package main

import (
	"errors"
	"net"
	"net/netip"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
)

// handshakesHeard counts the handshakes the server answers, from wireguard-go's log.
func handshakesHeard(t *testing.T, s *Server) *atomic.Int32 {
	t.Helper()
	var n atomic.Int32
	heard := func(line string) {
		if strings.Contains(line, "Received handshake initiation") {
			n.Add(1)
		}
	}
	s.heard.Store(&heard)
	t.Cleanup(func() { s.heard.Store(nil) })
	return &n
}

// On a carrier that gives the iPhone IPv6 only, the hotspot comes back with 172.20.10.1 before its
// IPv6 address. Listening there too, once it shows up, keeps the devices' sessions: they carry on
// with no new handshake, and a device that only has IPv6 connects there (#219).
func TestListeningOnAnAddressThatShowsUpLaterKeepsTheSessions(t *testing.T) {
	s, sPub := startOn(t, loopback)
	aPriv, aPub := keyPair(t)
	bPriv, bPub := keyPair(t)
	a, b := netip.MustParseAddr("10.7.0.2"), netip.MustParseAddr("10.7.0.3")
	if err := s.SetPeers([]Peer{{PublicKey: aPub, Address: a}, {PublicKey: bPub, Address: b}}); err != nil {
		t.Fatal(err)
	}
	overV4 := newDeviceVia(t, s, loopback, sPub, aPriv, MTU, a)
	addr := tcpServer(t, 1000)
	if n, err := fetch(t, overV4, addr); err != nil || n != 1000 {
		t.Fatalf("before: got %d bytes, %v", n, err)
	}
	port := s.port(t)
	handshakes := handshakesHeard(t, s)

	if err := s.ListenOn([]netip.Addr{loopback, netip.IPv6Loopback()}); err != nil {
		t.Fatal(err)
	}
	if n, err := fetch(t, overV4, addr); err != nil || n != 1000 {
		t.Fatalf("after, over IPv4: got %d bytes, %v", n, err)
	}
	if got := handshakes.Load(); got != 0 {
		t.Fatalf("%d new handshakes over IPv4, want the session kept", got)
	}
	if got := s.port(t); got != port {
		t.Fatalf("listening on port %d, want %d where the devices' configs point", got, port)
	}
	overV6 := newDeviceVia(t, s, netip.IPv6Loopback(), sPub, bPriv, MTU, b)
	if n, err := fetch(t, overV6, addr); err != nil || n != 1000 {
		t.Fatalf("over IPv6: got %d bytes, %v", n, err)
	}
	if handshakes.Load() == 0 {
		t.Fatal("the IPv6 device's handshake wasn't counted, so the count above proves nothing")
	}
}

// An address the iPhone doesn't have (yet) can't be listened on. The server keeps listening where
// it did, so the devices there carry on. Tether tries the new address again the next round.
func TestAnAddressThatCantBeListenedOnLeavesTheOldOnes(t *testing.T) {
	s, c := setup(t)
	addr := tcpServer(t, 1000)
	if n, err := fetch(t, c, addr); err != nil || n != 1000 {
		t.Fatalf("before: got %d bytes, %v", n, err)
	}
	port := s.port(t)
	gone := netip.MustParseAddr("2001:db8::1") // a documentation address, on no interface
	if err := s.ListenOn([]netip.Addr{loopback, gone}); err == nil {
		t.Fatal("listened on an address this machine doesn't have")
	}
	if n, err := fetch(t, c, addr); err != nil || n != 1000 {
		t.Fatalf("after: got %d bytes, %v", n, err)
	}
	if got := s.port(t); got != port {
		t.Fatalf("listening on port %d, want %d", got, port)
	}
}

// Another app's socket can hold Tether's port on every address: one that got 51820 for port 0, say.
// The server still listens on the hotspot's address, and its devices' packets come to it, not to
// the other socket. A socket of either family can hold it: Darwin keeps a dual-stack one with the
// IPv4 ones too.
func TestAnotherSocketOnEveryAddressLeavesThePort(t *testing.T) {
	for _, network := range []string{"udp4", "udp"} {
		t.Run(network, func(t *testing.T) {
			other, err := net.ListenUDP(network, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer other.Close()
			port := other.LocalAddr().(*net.UDPAddr).Port
			heard := make(chan struct{}, 1)
			go func() {
				buf := make([]byte, 2048)
				if _, _, err := other.ReadFromUDP(buf); err == nil {
					heard <- struct{}{}
				}
			}()

			sPriv, sPub := keyPair(t)
			cPriv, cPub := keyPair(t)
			s, err := Start([]netip.Addr{loopback}, port, sPriv)
			if err != nil {
				t.Fatalf("can't listen on port %d next to the other socket: %v", port, err)
			}
			t.Cleanup(s.Close)
			viaLoopback(s)
			addr := netip.MustParseAddr("10.7.0.2")
			if err := s.SetPeers([]Peer{{PublicKey: cPub, Address: addr}}); err != nil {
				t.Fatal(err)
			}
			c := newDeviceVia(t, s, loopback, sPub, cPriv, MTU, addr)
			if n, err := fetch(t, c, tcpServer(t, 1000)); err != nil || n != 1000 {
				t.Fatalf("got %d bytes, %v", n, err)
			}
			select {
			case <-heard:
				t.Fatal("the other socket got the device's packets")
			default:
			}
		})
	}
}

// A socket on the hotspot's own address and port still keeps the server out: two servers on one
// address would each get some of the devices' packets.
func TestAnotherSocketOnTheSameAddressRefusesThePort(t *testing.T) {
	other, err := net.ListenUDP("udp4", net.UDPAddrFromAddrPort(netip.AddrPortFrom(loopback, 0)))
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	sPriv, _ := keyPair(t)
	s, err := Start([]netip.Addr{loopback}, other.LocalAddr().(*net.UDPAddr).Port, sPriv)
	if err == nil {
		s.Close()
		t.Fatal("listened on an address and port another socket has")
	}
	if !errors.Is(err, syscall.EADDRINUSE) {
		t.Fatalf("got %v, want address already in use", err)
	}
}
