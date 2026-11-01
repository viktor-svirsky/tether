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
func withoutIPv4(s *Server) (dialed func() []string) {
	var mu sync.Mutex
	var dials []string
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
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		conn.Write([]byte(msg))
		buf := make([]byte, 100)
		n, err := conn.Read(buf)
		// The device's socket is connected to remote, so a reply from any other address, like
		// the NAT64 one it came from, wouldn't reach it.
		if err != nil || string(buf[:n]) != msg {
			t.Fatalf("echo %d: %q %v", i, buf[:n], err)
		}
	}
}

// Only a missing route goes to the NAT64. A host that refuses is refused, as it would be directly.
func TestARefusedDialIsntTriedThroughTheNAT64(t *testing.T) {
	s, c := setup(t)
	var mu sync.Mutex
	var dialed []string
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) { return carrierNAT64, nil }
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		mu.Lock()
		dialed = append(dialed, address)
		mu.Unlock()
		return nil, &net.OpError{Op: "dial", Net: network, Err: os.NewSyscallError("connect", syscall.ECONNREFUSED)}
	}
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
		wg.Go(func() { got[i] = n.prefix(context.Background()) })
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
		if p := n.prefix(context.Background()); p != wellKnownNAT64 {
			t.Fatalf("got %v", p)
		}
	}
	if lookups.Load() != 1 {
		t.Fatalf("%d lookups, want 1", lookups.Load())
	}
	n.expiry = time.Now() // a minute on
	n.prefix(context.Background())
	if lookups.Load() != 2 {
		t.Fatal("the lookup wasn't tried again")
	}
}

func TestOnlyRepliesFromInsideTheNAT64PrefixAreMapped(t *testing.T) {
	s := &Server{}
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
