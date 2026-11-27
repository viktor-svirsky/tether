package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// carrierNAT64 stands in for a carrier's own prefix, which isn't the well-known one.
var carrierNAT64 = netip.MustParsePrefix("2001:db8:64::/96")

// remoteVia is remote's address through the carrier's NAT64.
var remoteVia = netip.MustParseAddr("2001:db8:64::c633:6407")

// unreachable is the error Darwin gives for a dial or send with no route.
func unreachable(op string) error {
	return &net.OpError{Op: op, Err: os.NewSyscallError(op, syscall.ENETUNREACH)}
}

// withoutIPv4 fails the server's dials and UDP to remote, as on an iPhone without IPv4, and sends
// those to remote's NAT64 address to the test listeners on loopback. It returns the dials so far.
// The server is already running, so the hooks change under s.mu, which a device's first packet takes
// before anything reads them. Packets through a socket don't order memory for the race detector.
func withoutIPv4(s *Server) (dialed func() []string) {
	var mu sync.Mutex
	var dials []string
	s.mu.Lock()
	defer s.mu.Unlock()
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) { return carrierNAT64, nil }
	r := netip.MustParseAddr(remote)
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		mu.Lock()
		dials = append(dials, address)
		mu.Unlock()
		switch netip.MustParseAddrPort(address).Addr() {
		case r:
			return nil, unreachable("connect")
		case remoteVia:
			return toLoopback(ctx, network, address)
		}
		return nil, fmt.Errorf("unexpected dial to %s", address)
	}
	send := s.sendTo
	s.sendTo = func(c *net.UDPConn, payload []byte, to netip.AddrPort) error {
		if to.Addr() == r {
			return unreachable("sendto")
		}
		return send(c, payload, to)
	}
	s.toNet = func(a netip.AddrPort) netip.AddrPort {
		if a.Addr() == remoteVia {
			return netip.AddrPortFrom(loopback, a.Port())
		}
		return a
	}
	s.fromNet = func(a netip.AddrPort) netip.AddrPort {
		if a.Addr() == loopback {
			return netip.AddrPortFrom(remoteVia, a.Port())
		}
		return a
	}
	return func() []string {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(dials)
	}
}

func TestTCPReachesAnIPv4HostThroughTheCarriersNAT64(t *testing.T) {
	s, c := setup(t)
	dialed := withoutIPv4(s)
	if n, err := fetch(t, c, tcpServer(t, 100_000)); err != nil || n != 100_000 {
		t.Fatalf("got %d bytes, %v", n, err)
	}
	if d := dialed(); len(d) != 2 || netip.MustParseAddrPort(d[1]).Addr() != remoteVia {
		t.Fatalf("dialed %v, want remote and then its NAT64 address", d)
	}
}

// A device paused while its connection waits for the carrier's NAT64 prefix gets no connection once
// the prefix is there: its SYN would leave without the VPN, with Only share through a VPN (#277).
func TestAConnectionPausedBeforeItsNAT64PrefixIsFoundIsntDialed(t *testing.T) {
	s, c := setup(t)
	dialed := withoutIPv4(s)
	looking, release := make(chan struct{}, 1), make(chan struct{})
	s.mu.Lock() // the server reads it after taking s.mu, so the race detector sees the order (#250)
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) {
		looking <- struct{}{}
		<-release
		return carrierNAT64, nil
	}
	s.mu.Unlock()
	target := tcpServer(t, 1)
	done := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), scaled(2*time.Second))
		defer cancel()
		conn, err := c.net.DialContext(ctx, "tcp", target)
		if err == nil {
			conn.Close()
		}
		done <- err
	}()
	<-looking
	pause(t, s, true)
	close(release)
	if err := <-done; err == nil {
		t.Fatal("a paused device opened a connection")
	}
	if d := dialed(); len(d) != 1 {
		t.Fatalf("dialed %v, want only the IPv4 address, from before the pause", d)
	}
}

func TestUDPReachesAnIPv4HostThroughTheCarriersNAT64(t *testing.T) {
	s, c := setup(t)
	withoutIPv4(s)
	conn, err := c.net.Dial("udp", udpEcho(t))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	for i := range 3 {
		msg := fmt.Sprintf("ping %d", i)
		conn.SetDeadline(time.Now().Add(fetchTimeout()))
		conn.Write([]byte(msg))
		buf := make([]byte, 100)
		n, err := conn.Read(buf)
		// The device's socket is connected to remote, so a reply from any other address, like
		// the NAT64 one it came from, wouldn't reach it.
		if err != nil || string(buf[:n]) != msg {
			t.Fatalf("echo %d: %q %v", i, buf[:n], err)
		}
	}
	port := netip.MustParseAddrPort(conn.LocalAddr().String())
	s.mu.Lock()
	cn := s.cones[port]
	s.mu.Unlock()
	if cn == nil || cn.nat64Conn() == nil {
		t.Fatal("no NAT64 socket on the cone that used the NAT64")
	}
}

// A cone's own socket is IPv4 only. One socket for both would get its port from the free IPv6
// ports alone, and on macOS and iOS that port can be another app's IPv4 one, which then gets the
// replies: a lookup that never hears back (#67). NAT64 has a socket of its own, opened when needed.
func TestAConesSocketHoldsItsIPv4Port(t *testing.T) {
	s, c := setup(t)
	conn, err := c.net.Dial("udp", udpEcho(t))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := answered(conn, "hello"); err != nil {
		t.Fatal(err)
	}
	port := netip.MustParseAddrPort(conn.LocalAddr().String())
	s.mu.Lock()
	cn := s.cones[port]
	s.mu.Unlock()
	if cn == nil {
		t.Fatal("no cone for the device's port")
	}
	if local := cn.conn.LocalAddr().(*net.UDPAddr); local.IP.To4() == nil {
		t.Fatalf("the cone's socket is on %v, want an IPv4 one", local)
	}
	if cn.nat64Conn() != nil {
		t.Fatal("a NAT64 socket opened with an IPv4 route there")
	}
}

// Only a missing route goes to the NAT64. A host that refuses is refused, as it would be directly.
func TestARefusedDialIsntTriedThroughTheNAT64(t *testing.T) {
	s, c := setup(t)
	var mu sync.Mutex
	var dialed []string
	s.mu.Lock() // the server reads it after taking s.mu, so the race detector sees the order (#250)
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) { return carrierNAT64, nil }
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		mu.Lock()
		dialed = append(dialed, address)
		mu.Unlock()
		return nil, &net.OpError{Op: "dial", Net: network, Err: os.NewSyscallError("connect", syscall.ECONNREFUSED)}
	}
	s.mu.Unlock()
	if _, err := fetch(t, c, net.JoinHostPort(remote, "80")); err == nil {
		t.Fatal("the fetch worked")
	}
	// A slow run can see the device send its SYN again before the reset reaches it, which is a
	// second dial to remote. None may go to the NAT64.
	mu.Lock()
	defer mu.Unlock()
	if len(dialed) == 0 || slices.ContainsFunc(dialed, func(a string) bool { return a != net.JoinHostPort(remote, "80") }) {
		t.Fatalf("dialed %v, want only remote", dialed)
	}
}

// A real dial Darwin has no route for: 0.0.0.0/8 is nowhere. On the iPhone, every IPv4 address is.
func TestNoRouteTakesDarwinsErrorForAMissingRoute(t *testing.T) {
	_, err := net.Dial("tcp", "0.0.0.1:9")
	if !noRoute(err) {
		t.Fatalf("a dial with no route failed with %v, which noRoute doesn't take", err)
	}
	if !noRoute(unreachable("sendto")) {
		t.Fatal("noRoute doesn't take ENETUNREACH")
	}
	for _, err := range []error{nil, syscall.ECONNREFUSED, context.DeadlineExceeded, errors.New("other")} {
		if noRoute(err) {
			t.Errorf("noRoute(%v) is true", err)
		}
	}
}

func TestTheNAT64PrefixComesFromTheAnswerForIPv4onlyArpa(t *testing.T) {
	for _, tt := range []struct {
		answer []string
		want   string
	}{
		{[]string{"64:ff9b::c000:aa", "64:ff9b::c000:ab"}, "64:ff9b::/96"},
		{[]string{"2607:7700:0:1d::c000:ab"}, "2607:7700:0:1d::/96"},
		{[]string{"2001:db8::1", "2001:db8:64::c000:aa"}, "2001:db8:64::/96"},
		{[]string{"::ffff:192.0.0.170"}, ""}, // IPv4, mapped by Go's lookup on Darwin: no NAT64
		{[]string{"192.0.0.170"}, ""},
		{[]string{"2001:db8::1"}, ""},
		{nil, ""},
	} {
		var addrs []netip.Addr
		for _, a := range tt.answer {
			addrs = append(addrs, netip.MustParseAddr(a))
		}
		p, ok := nat64In(addrs)
		if got := map[bool]string{true: p.String(), false: ""}[ok]; got != tt.want {
			t.Errorf("%v: got %q, want %q", tt.answer, got, tt.want)
		}
	}
}

// A page load's connections all fail at once without IPv4. They wait for one lookup, not one each.
func TestTheNAT64PrefixIsLookedUpOnceAndKept(t *testing.T) {
	var lookups atomic.Int32
	n := &nat64{lookup: func(context.Context) (netip.Prefix, error) {
		lookups.Add(1)
		time.Sleep(50 * time.Millisecond)
		return carrierNAT64, nil
	}}
	var wg sync.WaitGroup
	got := make([]netip.Prefix, 50)
	for i := range got {
		wg.Go(func() { got[i] = n.prefix(context.Background(), time.Now) })
	}
	wg.Wait()
	if lookups.Load() != 1 || slices.ContainsFunc(got, func(p netip.Prefix) bool { return p != carrierNAT64 }) {
		t.Fatalf("%d lookups, got %v", lookups.Load(), got)
	}
}

func TestAFailedLookupUsesTheWellKnownPrefixForAWhile(t *testing.T) {
	var lookups atomic.Int32
	n := &nat64{lookup: func(context.Context) (netip.Prefix, error) {
		lookups.Add(1)
		return netip.Prefix{}, errors.New("no DNS64")
	}}
	for range 3 {
		if p := n.prefix(context.Background(), time.Now); p != wellKnownNAT64 {
			t.Fatalf("got %v", p)
		}
	}
	if lookups.Load() != 1 {
		t.Fatalf("%d lookups, want 1", lookups.Load())
	}
	n.expiry = time.Now() // a minute on
	n.prefix(context.Background(), time.Now)
	if lookups.Load() != 2 {
		t.Fatal("the lookup wasn't tried again")
	}
}

// A failed lookup after a good one keeps the carrier's prefix: the well-known one may not route on
// that carrier, and replies from the real NAT64 would stop being mapped back (#150).
func TestAFailedLookupKeepsTheCarriersPrefix(t *testing.T) {
	s := &Server{now: time.Now}
	var fail atomic.Bool
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) {
		if fail.Load() {
			return netip.Prefix{}, errors.New("timed out")
		}
		return carrierNAT64, nil
	}
	if p := s.nat64.prefix(context.Background(), s.now); p != carrierNAT64 {
		t.Fatalf("got %v", p)
	}
	fail.Store(true)
	s.nat64.expiry = time.Now() // ten minutes on
	if p := s.nat64.prefix(context.Background(), s.now); p != carrierNAT64 {
		t.Fatalf("a failed lookup gave %v", p)
	}
	from := netip.MustParseAddrPort("[2001:db8:64::c633:6407]:53")
	if got := s.fromNAT64(from); got != netip.MustParseAddrPort("198.51.100.7:53") {
		t.Fatalf("a reply from the carrier's NAT64 became %v", got)
	}
	if time.Until(s.nat64.expiry) > nat64Retry {
		t.Fatal("kept for longer than a retry before the next lookup")
	}
}

func TestOnlyRepliesFromInsideTheNAT64PrefixAreMapped(t *testing.T) {
	s := &Server{now: time.Now}
	from := netip.MustParseAddrPort("[2001:db8:64::c633:6407]:53")
	if got := s.fromNAT64(from); got != from {
		t.Fatalf("mapped %v to %v before any prefix was found", from, got)
	}
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) { return carrierNAT64, nil }
	via, ok := s.viaNAT64(context.Background(), netip.MustParseAddrPort("198.51.100.7:53"))
	if !ok || via != from {
		t.Fatalf("viaNAT64 gave %v %v", via, ok)
	}
	if got := s.fromNAT64(from); got != netip.MustParseAddrPort("198.51.100.7:53") {
		t.Fatalf("mapped %v to %v", from, got)
	}
	for _, a := range []string{"[2001:db8:65::c633:6407]:53", "198.51.100.7:53"} {
		if got := s.fromNAT64(netip.MustParseAddrPort(a)); got.String() != a {
			t.Errorf("mapped %v to %v", a, got)
		}
	}
	if _, ok := s.viaNAT64(context.Background(), from); ok {
		t.Error("an IPv6 address went through the NAT64")
	}
}

// The prefix is kept by the server's clock: moving it past nat64Keep looks it up again, and past
// nat64Retry after a failed lookup.
func TestTheNAT64PrefixExpiresByTheServersClock(t *testing.T) {
	k := newFakeClock()
	k.set(time.Now())
	s := &Server{now: k.now}
	var lookups atomic.Int32
	var fail atomic.Bool
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) {
		lookups.Add(1)
		if fail.Load() {
			return netip.Prefix{}, errors.New("timed out")
		}
		return carrierNAT64, nil
	}
	look := func(want int32) {
		t.Helper()
		s.viaNAT64(context.Background(), netip.MustParseAddrPort("198.51.100.7:53"))
		if n := lookups.Load(); n != want {
			t.Fatalf("%d lookups, want %d", n, want)
		}
	}
	look(1)
	k.advance(nat64Keep - time.Second)
	look(1)
	k.advance(time.Second)
	fail.Store(true)
	look(2)
	k.advance(nat64Retry - time.Second)
	look(2)
	k.advance(time.Second)
	look(3)
}

// Swift asks which prefix is in use, to check where a connection through it would leave (#277). The
// answer never waits: nothing until the first lookup ends, then the carrier's prefix, without
// another lookup while it's kept.
func TestThePrefixInUseIsToldWithoutWaiting(t *testing.T) {
	s := startAlone(t)
	release := make(chan struct{})
	var lookups atomic.Int32
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) {
		lookups.Add(1)
		<-release
		return carrierNAT64, nil
	}
	if got := s.NAT64(); got != "" {
		t.Fatalf("%q before any lookup ended, want nothing", got)
	}
	if !waitFor(5*time.Second, func() bool { return lookups.Load() == 1 }) {
		t.Fatal("asking for the prefix didn't start its lookup")
	}
	if got := s.NAT64(); got != "" || lookups.Load() != 1 {
		t.Fatalf("%q with %d lookups while the first one runs", got, lookups.Load())
	}
	close(release)
	if !waitFor(5*time.Second, func() bool { return s.NAT64() == carrierNAT64.String() }) {
		t.Fatalf("got %q, want the carrier's %v", s.NAT64(), carrierNAT64)
	}
	if s.NAT64(); lookups.Load() != 1 {
		t.Fatalf("%d lookups, want the one kept", lookups.Load())
	}
}

// An old prefix is looked up again, a new SIM's carrier has another, and stays the answer meanwhile:
// nothing in between would stop every device for the length of a lookup.
func TestAnOldPrefixIsToldWhileItsLookedUpAgain(t *testing.T) {
	s := startAlone(t)
	other := netip.MustParsePrefix("2001:db8:65::/96")
	var next atomic.Pointer[netip.Prefix]
	next.Store(&carrierNAT64)
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) { return *next.Load(), nil }
	if !waitFor(5*time.Second, func() bool { return s.NAT64() == carrierNAT64.String() }) {
		t.Fatalf("got %q, want the carrier's %v", s.NAT64(), carrierNAT64)
	}
	next.Store(&other)
	s.nat64.mu.Lock()
	s.nat64.expiry = time.Time{}
	s.nat64.mu.Unlock()
	if got := s.NAT64(); got != carrierNAT64.String() && got != other.String() {
		t.Fatalf("%q while the prefix is looked up again", got)
	}
	if !waitFor(5*time.Second, func() bool { return s.NAT64() == other.String() }) {
		t.Fatalf("got %q, want the new carrier's %v", s.NAT64(), other)
	}
}

// When the lookup fails, the well-known prefix is the one in use, and the one told.
func TestWithoutACarrierPrefixTheWellKnownOneIsTold(t *testing.T) {
	s := startAlone(t)
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) { return netip.Prefix{}, errors.New("no DNS64") }
	if !waitFor(5*time.Second, func() bool { return s.NAT64() == wellKnownNAT64.String() }) {
		t.Fatalf("got %q, want %v", s.NAT64(), wellKnownNAT64)
	}
}

// A stopped server starts no lookup.
func TestAStoppedServerLooksNoPrefixUp(t *testing.T) {
	s := startAlone(t)
	var lookups atomic.Int32
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) {
		lookups.Add(1)
		return carrierNAT64, nil
	}
	s.Close()
	if got := s.NAT64(); got != "" {
		t.Fatalf("%q from a stopped server", got)
	}
	time.Sleep(100 * time.Millisecond)
	if lookups.Load() != 0 {
		t.Fatal("a stopped server looked the prefix up")
	}
}
