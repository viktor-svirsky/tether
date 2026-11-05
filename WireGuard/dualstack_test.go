package main

import (
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"
)

// On a carrier that gives the iPhone IPv6 only, the hotspot still gives a Windows PC IPv4, while a
// Mac takes none. So the server listens on 172.20.10.1 and on the iPhone's IPv6 address (#98).
func startOn(t *testing.T, hosts ...netip.Addr) (*Server, [32]byte) {
	t.Helper()
	sPriv, sPub := keyPair(t)
	s, err := Start(hosts, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	return s, sPub
}

func TestDevicesReachTheServerOnEitherAddress(t *testing.T) {
	s, sPub := startOn(t, loopback, netip.IPv6Loopback())
	aPriv, aPub := keyPair(t)
	bPriv, bPub := keyPair(t)
	a, b := netip.MustParseAddr("10.7.0.2"), netip.MustParseAddr("10.7.0.3")
	if err := s.SetPeers([]Peer{{PublicKey: aPub, Address: a}, {PublicKey: bPub, Address: b}}); err != nil {
		t.Fatal(err)
	}
	overV4 := newDeviceVia(t, s, loopback, sPub, aPriv, MTU, a)
	overV6 := newDeviceVia(t, s, netip.IPv6Loopback(), sPub, bPriv, MTU, b)
	for name, c := range map[string]*client{"IPv4": overV4, "IPv6": overV6} {
		if n, err := fetch(t, c, tcpServer(t, 1000)); err != nil || n != 1000 {
			t.Fatalf("over %s: got %d bytes, %v", name, n, err)
		}
	}
	s.readHandshakes()
	s.mu.Lock()
	got := map[string]string{"10.7.0.2": s.endpoints[a], "10.7.0.3": s.endpoints[b]}
	s.mu.Unlock()
	if !strings.HasPrefix(got["10.7.0.2"], "127.0.0.1:") || !strings.HasPrefix(got["10.7.0.3"], "[::1]:") {
		t.Fatalf("endpoints %v, want each device where it connected from", got)
	}
}

// A device whose config is imported again with the other address carries on with the same key, and
// the server answers it there. (Changing the endpoint on a running client isn't the test: the client
// follows the server's replies too, and one still coming from IPv4 pulls it back.)
func TestADeviceMovesBetweenTheAddresses(t *testing.T) {
	s, sPub := startOn(t, loopback, netip.IPv6Loopback())
	cPriv, cPub := keyPair(t)
	addr := netip.MustParseAddr("10.7.0.2")
	if err := s.SetPeers([]Peer{{PublicKey: cPub, Address: addr}}); err != nil {
		t.Fatal(err)
	}
	overV4 := newDeviceVia(t, s, loopback, sPub, cPriv, MTU, addr)
	if n, err := fetch(t, overV4, tcpServer(t, 1000)); err != nil || n != 1000 {
		t.Fatalf("over IPv4: got %d bytes, %v", n, err)
	}
	overV4.dev.Down()
	handshakeAgain()
	overV6 := newDeviceVia(t, s, netip.IPv6Loopback(), sPub, cPriv, MTU, addr)
	if n, err := fetch(t, overV6, tcpServer(t, 1000)); err != nil || n != 1000 {
		t.Fatalf("over IPv6: got %d bytes, %v", n, err)
	}
	if status, _ := s.dev.IpcGet(); !strings.Contains(status, "endpoint=[::1]:") {
		t.Fatalf("the server didn't follow the device to IPv6:\n%s", status)
	}
}

// An address that can't be listened on (not ready yet, say) fails the start, and the session tries
// again the next round. Serving only the other one would never try it again.
func TestAnAddressThatFailsStopsTheStart(t *testing.T) {
	gone := netip.MustParseAddr("2001:db8::1") // a documentation address, on no interface
	sPriv, _ := keyPair(t)
	for _, hosts := range [][]netip.Addr{{loopback, gone}, {gone, loopback}, nil} {
		if s, err := Start(hosts, 0, sPriv); err == nil {
			s.Close()
			t.Fatalf("%v: a server that can't listen everywhere should fail", hosts)
		}
	}
	// One socket per family, so a reply knows which to go out of.
	two := []netip.Addr{loopback, netip.MustParseAddr("127.0.0.2")}
	if s, err := Start(two, 0, sPriv); err == nil {
		s.Close()
		t.Fatal("two IPv4 addresses should fail")
	}
	// What failed is closed.
	b := &hostBind{hosts: []netip.Addr{loopback, gone}}
	if _, _, err := b.Open(0); err == nil {
		t.Fatal("should fail")
	}
	if b.v4 != nil || b.v6 != nil {
		t.Fatal("a socket was left open")
	}
}

func TestTheBindKeepsOneSocketPerFamily(t *testing.T) {
	b := &hostBind{hosts: []netip.Addr{loopback, netip.IPv6Loopback()}}
	fns, port, err := b.Open(0)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	if len(fns) != 2 || port == 0 {
		t.Fatalf("%d receive funcs on port %d, want 2 on one port", len(fns), port)
	}
	for _, host := range []string{"127.0.0.1", "::1"} {
		c, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP(host)})
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		ep, _ := b.ParseEndpoint(c.LocalAddr().String())
		if err := b.Send([][]byte{[]byte("hi")}, ep); err != nil {
			t.Fatalf("send to %s: %v", host, err)
		}
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		buf := make([]byte, 10)
		n, from, err := c.ReadFromUDPAddrPort(buf)
		if err != nil || string(buf[:n]) != "hi" {
			t.Fatalf("from %s: %q %v", host, buf[:n], err)
		}
		if from.Port() != port || from.Addr().Unmap().String() != host {
			t.Fatalf("sent from %v, want %s port %d", from, host, port)
		}
	}

	only4 := &hostBind{hosts: []netip.Addr{loopback}}
	if _, _, err := only4.Open(0); err != nil {
		t.Fatal(err)
	}
	defer only4.Close()
	ep, _ := only4.ParseEndpoint("[::1]:9")
	if err := only4.Send([][]byte{{1}}, ep); err == nil {
		t.Fatal("sending to IPv6 without an IPv6 socket should fail")
	}
}
