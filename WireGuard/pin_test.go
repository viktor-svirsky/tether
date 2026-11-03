package main

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// loopbackIndex is lo0's interface index.
func loopbackIndex(t *testing.T) int {
	i, err := net.InterfaceByName("lo0")
	if err != nil {
		t.Fatal(err)
	}
	return i.Index
}

// otherInterface is the interface of this computer's IPv4 default route: Wi-Fi or Ethernet, with
// an address, so a dial pinned to it fails for being on the wrong interface, not for having none.
func otherInterface(t *testing.T) net.Interface {
	r := defaultRoute(false)
	if r.name == "" || r.name == "lo0" {
		t.Skip("no IPv4 default route here")
	}
	return net.Interface{Index: r.index, Name: r.name}
}

// udpEchoOn is a UDP echo on host, for a socket outside the tunnel.
func udpEchoOn(t *testing.T, host string) string {
	c, err := net.ListenPacket("udp", net.JoinHostPort(host, "0"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	go func() {
		buf := make([]byte, 2048)
		for {
			n, from, err := c.ReadFrom(buf)
			if err != nil {
				return
			}
			c.WriteTo(buf[:n], from)
		}
	}()
	return c.LocalAddr().String()
}

// boundTo is the interface a socket is pinned to, 0 for none.
func boundTo(t *testing.T, c syscall.Conn, ipv6 bool) int {
	rc, err := c.SyscallConn()
	if err != nil {
		t.Fatal(err)
	}
	var index int
	var gerr error
	rc.Control(func(fd uintptr) {
		if ipv6 {
			index, gerr = syscall.GetsockoptInt(int(fd), syscall.IPPROTO_IPV6, syscall.IPV6_BOUND_IF)
		} else {
			index, gerr = syscall.GetsockoptInt(int(fd), syscall.IPPROTO_IP, syscall.IP_BOUND_IF)
		}
	})
	if gerr != nil {
		t.Fatal(gerr)
	}
	return index
}

// noInterface is an interface index no interface has.
const noInterface = 9999

// A TCP socket pinned to lo0 reaches 127.0.0.1, and one pinned to any other interface can't: Darwin
// takes a source address from that interface, which loopback refuses. IPv6 can't show it the same
// way, since Darwin reaches ::1 from a TCP socket pinned anywhere.
func TestAPinnedTCPSocketLeavesOnlyOnItsInterface(t *testing.T) {
	lo := loopbackIndex(t)
	other := otherInterface(t)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	dial := func(index int) error {
		d := net.Dialer{Timeout: 2 * time.Second, Control: func(network, address string, c syscall.RawConn) error {
			var err error
			c.Control(func(fd uintptr) { err = pinSocket(int(fd), false, index) })
			return err
		}}
		c, err := d.Dial("tcp4", l.Addr().String())
		if c != nil {
			c.Close()
		}
		return err
	}
	if err := dial(lo); err != nil {
		t.Fatalf("pinned to lo0, 127.0.0.1 wasn't reached: %v", err)
	}
	err = dial(other.Index)
	if err == nil {
		t.Fatalf("pinned to %s, 127.0.0.1 was reached", other.Name)
	}
	t.Logf("pinned to %s, a dial to 127.0.0.1 failed: %v", other.Name, err)
}

// A cone's socket sends to many addresses, so each packet is pinned on its own. A packet pinned to
// lo0 reaches loopback, and one pinned to an interface that isn't there fails, so Darwin reads the
// pin. Over IPv6 it also refuses to send to ::1 from another interface. Darwin delivers an IPv4
// packet to 127.0.0.1 whatever it's pinned to, so IPv4 can't show that part.
func TestAPinnedUDPPacketLeavesOnItsInterface(t *testing.T) {
	lo := loopbackIndex(t)
	other := otherInterface(t)
	send := func(network string, to netip.AddrPort, index int) error {
		c, err := net.ListenUDP(network, nil)
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		if _, _, err := c.WriteMsgUDPAddrPort([]byte("hi"), via(to.Addr(), index), to); err != nil {
			return err
		}
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		_, _, err = c.ReadFromUDPAddrPort(make([]byte, 10))
		return err
	}
	to4 := netip.MustParseAddrPort(udpEchoOn(t, "127.0.0.1"))
	to6 := netip.MustParseAddrPort(udpEchoOn(t, "::1"))
	for _, tt := range []struct {
		network string
		to      netip.AddrPort
		index   int
		reached bool
	}{
		{"udp4", to4, 0, true},
		{"udp4", to4, lo, true},
		{"udp4", to4, noInterface, false},
		{"udp", to6, 0, true},
		{"udp", to6, lo, true},
		{"udp", to6, noInterface, false},
		{"udp", to6, other.Index, false},
	} {
		if err := send(tt.network, tt.to, tt.index); (err == nil) != tt.reached {
			t.Errorf("pinned to %d, %v: %v", tt.index, tt.to, err)
		}
	}
}

func TestOnlyAddressesOnTheInternetArePinned(t *testing.T) {
	for _, a := range []string{"1.1.1.1", "198.51.100.7", "2606:4700::1111", "64:ff9b::101:101", "::ffff:1.1.1.1"} {
		if !pinnable(netip.MustParseAddr(a)) {
			t.Errorf("%s isn't pinned", a)
		}
	}
	// The iPhone's own networks, a VPN's (Tailscale's are CGNAT and fd7a::), and what never leaves.
	for _, a := range []string{"10.0.0.5", "172.16.0.1", "192.168.1.10", "100.64.0.1", "100.100.100.100",
		"fd00::1", "fd7a:115c:a1e0::53", "169.254.1.1", "fe80::1", "127.0.0.1", "::1", "224.0.0.251", "0.0.0.0", "::ffff:10.0.0.5"} {
		if pinnable(netip.MustParseAddr(a)) {
			t.Errorf("%s is pinned", a)
		}
	}
	p := &pinner{find: func(bool) route { t.Fatal("looked up the route for a local address"); return route{} }}
	if i := p.index(netip.MustParseAddr("192.168.1.10")); i != 0 {
		t.Fatalf("a private address pinned to %d", i)
	}
}

// fakeRoutes is a pinner whose default routes are what the test says, on a clock it moves.
type fakeRoutes struct {
	mu     sync.Mutex
	v4, v6 route
	finds  int
	clock  time.Time
	logged []string
}

func (f *fakeRoutes) pinner() *pinner {
	p := &pinner{}
	f.use(p)
	return p
}

// use makes p's routes, clock and log f's.
func (f *fakeRoutes) use(p *pinner) {
	p.find = func(ipv6 bool) route {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.finds++
		if ipv6 {
			return f.v6
		}
		return f.v4
	}
	p.now = func() time.Time { f.mu.Lock(); defer f.mu.Unlock(); return f.clock }
	p.logf = func(format string, args ...any) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.logged = append(f.logged, fmt.Sprintf(format, args...))
	}
}

func (f *fakeRoutes) set(v4, v6 route) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.v4, f.v6 = v4, v6
}

func (f *fakeRoutes) wait(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.clock = f.clock.Add(d)
}

func (f *fakeRoutes) state() (finds int, logged []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.finds, slices.Clone(f.logged)
}

var (
	internet4 = netip.MustParseAddr("1.1.1.1")
	internet6 = netip.MustParseAddr("2606:4700::1111")
)

// A VPN on the iPhone that carries the default route carries the devices' traffic too.
func TestAVPNsDefaultRouteIsntPinnedAround(t *testing.T) {
	for _, name := range []string{"utun3", "ipsec0"} {
		f := &fakeRoutes{clock: time.Unix(1, 0)}
		f.set(route{name, 9}, route{name, 9})
		p := f.pinner()
		if i := p.index(internet4); i != 0 {
			t.Errorf("pinned to %d with the default route on %s", i, name)
		}
		if _, logged := f.state(); len(logged) != 1 || !strings.Contains(logged[0], name+", a VPN") {
			t.Errorf("logged %q", logged)
		}
	}
}

// An IPv6-only carrier has no IPv4 default route. A socket pinned to an interface without IPv4 sends
// into nothing without an error, so IPv4 isn't pinned and its send fails with no route, which takes
// it to the NAT64.
func TestNoDefaultRouteMeansNoPin(t *testing.T) {
	f := &fakeRoutes{clock: time.Unix(1, 0)}
	f.set(route{}, route{"pdp_ip0", 5})
	p := f.pinner()
	if i := p.index(internet4); i != 0 {
		t.Fatalf("IPv4 pinned to %d without an IPv4 route", i)
	}
	if i := p.index(netip.MustParseAddr("64:ff9b::101:101")); i != 5 {
		t.Fatalf("the NAT64 address pinned to %d, want pdp_ip0's 5", i)
	}
	if _, logged := f.state(); !slices.Equal(logged, []string{
		"IPv4 traffic isn't pinned: there's no default route", "IPv6 traffic leaves on pdp_ip0",
	}) {
		t.Fatalf("logged %q", logged)
	}
}

// The interface is looked up once per pinKeep, each IP version on its own, and a change is logged
// once.
func TestTheInterfaceIsLookedUpAgainAfterAWhile(t *testing.T) {
	f := &fakeRoutes{clock: time.Unix(1, 0)}
	f.set(route{"pdp_ip0", 5}, route{"pdp_ip0", 5})
	p := f.pinner()
	for range 3 {
		if i := p.index(internet4); i != 5 {
			t.Fatalf("pinned to %d, want 5", i)
		}
	}
	if finds, _ := f.state(); finds != 1 {
		t.Fatalf("%d lookups, want 1", finds)
	}
	// Wi-Fi comes, and the interface found stays until pinKeep has passed.
	f.set(route{"en0", 11}, route{"pdp_ip0", 5})
	f.wait(pinKeep - time.Millisecond)
	if i := p.index(internet4); i != 5 {
		t.Fatalf("pinned to %d before pinKeep passed, want 5", i)
	}
	f.wait(time.Millisecond)
	if i := p.index(internet4); i != 11 {
		t.Fatalf("pinned to %d after pinKeep, want en0's 11", i)
	}
	if i := p.index(internet6); i != 5 {
		t.Fatalf("IPv6 pinned to %d, want 5", i)
	}
	// The same answer again isn't logged again.
	f.wait(pinKeep)
	p.index(internet4)
	finds, logged := f.state()
	if finds != 4 {
		t.Fatalf("%d lookups, want 4", finds)
	}
	if !slices.Equal(logged, []string{
		"IPv4 traffic leaves on pdp_ip0", "IPv4 traffic leaves on en0", "IPv6 traffic leaves on pdp_ip0",
	}) {
		t.Fatalf("logged %q", logged)
	}
}

// A page load's connections all ask at once. They wait for one lookup, not one each.
func TestTheInterfaceIsLookedUpOnceForManySockets(t *testing.T) {
	f := &fakeRoutes{clock: time.Unix(1, 0)}
	f.set(route{"pdp_ip0", 5}, route{})
	p := f.pinner()
	find := p.find
	p.find = func(ipv6 bool) route { time.Sleep(20 * time.Millisecond); return find(ipv6) }
	var wg sync.WaitGroup
	for range 50 {
		wg.Go(func() {
			if i := p.index(internet4); i != 5 {
				t.Errorf("pinned to %d", i)
			}
		})
	}
	wg.Wait()
	if finds, _ := f.state(); finds != 1 {
		t.Fatalf("%d lookups, want 1", finds)
	}
}

// The real lookup, on this computer: the interface it names has the index it gives.
func TestTheDefaultRouteIsFound(t *testing.T) {
	c, err := net.Dial("udp", "1.1.1.1:53")
	if err != nil {
		t.Skipf("no IPv4 default route here: %v", err)
	}
	c.Close()
	r := defaultRoute(false)
	i, err := net.InterfaceByName(r.name)
	if err != nil || i.Index != r.index {
		t.Fatalf("found %+v, which is %+v %v", r, i, err)
	}
	t.Logf("IPv4 leaves this computer on %s", r.name)
}

// The dialer pins a connection to the internet before it connects, and leaves a local one alone.
func TestTheDialerPinsOnlyConnectionsToTheInternet(t *testing.T) {
	lo := loopbackIndex(t)
	f := &fakeRoutes{clock: time.Unix(1, 0)}
	f.set(route{"lo0", lo}, route{"lo0", lo})
	d := newDialer(f.pinner())
	for _, tt := range []struct {
		network, address string
		want             int
	}{
		{"tcp4", "1.1.1.1:443", lo},
		{"tcp6", "[2606:4700::1111]:443", lo},
		{"tcp4", "10.8.0.1:443", 0},
		{"tcp6", "[fd00::1]:443", 0},
	} {
		c, err := net.ListenUDP(map[string]string{"tcp4": "udp4", "tcp6": "udp6"}[tt.network], nil)
		if err != nil {
			t.Fatal(err)
		}
		rc, _ := c.SyscallConn()
		if err := d.Control(tt.network, tt.address, rc); err != nil {
			t.Fatal(err)
		}
		if got := boundTo(t, c, tt.network == "tcp6"); got != tt.want {
			t.Errorf("%s pinned to %d, want %d", tt.address, got, tt.want)
		}
		c.Close()
	}
}

// One socket sends every device's pings, so it's pinned again when the next one needs it.
func TestThePingSocketIsPinnedForEachPing(t *testing.T) {
	s, _ := setup(t)
	lo := loopbackIndex(t)
	f := &fakeRoutes{clock: time.Unix(1, 0)}
	f.set(route{"lo0", lo}, route{})
	f.use(&s.pin)
	s.pings.once.Do(s.startPinging)
	if s.pings.conn == nil {
		t.Skip("no ping socket here")
	}
	sc := s.pings.conn.IPv4PacketConn().PacketConn.(syscall.Conn)
	s.pinPing(internet4)
	if got := boundTo(t, sc, false); got != lo {
		t.Fatalf("a ping to the internet pinned to %d, want %d", got, lo)
	}
	s.pinPing(netip.MustParseAddr("192.168.1.1"))
	if got := boundTo(t, sc, false); got != 0 {
		t.Fatalf("a ping to a private address pinned to %d", got)
	}
}

// With the iPhone's sockets pinned, a device still reaches what's local to the iPhone: the TCP
// dialer, a cone and a ping all reach the test's listeners on loopback, which pinning would refuse.
func TestLocalAddressesArentPinnedThroughTheTunnel(t *testing.T) {
	s, c := setup(t)
	other := otherInterface(t)
	s.pin.find = func(bool) route {
		t.Error("looked up the route for a local address")
		return route{other.Name, other.Index}
	}
	d := newDialer(&s.pin)
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		_, port, _ := net.SplitHostPort(address)
		return d.DialContext(ctx, network, net.JoinHostPort("127.0.0.1", port))
	}
	if n, err := fetch(t, c, tcpServer(t, 1000)); err != nil || n != 1000 {
		t.Fatalf("got %d bytes, %v", n, err)
	}
	conn, err := c.net.Dial("udp", udpEcho(t))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := answered(conn, "hello"); err != nil {
		t.Fatal(err)
	}
	if _, err := pingFrom(c, remote, 1, []byte("hi"), 5*time.Second); err != nil {
		t.Fatal(err)
	}
}
