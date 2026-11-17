package main

import (
	"encoding/binary"
	"errors"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"
)

// The counters on the Diagnostics screen (#256), see diagnostics.go. Each is driven the way a device
// would make it move.

// junk sends n UDP datagrams of a type WireGuard doesn't have to the server's port, and returns
// where they came from.
func junk(t *testing.T, s *Server, n int) netip.AddrPort {
	t.Helper()
	c, err := net.DialUDP("udp4", nil, net.UDPAddrFromAddrPort(netip.AddrPortFrom(loopback, uint16(s.port(t)))))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	msg := make([]byte, 32) // wireguard-go reads nothing shorter
	binary.LittleEndian.PutUint32(msg, 9)
	for range n {
		if _, err := c.Write(msg); err != nil {
			t.Fatal(err)
		}
	}
	return c.LocalAddr().(*net.UDPAddr).AddrPort()
}

// diagWithin waits up to 5 s for the counters to say what ok wants, since wireguard-go reads and
// logs on its own goroutines.
func diagWithin(t *testing.T, s *Server, ok func(diagStats) bool) diagStats {
	t.Helper()
	var d diagStats
	if !waitFor(5*time.Second, func() bool { d = s.diagStats(); return ok(d) }) {
		t.Fatalf("diagnostics %+v", d)
	}
	return d
}

// A new server says where it listens and has counted nothing.
func TestDiagnosticsStartAtZero(t *testing.T) {
	s, _ := startOneDevice(t)
	want := diagStats{Listening: []string{netip.AddrPortFrom(loopback, uint16(s.port(t))).String()}}
	if d := s.diagStats(); d.UDPIn != 0 || d.PacketsIn != 0 || d.TCPTried != 0 || d.UDPFrom != "" || d.LastError != "" ||
		len(d.Listening) != 1 || d.Listening[0] != want.Listening[0] {
		t.Fatalf("diagnostics %+v, want %+v", d, want)
	}
}

// Each datagram that reaches the port counts, with its sender, and junk is a rejected message.
func TestDiagnosticsCountUDPInAndItsSender(t *testing.T) {
	s, _ := startOneDevice(t)
	from := junk(t, s, 3)
	d := diagWithin(t, s, func(d diagStats) bool { return d.UDPIn == 3 && d.Rejected == 3 })
	if d.UDPFrom != from.String() {
		t.Fatalf("last UDP from %q, want %v", d.UDPFrom, from)
	}
}

// A device whose key the server doesn't let in reaches the port, and its handshake is rejected.
func TestDiagnosticsCountAHandshakeFromAKeyNotLetIn(t *testing.T) {
	s, sPub := startOneDevice(t)
	knock(t, s, sPub)
	diagWithin(t, s, func(d diagStats) bool { return d.UDPIn >= 1 && d.Rejected >= 1 })
}

// A device's packets into the tunnel count, and so does the connection the iPhone makes for it.
func TestDiagnosticsCountPacketsInAndTCPTried(t *testing.T) {
	s, c := setup(t)
	if _, err := fetch(t, c, tcpServer(t, 1000)); err != nil {
		t.Fatal(err)
	}
	d := diagWithin(t, s, func(d diagStats) bool { return d.PacketsIn >= 3 })
	if d.TCPTried != 1 || d.TCPFailed != 0 || d.Rejected != 0 || d.LastError != "" {
		t.Fatalf("diagnostics %+v, want one connection that worked and no error", d)
	}
}

// A connection the iPhone can't make counts as failed, and says why.
func TestDiagnosticsCountAFailedTCPConnection(t *testing.T) {
	s, c := setup(t)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	closed := viaRemote(l.Addr().String())
	l.Close() // nothing listens there now, so the dial is refused
	if _, err := fetch(t, c, closed); err == nil {
		t.Fatal("a connection to a closed port went through")
	}
	d := diagWithin(t, s, func(d diagStats) bool { return d.TCPFailed == 1 })
	if d.TCPTried != 1 || !strings.HasPrefix(d.LastError, "TCP to "+closed+": ") {
		t.Fatalf("diagnostics %+v, want the failed connection as the last error", d)
	}
}

// A device's UDP the iPhone can't send on counts, and says why.
func TestDiagnosticsCountAFailedUDPSend(t *testing.T) {
	s, c := setup(t)
	s.mu.Lock()
	s.sendTo = func(*net.UDPConn, []byte, netip.AddrPort) error { return errors.New("no buffer space available") }
	s.mu.Unlock()
	to := net.JoinHostPort(remote, "9")
	conn, err := c.net.Dial("udp", to)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	d := diagWithin(t, s, func(d diagStats) bool { conn.Write([]byte("hello")); return d.UDPFailed >= 1 })
	if d.LastError != "UDP to "+to+": no buffer space available" {
		t.Fatalf("last error %q", d.LastError)
	}
	// A packet left queued when its cone closed didn't fail.
	s.diag.sent(netip.MustParseAddrPort(to), net.ErrClosed)
	if n := s.diagStats().UDPFailed; n != d.UDPFailed {
		t.Fatalf("%d UDP sends failed after a closed cone's, want %d", n, d.UDPFailed)
	}
}

// A device sending from an address its config doesn't give it gets its packets dropped, and counted.
// IPv6 here: an IPv4 one would make it the router.
func TestDiagnosticsCountPacketsFromAnAddressTheDeviceDoesntHave(t *testing.T) {
	sPriv, sPub := keyPair(t)
	cPriv, cPub := keyPair(t)
	s, err := Start([]netip.Addr{loopback}, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	addr := netip.MustParseAddr("10.7.0.2")
	if err := s.SetPeers([]Peer{{PublicKey: cPub, Address: addr}}); err != nil {
		t.Fatal(err)
	}
	c := newClientAt(t, s, sPub, cPriv, addr, netip.MustParseAddr("fd00::2"))
	conn, err := c.net.Dial("udp", "[2001:db8::1]:9")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	diagWithin(t, s, func(d diagStats) bool { conn.Write([]byte("hello")); return d.Disallowed >= 1 })
}

// A reply the iPhone can't send counts, and says why. A broadcast address refuses a socket without
// SO_BROADCAST, the way iOS refuses a reply with Local Network off.
func TestDiagnosticsCountARepliesThatCouldntBeSent(t *testing.T) {
	s, _ := startOneDevice(t)
	to := netip.MustParseAddrPort("255.255.255.255:9")
	if err := s.bind.Send([][]byte{[]byte("hello")}, endpoint{to}); err == nil {
		t.Fatal("a send to the broadcast address went out")
	}
	d := s.diagStats()
	if d.ReplyFailed != 1 || !strings.HasPrefix(d.ReplyError, "to 255.255.255.255:9: ") {
		t.Fatalf("diagnostics %+v, want one reply that couldn't be sent", d)
	}
	// One of a family it doesn't listen on has no socket to go out of.
	if err := s.bind.Send([][]byte{[]byte("hello")}, endpoint{netip.MustParseAddrPort("[::1]:9")}); err == nil {
		t.Fatal("a send to IPv6 went out of an IPv4 socket")
	}
	if d := s.diagStats(); d.ReplyFailed != 2 || !strings.HasPrefix(d.ReplyError, "to [::1]:9: ") {
		t.Fatalf("diagnostics %+v, want two", d)
	}
}

// Without IPv4, a connection goes through the carrier's NAT64, and the screen shows its prefix. The
// first dial failing isn't a failed connection: the one through NAT64 worked.
func TestDiagnosticsShowTheNAT64Prefix(t *testing.T) {
	s, c := setup(t)
	withoutIPv4(s)
	if _, err := fetch(t, c, tcpServer(t, 100)); err != nil {
		t.Fatal(err)
	}
	d := diagWithin(t, s, func(d diagStats) bool { return d.NAT64 != "" })
	if d.NAT64 != carrierNAT64.String() || d.TCPTried != 1 || d.TCPFailed != 0 {
		t.Fatalf("diagnostics %+v, want the carrier's prefix and one connection that worked", d)
	}
}
