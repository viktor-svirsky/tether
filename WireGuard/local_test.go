package main

import (
	"context"
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"
)

// blockLocal turns the setting on or off, the way configure does.
func blockLocal(s *Server, on bool) { s.SetBlockLocal(on) }

// onLinkRemote makes remote's network one the iPhone is on, the way its Wi-Fi's would be, so the
// tests' far ends count as local without binding to private addresses.
func onLinkRemote(s *Server) {
	ownAre(s, "198.51.100.1/24")
	s.refreshLocal()
}

// Block refuses the private ranges, the carrier-grade NAT range Tailscale uses and IPv6 unique
// local addresses. The internet stays open, 198.18.0.0/15 included, and so does everything with
// Allow.
func TestBlockingLocalNetworksRefusesTheirRanges(t *testing.T) {
	s := startAlone(t)
	local := []string{"10.1.2.3", "172.16.5.5", "172.31.255.254", "192.168.1.50", "100.64.1.1", "100.127.255.254", "fd12::1", "fc00::1", "::ffff:192.168.1.50"}
	internet := []string{"1.1.1.1", "172.32.0.1", "100.128.0.1", "198.18.0.5", "2606:4700::1111", "11.0.0.1"}
	for _, a := range append(local, internet...) {
		if !s.leaves(netip.MustParseAddr(a)) {
			t.Errorf("%s stayed inside with Allow", a)
		}
	}
	blockLocal(s, true)
	for _, a := range local {
		if s.leaves(netip.MustParseAddr(a)) {
			t.Errorf("%s went out with Block", a)
		}
	}
	for _, a := range internet {
		if !s.leaves(netip.MustParseAddr(a)) {
			t.Errorf("%s is the internet and stayed inside with Block", a)
		}
	}
	blockLocal(s, false)
	if !s.leaves(netip.MustParseAddr("192.168.1.50")) {
		t.Fatal("Allow again didn't open the local networks")
	}
}

// The networks the iPhone is on count as local too: a Wi-Fi with public IPv4 or global IPv6
// addresses is still the owner's network. A mask wider than /16, or /48 for IPv6, is ignored, so
// an odd VPN address can't block the internet.
func TestBlockingLocalNetworksRefusesTheNetworksTheIPhoneIsOn(t *testing.T) {
	s := startAlone(t)
	ownAre(s, "203.0.113.5/24", "2607:fb90:1:2::5/64", "8.8.4.4/8", "2001:db8::5/32", "198.18.0.1/16")
	s.refreshLocal()
	blockLocal(s, true)
	for _, a := range []string{"203.0.113.9", "2607:fb90:1:2::6"} {
		if s.leaves(netip.MustParseAddr(a)) {
			t.Errorf("%s is on the iPhone's network and went out with Block", a)
		}
	}
	// A proxy app's interface in 198.18.0.0/15 doesn't make its fake addresses local.
	for _, a := range []string{"203.0.114.9", "2607:fb90:1:3::1", "8.1.1.1", "2001:db8:1::1", "198.18.5.5"} {
		if !s.leaves(netip.MustParseAddr(a)) {
			t.Errorf("%s isn't on the iPhone's network and stayed inside", a)
		}
	}
	// The networks follow the iPhone, like its own addresses.
	ownAre(s, "203.0.114.5/24")
	s.refreshLocal()
	if !s.leaves(netip.MustParseAddr("203.0.113.9")) || s.leaves(netip.MustParseAddr("203.0.114.9")) {
		t.Fatal("the iPhone's networks didn't follow its addresses")
	}
}

// A device's connection to a private address is refused with Block and works with Allow.
func TestATCPConnectionToAPrivateAddressFollowsTheSetting(t *testing.T) {
	s, c := setup(t)
	_, port, _ := net.SplitHostPort(tcpServer(t, 100))
	addr := net.JoinHostPort("192.168.1.50", port) // the server's dial goes to loopback, see toLoopback
	if n, err := fetch(t, c, addr); err != nil || n != 100 {
		t.Fatalf("with Allow: %d bytes, %v", n, err)
	}
	blockLocal(s, true)
	ctx, cancel := context.WithTimeout(context.Background(), fetchTimeout())
	defer cancel()
	if _, err := c.net.DialContext(ctx, "tcp", addr); err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("with Block: got %v, want a refusal", err)
	}
	if n, err := fetch(t, c, tcpServer(t, 100)); err != nil || n != 100 {
		t.Fatalf("with Block, the internet: %d bytes, %v", n, err)
	}
}

// Turning Block on resets the connections already open to local addresses. The others stay.
func TestBlockingClosesOpenLocalConnectionsOnly(t *testing.T) {
	s, c := setup(t)
	echo := func(conn *net.TCPConn) { io.Copy(conn, conn) }
	_, port, _ := net.SplitHostPort(farEnd(t, echo))
	local := connect(t, c, net.JoinHostPort("192.168.1.50", port))
	internet := connect(t, c, farEnd(t, echo))
	for _, conn := range []net.Conn{local, internet} {
		if _, err := conn.Write([]byte("hi")); err != nil {
			t.Fatal(err)
		}
		if _, err := io.ReadFull(conn, make([]byte, 2)); err != nil {
			t.Fatal(err)
		}
	}
	blockLocal(s, true)
	local.SetDeadline(time.Now().Add(5 * time.Second))
	local.Write([]byte("hi"))
	if _, err := io.ReadFull(local, make([]byte, 2)); err == nil {
		t.Fatal("a connection to a local address still echoes after Block")
	}
	if _, err := internet.Write([]byte("hi")); err != nil {
		t.Fatal("Block closed a connection to the internet:", err)
	}
	if _, err := io.ReadFull(internet, make([]byte, 2)); err != nil {
		t.Fatal("Block closed a connection to the internet:", err)
	}
}

// A connection opened to an address that wasn't local is reset once the iPhone joins its network
// with Block on, since a device could otherwise keep reaching that network through it.
func TestAConnectionWhoseDestinationBecomesLocalIsReset(t *testing.T) {
	s, c := setup(t)
	conn := connect(t, c, farEnd(t, func(conn *net.TCPConn) { io.Copy(conn, conn) }))
	blockLocal(s, true)
	if _, err := conn.Write([]byte("hi")); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(conn, make([]byte, 2)); err != nil {
		t.Fatal("remote isn't local yet, so it should still echo:", err)
	}
	onLinkRemote(s)
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	conn.Write([]byte("hi"))
	if _, err := io.ReadFull(conn, make([]byte, 2)); err == nil {
		t.Fatal("a connection to what became a local address still echoes")
	}
}

// UDP to a local address is dropped with Block, and so is a reply from one, also to a port the
// device opened while it was allowed.
func TestUDPToAndFromLocalAddressesFollowsTheSetting(t *testing.T) {
	s, c := setup(t)
	addr := udpEcho(t)
	if err := echoOnce(c, addr, "allowed", fetchTimeout()); err != nil {
		t.Fatal("with Allow:", err)
	}
	onLinkRemote(s)
	blockLocal(s, true)
	if err := echoOnce(c, addr, "blocked", time.Second); err == nil {
		t.Fatal("with Block, an echo came back from a local address")
	}
	blockLocal(s, false)
	if err := echoOnce(c, addr, "allowed again", fetchTimeout()); err != nil {
		t.Fatal("with Allow again:", err)
	}
}

// A reply that comes later, from a host the device reached while it was allowed, is dropped once
// Block is on: the cone takes replies from anyone, so it checks where they come from.
func TestALateReplyFromALocalAddressIsDropped(t *testing.T) {
	s, c := setup(t)
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })
	from := make(chan net.Addr, 1)
	go func() {
		buf := make([]byte, 64)
		n, a, err := pc.ReadFrom(buf)
		if err != nil {
			return
		}
		pc.WriteTo(buf[:n], a)
		from <- a
	}()
	conn, err := c.net.Dial("udp", viaRemote(pc.LocalAddr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write([]byte("first"))
	conn.SetReadDeadline(time.Now().Add(fetchTimeout()))
	if _, err := conn.Read(make([]byte, 64)); err != nil {
		t.Fatal("the first reply:", err)
	}
	onLinkRemote(s)
	blockLocal(s, true)
	pc.WriteTo([]byte("later"), <-from)
	conn.SetReadDeadline(time.Now().Add(time.Second))
	if n, err := conn.Read(make([]byte, 64)); err == nil {
		t.Fatalf("a later reply from a local address got through: %d bytes", n)
	}
}

// echoOnce sends text to a UDP echo from the device and waits for it back.
func echoOnce(c *client, addr, text string, wait time.Duration) error {
	conn, err := c.net.Dial("udp", addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.Write([]byte(text)); err != nil {
		return err
	}
	conn.SetReadDeadline(time.Now().Add(wait))
	buf := make([]byte, 64)
	n, err := conn.Read(buf)
	if err != nil {
		return err
	}
	if string(buf[:n]) != text {
		return io.ErrUnexpectedEOF
	}
	return nil
}

// A ping to a local address gets no reply with Block. Through loopback, which some Macs drop.
func TestAPingToALocalAddressFollowsTheSetting(t *testing.T) {
	s, c := setup(t)
	if _, err := pingFrom(c, remote, 1, []byte("allowed"), 5*time.Second); err != nil {
		t.Fatal("with Allow:", err)
	}
	onLinkRemote(s)
	blockLocal(s, true)
	if _, err := pingFrom(c, remote, 2, []byte("blocked"), time.Second); err == nil {
		t.Fatal("with Block, a local address answered a ping")
	}
}

// Tether's own services stay open with Block: its DNS at 10.7.0.1, over UDP and TCP, and a ping
// to it.
func TestBlockingLeavesTethersOwnAddressOpen(t *testing.T) {
	s, c := setup(t)
	p := newPlain(t, 1)
	viaPlain(s, p)
	blockLocal(s, true)
	if a, err := lookupUDP(c, lookupFor(t, 81, "a.example.", 0), answerWait); err != nil {
		t.Fatal("a lookup over UDP with Block:", err)
	} else if h, n := read(t, a); h.ID != 81 || n != 1 {
		t.Fatalf("over UDP: %+v with %d records", h, n)
	}
	answers, err := lookupsTCP(c, answerWait, lookupFor(t, 82, "b.example.", 0))
	if err != nil {
		t.Fatal("a lookup over TCP with Block:", err)
	}
	if h, n := read(t, answers[0]); h.ID != 82 || n != 1 {
		t.Fatalf("over TCP: %+v with %d records", h, n)
	}
	if _, err := pingFrom(c, dnsAddr.Addr().String(), 1, []byte("tether"), 5*time.Second); err != nil {
		t.Fatal("a ping to 10.7.0.1 with Block:", err)
	}
}

// Block turning on while a connection to a local address is being dialed refuses it, though
// leaves let it through before the dial.
func TestBlockTurningOnMidDialRefusesTheConnection(t *testing.T) {
	s, c := setup(t)
	_, port, _ := net.SplitHostPort(farEnd(t, func(conn *net.TCPConn) { io.Copy(conn, conn) }))
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		go s.SetBlockLocal(true)
		for !s.blockLocal.Load() {
			time.Sleep(time.Millisecond)
		}
		return toLoopback(ctx, network, address)
	}
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), fetchTimeout())
	defer cancel()
	conn, err := c.net.DialContext(ctx, "tcp", net.JoinHostPort("192.168.1.50", port))
	if err != nil {
		return // refused, as it should be
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	conn.Write([]byte("hi"))
	if _, err := io.ReadFull(conn, make([]byte, 2)); err == nil {
		t.Fatal("a connection dialed while Block turned on still echoes")
	}
}

// The config message carries the setting. Without it, local networks stay open, as before.
func TestTheConfigMessageCarriesTheSetting(t *testing.T) {
	for js, want := range map[string]bool{
		`{"v":1,"peers":[]}`:                    false,
		`{"v":1,"peers":[],"blockLocal":false}`: false,
		`{"v":1,"peers":[],"blockLocal":true}`:  true,
	} {
		_, _, block, err := parseConfig(js)
		if err != nil || block != want {
			t.Errorf("%s: block %v, %v, want %v", js, block, err, want)
		}
	}
}

// The config page is on the hotspot's address, which is a local one, and stays open with Block,
// connections already open to it included.
func TestTheConfigPageStaysOpenWithBlock(t *testing.T) {
	s, c := setup(t)
	_, port, _ := net.SplitHostPort(farEnd(t, func(conn *net.TCPConn) { io.Copy(conn, conn) }))
	page := netip.MustParseAddrPort(net.JoinHostPort("192.168.1.50", port))
	ownAre(s, "192.168.1.50/32")
	s.refreshLocal()
	s.SetPage([]netip.AddrPort{page})
	conn := connect(t, c, page.String())
	blockLocal(s, true)
	if _, err := conn.Write([]byte("hi")); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(conn, make([]byte, 2)); err != nil {
		t.Fatal("Block closed a connection to the config page:", err)
	}
	connect(t, c, page.String()) // fails the test if the page refuses a new connection with Block
}
