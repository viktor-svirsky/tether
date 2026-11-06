package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"os"
	"testing"
	"time"
)

// A paused device stays on the server, so its session and handshake survive, and the server
// refuses its traffic until it's resumed (#74).

var deviceAddr = netip.MustParseAddr("10.7.0.2")

// pause pauses or resumes the one device of setup, keeping its key and address.
func pause(t *testing.T, s *Server, paused bool) {
	t.Helper()
	if err := s.SetPeers([]Peer{{PublicKey: s.keyOf(deviceAddr), Address: deviceAddr, Paused: paused}}); err != nil {
		t.Fatal(err)
	}
}

// handshakeOf is the device's last handshake as the server read it, zero for none.
func (s *Server) handshakeOf(addr netip.Addr) time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.shaken[addr]
}

// noTCP says the device's connection to target was refused, and the far end never saw one.
func noTCP(t *testing.T, c *client) {
	t.Helper()
	target, accepted := acceptOne(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if conn, err := c.net.DialContext(ctx, "tcp", target); err == nil {
		conn.Close()
		t.Fatal("a paused device opened a connection")
	}
	select {
	case <-accepted:
		t.Fatal("a paused device's connection reached the far end")
	case <-time.After(200 * time.Millisecond):
	}
}

// noUDP says a datagram from the device to an echo server got nothing back.
func noUDP(t *testing.T, c *client) {
	t.Helper()
	conn, err := c.net.Dial("udp", udpEcho(t))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write([]byte("ping"))
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Read(make([]byte, 10)); err == nil {
		t.Fatal("a paused device got a UDP reply")
	}
}

func TestAPausedDeviceKeepsItsHandshakeButGetsNoTraffic(t *testing.T) {
	s, c := setup(t)
	target := tcpServer(t, 10)
	fetchAndShake(t, s, c, target)
	shook := s.handshakeOf(deviceAddr)
	if shook.IsZero() {
		t.Fatal("no handshake before the pause")
	}
	pause(t, s, true)
	noTCP(t, c)
	noUDP(t, c)
	s.readHandshakes()
	if got := s.handshakeOf(deviceAddr); !got.Equal(shook) {
		t.Fatalf("handshake %v after the pause, want the one from before, %v", got, shook)
	}
	pause(t, s, false)
	if n, err := fetch(t, c, target); err != nil || n != 10 {
		t.Fatalf("after resuming got %d bytes, %v", n, err)
	}
	s.readHandshakes()
	if got := s.handshakeOf(deviceAddr); !got.Equal(shook) {
		t.Fatalf("handshake %v after resuming, want the same session, %v", got, shook)
	}
}

func TestPausingADeviceClosesItsConnections(t *testing.T) {
	s, c := setup(t)
	target, accepted := acceptOne(t)
	conn, err := c.net.Dial("tcp", target)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	var far net.Conn
	select {
	case far = <-accepted:
	case <-time.After(5 * time.Second):
		t.Fatal("the connection never reached the far end")
	}
	udp, err := c.net.Dial("udp", udpEcho(t))
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	udp.SetDeadline(time.Now().Add(5 * time.Second))
	udp.Write([]byte("ping"))
	if _, err := udp.Read(make([]byte, 10)); err != nil {
		t.Fatal(err)
	}
	pause(t, s, true)
	if !closedSoon(far) {
		t.Fatal("the paused device's connection is still open on the iPhone's side")
	}
	// The device's netstack says a reset its own way, not as syscall.ECONNRESET.
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil || errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("the paused device's connection is still open on its own side: %v", err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for s.tracked(deviceAddr) > 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if n := s.tracked(deviceAddr); n != 0 {
		t.Fatalf("%d of its connections and UDP flows still open", n)
	}
}

func TestPausingOneDeviceLeavesTheOthers(t *testing.T) {
	s, a, b := setupTwo(t)
	aAddr, bAddr := deviceAddr, netip.MustParseAddr("10.7.0.3")
	target := tcpServer(t, 1000)
	fetchAndShake(t, s, a, target)
	fetchAndShake(t, s, b, target)
	before := s.statsMessage()
	if err := s.SetPeers([]Peer{{PublicKey: s.keyOf(aAddr), Address: aAddr, Paused: true}, {PublicKey: s.keyOf(bAddr), Address: bAddr}}); err != nil {
		t.Fatal(err)
	}
	if n, err := fetch(t, b, target); err != nil || n != 1000 {
		t.Fatalf("the other device got %d bytes, %v", n, err)
	}
	noTCP(t, a)
	after := s.statsMessage()
	if after.Peers[0].Down != before.Peers[0].Down || after.Peers[0].Address != aAddr.String() {
		t.Fatalf("the paused device's count went from %+v to %+v, want it kept", before.Peers[0], after.Peers[0])
	}
}

// A device can be let in paused from the start, as after a relaunch: its handshake goes through,
// so it shows the tunnel up, and nothing else does.
func TestADeviceAddedPausedHandshakesButGetsNoTraffic(t *testing.T) {
	sPriv, sPub := keyPair(t)
	cPriv, cPub := keyPair(t)
	s, err := Start([]netip.Addr{loopback}, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	if err := s.SetPeers([]Peer{{PublicKey: cPub, Address: deviceAddr, Paused: true}}); err != nil {
		t.Fatal(err)
	}
	c := newClient(t, s, sPub, cPriv, deviceAddr)
	noTCP(t, c)
	s.readHandshakes()
	if s.handshakeOf(deviceAddr).IsZero() {
		t.Fatal("a paused device didn't get its handshake")
	}
}

// A router's clients send from their own addresses, and their traffic is the router's, so pausing
// the router stops them too.
func TestPausingARouterStopsItsClients(t *testing.T) {
	s, c := setupRouter(t, netip.MustParseAddr("192.168.4.20"))
	target := tcpServer(t, 10)
	if _, err := fetch(t, c, target); err != nil {
		t.Fatal(err)
	}
	if s.routerOf() != deviceAddr {
		t.Fatalf("router %v, want %v", s.routerOf(), deviceAddr)
	}
	pause(t, s, true)
	noTCP(t, c)
	if n := s.tracked(deviceAddr); n != 0 {
		t.Fatalf("%d of its clients' flows still open", n)
	}
	pause(t, s, false)
	if n, err := fetch(t, c, target); err != nil || n != 10 {
		t.Fatalf("after resuming its clients got %d bytes, %v", n, err)
	}
}

// A paused router still handshakes, so it looks online. If it kept the role, no other router could
// take over until it was resumed (#95).
func TestPausingTheRouterLetsAnotherRouterTakeOver(t *testing.T) {
	s, a, b, cb, target := twoRouters(t)
	if err := s.SetPeers([]Peer{{PublicKey: s.keyOf(a), Address: a, Paused: true}, {PublicKey: s.keyOf(b), Address: b}}); err != nil {
		t.Fatal(err)
	}
	if r := s.routerOf(); r.IsValid() {
		t.Fatalf("router %v, want none once it's paused", r)
	}
	if _, err := fetch(t, cb, target); err != nil {
		t.Fatalf("the other router's clients were refused: %v", err)
	}
	if s.routerOf() != b {
		t.Fatalf("router %v, want %v", s.routerOf(), b)
	}
}

// A resumed router gets the role back with its next packet for a client.
func TestAResumedRouterGetsTheRoleBackByItsNextPacketForAClient(t *testing.T) {
	s, c := setupRouter(t, netip.MustParseAddr("192.168.4.20"))
	target := tcpServer(t, 10)
	if _, err := fetch(t, c, target); err != nil {
		t.Fatal(err)
	}
	pause(t, s, true)
	if r := s.routerOf(); r.IsValid() {
		t.Fatalf("router %v, want none once it's paused", r)
	}
	pause(t, s, false)
	if n, err := fetch(t, c, target); err != nil || n != 10 {
		t.Fatalf("after resuming its clients got %d bytes, %v", n, err)
	}
	if s.routerOf() != deviceAddr {
		t.Fatalf("router %v, want %v back", s.routerOf(), deviceAddr)
	}
}

// The router you pause is often one that just kept another router out. That one takes over on its
// next packet rather than waiting out its refusal, since the role is free now.
func TestARouterKeptOutTakesOverOnceTheRouterIsPaused(t *testing.T) {
	s, a, b, cb, target := twoRouters(t)
	// The clock stops, so a refusal never wears off by itself.
	now := time.Now()
	s.mu.Lock()
	s.now = func() time.Time { return now }
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := cb.net.DialContext(ctx, "tcp", target); err == nil {
		t.Fatal("another router got through while the router was online")
	}
	// The refresher refuses it on its own goroutine, which on a busy runner under -race can come
	// after the device gave up its dial.
	deadline := time.Now().Add(15 * time.Second)
	for {
		s.mu.Lock()
		refused := s.refused
		s.mu.Unlock()
		if refused == b {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("refused %v, want %v kept out before the pause", refused, b)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := s.SetPeers([]Peer{{PublicKey: s.keyOf(a), Address: a, Paused: true}, {PublicKey: s.keyOf(b), Address: b}}); err != nil {
		t.Fatal(err)
	}
	if _, err := fetch(t, cb, target); err != nil {
		t.Fatalf("the router kept out was still refused: %v", err)
	}
	if s.routerOf() != b {
		t.Fatalf("router %v, want %v", s.routerOf(), b)
	}
}

// wireguard-go drops a paused device's packets from other addresses too, and that mustn't make it
// the router: it would take the role from a router whose clients haven't sent yet.
func TestAPausedDeviceDoesntBecomeTheRouter(t *testing.T) {
	s, c := setupRouter(t, netip.MustParseAddr("192.168.4.20"))
	pause(t, s, true)
	noTCP(t, c)
	time.Sleep(time.Second) // the refresher makes a router on its own goroutine
	if r := s.routerOf(); r.IsValid() {
		t.Fatalf("router %v, want none while it's paused", r)
	}
}

// The refresher can pick a device to make the router just before it's paused. It isn't made one then.
func TestAPausedCandidateIsntMadeTheRouter(t *testing.T) {
	s, _ := setup(t)
	pause(t, s, true)
	s.makeRouter(deviceAddr)
	if r := s.routerOf(); r.IsValid() {
		t.Fatalf("router %v, want none while it's paused", r)
	}
}
