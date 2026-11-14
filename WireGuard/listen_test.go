package main

import (
	"net/netip"
	"strings"
	"sync/atomic"
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
