package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/curve25519"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
	"gvisor.dev/gvisor/pkg/tcpip/header"
)

var loopback = netip.MustParseAddr("127.0.0.1")

func keyPair(t *testing.T) (priv, pub [32]byte) {
	rand.Read(priv[:])
	priv[0] &= 248
	priv[31] = priv[31]&127 | 64
	p, err := curve25519.X25519(priv[:], curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	copy(pub[:], p)
	return
}

func (s *Server) port(t *testing.T) int {
	status, _ := s.dev.IpcGet()
	for _, line := range strings.Split(status, "\n") {
		if v, ok := strings.CutPrefix(line, "listen_port="); ok {
			var p int
			fmt.Sscan(v, &p)
			return p
		}
	}
	t.Fatal("no listen_port")
	return 0
}

// client is a device: a userspace WireGuard client whose own netstack dials through the tunnel.
type client struct {
	net *netstack.Net
	dev *device.Device
}

func newClient(t *testing.T, s *Server, serverPub, priv [32]byte, addr netip.Addr) *client {
	return newClientWithMTU(t, s, serverPub, priv, addr, MTU)
}

// newClientWithMTU is a device whose config has its own MTU, like one set up before the MTU changed.
func newClientWithMTU(t *testing.T, s *Server, serverPub, priv [32]byte, addr netip.Addr, mtu int) *client {
	return newDevice(t, s, serverPub, priv, mtu, addr)
}

// newClientAt is a device with more than one address, like a laptop that also has an IPv6 address
// from the hotspot's Wi-Fi.
func newClientAt(t *testing.T, s *Server, serverPub, priv [32]byte, addrs ...netip.Addr) *client {
	return newDevice(t, s, serverPub, priv, MTU, addrs...)
}

func newDevice(t *testing.T, s *Server, serverPub, priv [32]byte, mtu int, addrs ...netip.Addr) *client {
	tdev, tnet, err := netstack.CreateNetTUN(addrs, nil, mtu)
	if err != nil {
		t.Fatal(err)
	}
	dev := device.NewDevice(tdev, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "client: "))
	err = dev.IpcSet(fmt.Sprintf("private_key=%s\npublic_key=%s\nendpoint=127.0.0.1:%d\nallowed_ip=0.0.0.0/0\nallowed_ip=::/0\n",
		hex.EncodeToString(priv[:]), hex.EncodeToString(serverPub[:]), s.port(t)))
	if err != nil {
		t.Fatal(err)
	}
	if err := dev.Up(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(dev.Close)
	return &client{tnet, dev}
}

// setup starts a server with one device and returns both.
func setup(t *testing.T) (*Server, *client) { return setupWithMTU(t, MTU) }

// setupWithMTU is setup with a device whose config has its own MTU.
func setupWithMTU(t *testing.T, mtu int) (*Server, *client) {
	sPriv, sPub := keyPair(t)
	cPriv, cPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	addr := netip.MustParseAddr("10.7.0.2")
	if err := s.SetPeers([]Peer{{PublicKey: cPub, Address: addr}}); err != nil {
		t.Fatal(err)
	}
	return s, newClientWithMTU(t, s, sPub, cPriv, addr, mtu)
}

// setupTwo starts a server with two devices, a at 10.7.0.2 and b at 10.7.0.3.
func setupTwo(t *testing.T) (s *Server, a, b *client) {
	sPriv, sPub := keyPair(t)
	aPriv, aPub := keyPair(t)
	bPriv, bPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	aAddr, bAddr := netip.MustParseAddr("10.7.0.2"), netip.MustParseAddr("10.7.0.3")
	if err := s.SetPeers([]Peer{{PublicKey: aPub, Address: aAddr}, {PublicKey: bPub, Address: bAddr}}); err != nil {
		t.Fatal(err)
	}
	return s, newClient(t, s, sPub, aPriv, aAddr), newClient(t, s, sPub, bPriv, bAddr)
}

// fetchAndShake makes one connection, so the device has done its handshake, then reads the
// handshakes at once instead of waiting for the refresher's next tick.
func fetchAndShake(t *testing.T, s *Server, c *client, addr string) {
	if _, err := fetch(t, c, addr); err != nil {
		t.Fatal(err)
	}
	s.readHandshakes()
}

// remote stands in for a host on the internet. The client's netstack won't send to 127.0.0.1, so
// the tests dial remote:port and the server's dialer sends it to the test listener on loopback.
const remote = "198.51.100.7"

func toLoopback(ctx context.Context, network, address string) (net.Conn, error) {
	_, port, _ := net.SplitHostPort(address)
	return (&net.Dialer{Timeout: 5 * time.Second}).DialContext(ctx, network, net.JoinHostPort("127.0.0.1", port))
}

// viaLoopback points the server's TCP dials and UDP sends for remote at loopback, and labels
// loopback replies as coming from remote.
func viaLoopback(s *Server) {
	s.dial = toLoopback
	r, lo := netip.MustParseAddr(remote), netip.MustParseAddr("127.0.0.1")
	s.toNet = func(a netip.AddrPort) netip.AddrPort {
		if a.Addr() == r {
			return netip.AddrPortFrom(lo, a.Port())
		}
		return a
	}
	s.fromNet = func(a netip.AddrPort) netip.AddrPort {
		if a.Addr() == lo {
			return netip.AddrPortFrom(r, a.Port())
		}
		return a
	}
}

func viaRemote(addr string) string {
	_, port, _ := net.SplitHostPort(addr)
	return net.JoinHostPort(remote, port)
}

// tcpServer answers each connection with n bytes, then closes it.
func tcpServer(t *testing.T, n int) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				buf := make([]byte, 5)
				io.ReadFull(c, buf)
				c.Write(make([]byte, n))
			}()
		}
	}()
	return viaRemote(l.Addr().String())
}

func udpEcho(t *testing.T) string {
	c, err := net.ListenPacket("udp", "127.0.0.1:0")
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
	return viaRemote(c.LocalAddr().String())
}

func fetch(t *testing.T, c *client, addr string) (int, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	conn, err := c.net.DialContext(ctx, "tcp", addr)
	if err != nil {
		return 0, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(15 * time.Second))
	conn.Write([]byte("hello"))
	b, err := io.ReadAll(conn)
	return len(b), err
}

func TestTCPGoesThroughTheTunnel(t *testing.T) {
	s, c := setup(t)
	n, err := fetch(t, c, tcpServer(t, 100_000))
	if err != nil || n != 100_000 {
		t.Fatalf("got %d bytes, %v", n, err)
	}
	s.readHandshakes()
	st := s.Stats()
	if st.Down != 100_000 || st.Up != 5 {
		t.Fatalf("counted up %d down %d", st.Up, st.Down)
	}
	if len(st.Connected) != 1 || st.Connected[0] != "10.7.0.2" {
		t.Fatalf("connected %v, want the device's tunnel address", st.Connected)
	}
}

func TestUDPGoesThroughTheTunnel(t *testing.T) {
	s, c := setup(t)
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
		if err != nil || string(buf[:n]) != msg {
			t.Fatalf("echo %d: %q %v", i, buf[:n], err)
		}
	}
	if n := s.tracked(netip.MustParseAddr("10.7.0.2")); n != 1 {
		t.Fatalf("want one open flow, got %d", n)
	}
	if st := s.Stats(); st.Up != 18 || st.Down != 18 {
		t.Fatalf("counted up %d down %d, want 18 each", st.Up, st.Down)
	}
}

// A device set up when the MTU was 1280 keeps that in its config. Its SYN asks for segments that
// fit 1280, so a big download still arrives whole.
func TestADeviceWithTheOldMTUStillDownloads(t *testing.T) {
	_, c := setupWithMTU(t, 1280)
	// Over a hundred full segments. More only makes the race detector's run slow, not the test stronger.
	if n, err := fetch(t, c, tcpServer(t, 200_000)); err != nil || n != 200_000 {
		t.Fatalf("got %d bytes, %v", n, err)
	}
}

func TestAnUnknownKeyGetsNothing(t *testing.T) {
	sPriv, sPub := keyPair(t)
	cPriv, cPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s) // so a stranger let in by mistake would reach the listener and fail the test
	s.SetPeers([]Peer{{PublicKey: cPub, Address: netip.MustParseAddr("10.7.0.2")}})
	_ = cPriv
	// The right server key, but a client key the server was never given.
	priv, _ := keyPair(t)
	stranger := newClient(t, s, sPub, priv, netip.MustParseAddr("10.7.0.2"))
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := stranger.net.DialContext(ctx, "tcp", tcpServer(t, 10)); err == nil {
		t.Fatal("a device without a key got through")
	}
}

func TestRemovingAPeerLocksItOut(t *testing.T) {
	s, c := setup(t)
	addr := tcpServer(t, 10)
	if _, err := fetch(t, c, addr); err != nil {
		t.Fatal(err)
	}
	if err := s.SetPeers(nil); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := c.net.DialContext(ctx, "tcp", addr); err == nil {
		t.Fatal("a removed device still got through")
	}
}

func TestParsePeers(t *testing.T) {
	keys := make([]byte, 64)
	keys[32] = 7
	peers, err := parsePeers(keys, "10.7.0.2\n10.7.0.3")
	if err != nil || len(peers) != 2 || peers[1].PublicKey[0] != 7 || peers[1].Address.String() != "10.7.0.3" {
		t.Fatalf("%+v %v", peers, err)
	}
	if _, err := parsePeers(keys, "10.7.0.2"); err == nil {
		t.Fatal("two keys and one address should be refused")
	}
	if _, err := parsePeers(make([]byte, 64), "10.7.0.2\n10.7.0.3"); err == nil {
		t.Fatal("two devices with the same key should be refused")
	}
	if _, err := parsePeers(keys, "10.7.0.2\n10.7.0.2"); err == nil {
		t.Fatal("two devices with the same address should be refused")
	}
	if _, err := parsePeers(keys[:32], "nonsense"); err == nil {
		t.Fatal("a bad address should be refused")
	}
	if peers, err := parsePeers(nil, ""); err != nil || len(peers) != 0 {
		t.Fatal("no devices is fine")
	}
	if _, err := parsePeers(keys[:32], "10.7.0.2 router"); err == nil {
		t.Fatal("anything after the address should be refused, a router is found by its traffic")
	}
}

func TestCloseDuringUDPTrafficReturns(t *testing.T) {
	sPriv, sPub := keyPair(t)
	cPriv, cPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	viaLoopback(s)
	addr := netip.MustParseAddr("10.7.0.2")
	s.SetPeers([]Peer{{PublicKey: cPub, Address: addr}})
	c := newClient(t, s, sPub, cPriv, addr)
	echo := udpEcho(t)
	_, port, _ := net.SplitHostPort(echo)
	stop := make(chan struct{})
	var sender sync.WaitGroup
	sender.Add(1)
	go func() {
		defer sender.Done()
		// A new client port each time, so every packet asks the forwarder for a new flow.
		for {
			select {
			case <-stop:
				return
			default:
			}
			conn, err := c.net.Dial("udp", net.JoinHostPort(remote, port))
			if err == nil {
				conn.Write([]byte("x"))
				conn.Close()
			}
		}
	}()
	// The client is closed in cleanup, so the sender must be gone first.
	defer sender.Wait()
	defer close(stop)
	time.Sleep(500 * time.Millisecond)
	other, _ := keyPair(t)
	done := make(chan struct{})
	go func() {
		s.SetPeers([]Peer{{PublicKey: cPub, Address: addr}, {PublicKey: other, Address: netip.MustParseAddr("10.7.0.3")}})
		s.Close()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Close hung while UDP flows were opening")
	}
	// wireguard-go's own netstack tun, the test client, races its Close against a packet it is
	// still taking in. Let the last ones land before cleanup closes it.
	time.Sleep(200 * time.Millisecond)
}

func TestAddingADeviceKeepsTheOthersConnected(t *testing.T) {
	s, c := setup(t)
	addr := tcpServer(t, 10)
	fetchAndShake(t, s, c, addr)
	var mine [32]byte
	for k := range s.peers {
		mine = k
	}
	// The status text lists peers in no fixed order, so find this device's own lines.
	handshake := func() string {
		status, _ := s.dev.IpcGet()
		current := ""
		for _, line := range strings.Split(status, "\n") {
			if v, ok := strings.CutPrefix(line, "public_key="); ok {
				current = v
			}
			if v, ok := strings.CutPrefix(line, "last_handshake_time_nsec="); ok && current == hex.EncodeToString(mine[:]) {
				return v
			}
		}
		return ""
	}
	before := handshake()
	other, _ := keyPair(t)
	if err := s.SetPeers([]Peer{{PublicKey: mine, Address: netip.MustParseAddr("10.7.0.2")}, {PublicKey: other, Address: netip.MustParseAddr("10.7.0.3")}}); err != nil {
		t.Fatal(err)
	}
	if _, err := fetch(t, c, addr); err != nil {
		t.Fatal(err)
	}
	// replace_peers would have dropped the session, and this fetch would have made a new handshake.
	if after := handshake(); before == "" || after != before {
		t.Fatalf("the first device had to reconnect: handshake %s then %s", before, after)
	}
}

func TestLocalDestinationsStayInside(t *testing.T) {
	for _, a := range []string{"127.0.0.1", "224.0.0.251", "239.255.255.250", "255.255.255.255", "169.254.1.1", "10.7.0.3", "0.0.0.0", "::1", "ff02::fb"} {
		if forwardable(netip.MustParseAddr(a)) {
			t.Errorf("%s should stay inside", a)
		}
	}
	for _, a := range []string{"1.1.1.1", "172.20.10.1", "2606:4700::1111"} {
		if !forwardable(netip.MustParseAddr(a)) {
			t.Errorf("%s should go out", a)
		}
	}
}

// Private ranges stay reachable on purpose: a device reaches what the iPhone reaches, a network
// behind a VPN on the iPhone included. Blocking them would cut devices off from that VPN.
func TestPrivateNetworksBehindTheIPhoneAreReachable(t *testing.T) {
	for _, a := range []string{"10.0.0.5", "10.8.0.1", "172.16.0.1", "192.168.1.10", "100.64.0.1", "fd00::1"} {
		if !forwardable(netip.MustParseAddr(a)) {
			t.Errorf("%s should go out, it may be behind the iPhone's VPN", a)
		}
	}
}

func TestRemovingADeviceClosesItsConnections(t *testing.T) {
	s, c := setup(t)
	// A server that answers, then holds the connection open.
	l, _ := net.Listen("tcp", "127.0.0.1:0")
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				return
			}
			go func() { conn.Write([]byte("hi")); time.Sleep(time.Minute); conn.Close() }()
		}
	}()
	conn, err := c.net.Dial("tcp", viaRemote(l.Addr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 2)
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatal(err)
	}
	if err := s.SetPeers(nil); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		s.mu.Lock()
		open := len(s.flows[netip.MustParseAddr("10.7.0.2")])
		s.mu.Unlock()
		if open == 0 {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("the removed device's connection is still open")
}

func TestTotalsSurviveRemovingADevice(t *testing.T) {
	s, c := setup(t)
	fetchAndShake(t, s, c, tcpServer(t, 1000))
	before := s.Stats()
	if before.Down != 1000 {
		t.Fatalf("counted down %d, want 1000", before.Down)
	}
	s.SetPeers(nil)
	if after := s.Stats(); after.Up != before.Up || after.Down != before.Down {
		t.Fatalf("before %+v, after removal %+v", before, after)
	}
}

// The QR code changes once a new device shows as connected, so it mustn't wait for the
// refresher's next tick.
func TestANewDeviceIsConnectedWithinSeconds(t *testing.T) {
	s, c := setup(t)
	if _, err := fetch(t, c, tcpServer(t, 10)); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(handshakeEvery / 2)
	for time.Now().Before(deadline) {
		if st := s.Stats(); len(st.Connected) == 1 {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("not connected within %v, the refresher reads every %v", handshakeEvery/2, handshakeEvery)
}

func TestADeviceIsConnectedUntilItsHandshakeIsOld(t *testing.T) {
	s, c := setup(t)
	if st := s.Stats(); len(st.Connected) != 0 {
		t.Fatalf("connected %v before any handshake, want none", st.Connected)
	}
	fetchAndShake(t, s, c, tcpServer(t, 1000))
	if st := s.Stats(); len(st.Connected) != 1 || st.Connected[0] != "10.7.0.2" {
		t.Fatalf("connected %v, want the device's tunnel address", st.Connected)
	}
	s.mu.Lock()
	s.now = func() time.Time { return time.Now().Add(onlineWithin) }
	s.mu.Unlock()
	st := s.Stats()
	if len(st.Connected) != 0 {
		t.Fatalf("connected %v after the handshake aged, want none", st.Connected)
	}
	if st.Down != 1000 {
		t.Fatalf("counted down %d after the handshake aged, want the traffic kept", st.Down)
	}
}

func TestARemovedDeviceIsNotConnected(t *testing.T) {
	s, c := setup(t)
	fetchAndShake(t, s, c, tcpServer(t, 1000))
	s.SetPeers(nil)
	if st := s.Stats(); len(st.Connected) != 0 {
		t.Fatalf("connected %v, want none", st.Connected)
	}
}

func TestOneWayUDPOutlivesTheQuietDirection(t *testing.T) {
	s := &Server{fromNet: func(a netip.AddrPort) netip.AddrPort { return a }}
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		t.Fatal(err)
	}
	c := &cone{device: netip.MustParseAddrPort("10.7.0.2:5000"), owner: netip.MustParseAddr("10.7.0.2"), conn: conn, done: make(chan struct{}), lock: &s.mu}
	defer c.Close()
	c.last.Store(time.Now().Add(-udpIdle - time.Second).UnixNano()) // nothing came back for a minute
	go func() { c.last.Store(time.Now().UnixNano()) }()             // but the device just sent
	time.Sleep(10 * time.Millisecond)
	done := make(chan struct{})
	go func() { s.receive(c); close(done) }()
	select {
	case <-done:
		t.Fatal("the quiet direction ended the flow while the device was sending")
	case <-time.After(200 * time.Millisecond):
	}
}

// A DNS lookup uses a new port every time, so its cone goes after dnsIdle, not a minute later.
func TestALookupFlowEndsSooner(t *testing.T) {
	ended := func(dnsOnly bool) bool {
		s := &Server{fromNet: func(a netip.AddrPort) netip.AddrPort { return a }}
		conn, err := net.ListenUDP("udp4", nil)
		if err != nil {
			t.Fatal(err)
		}
		c := &cone{device: netip.MustParseAddrPort("10.7.0.2:5000"), owner: netip.MustParseAddr("10.7.0.2"), conn: conn, done: make(chan struct{}), lock: &s.mu}
		defer c.Close()
		c.dnsOnly.Store(dnsOnly)
		c.last.Store(time.Now().Add(-dnsIdle - time.Second).UnixNano())
		done := make(chan struct{})
		go func() { s.receive(c); close(done) }()
		select {
		case <-done:
			return true
		case <-time.After(500 * time.Millisecond):
			return false
		}
	}
	if !ended(true) {
		t.Fatal("a lookup's cone outlived dnsIdle")
	}
	if ended(false) {
		t.Fatal("another flow ended after dnsIdle instead of udpIdle")
	}
}

// A port that sent a lookup and then talks to anything else is no longer a lookup.
func TestAPortThatSendsElsewhereKeepsTheMinute(t *testing.T) {
	s, _ := setup(t)
	c := s.cone(netip.MustParseAddrPort("10.7.0.2:5000"))
	if c == nil {
		t.Fatal("no cone")
	}
	c.sentTo(netip.MustParseAddrPort(remote + ":53"))
	if c.idle() != dnsIdle {
		t.Fatalf("idle %v after a lookup, want %v", c.idle(), dnsIdle)
	}
	c.sentTo(netip.MustParseAddrPort("1.1.1.1:443"))
	c.sentTo(netip.MustParseAddrPort("1.1.1.1:53"))
	if c.idle() != udpIdle {
		t.Fatalf("idle %v after other traffic, want %v", c.idle(), udpIdle)
	}
}

// Past maxCones a new device port gets nothing, instead of one more socket and two goroutines.
func TestConesStopAtTheCap(t *testing.T) {
	s, _ := setup(t)
	s.maxCones = 2
	for port := uint16(5000); port < 5002; port++ {
		if s.cone(netip.AddrPortFrom(netip.MustParseAddr("10.7.0.2"), port)) == nil {
			t.Fatalf("cone %d refused under the cap", port)
		}
	}
	if s.cone(netip.MustParseAddrPort("10.7.0.2:5002")) != nil {
		t.Fatal("a third cone was made past a cap of 2")
	}
	if s.cone(netip.MustParseAddrPort("10.7.0.2:5000")) == nil {
		t.Fatal("an existing cone was refused at the cap")
	}
}

// A full-cone NAT lets a reply from anyone reach the device port, which is what makes a call or a
// game connect directly after STUN.
func TestUDPIsFullCone(t *testing.T) {
	_, c := setup(t)
	// A tells the device which iPhone port it saw, like a STUN server. B then sends to that port.
	a, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	b, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	go func() {
		buf := make([]byte, 100)
		for {
			_, from, err := a.ReadFromUDPAddrPort(buf)
			if err != nil {
				return
			}
			b.WriteToUDPAddrPort([]byte("from b"), from) // B was never contacted by the device
		}
	}()
	conn, err := c.net.ListenUDP(&net.UDPAddr{IP: net.IPv4(10, 7, 0, 2), Port: 40000})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	aPort := a.LocalAddr().(*net.UDPAddr).Port
	// Sent again each second: under load WireGuard's first handshake can be lost, and its own
	// retry waits five seconds.
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		for {
			conn.WriteTo([]byte("hello"), &net.UDPAddr{IP: net.ParseIP(remote), Port: aPort})
			select {
			case <-stop:
				return
			case <-time.After(time.Second):
			}
		}
	}()
	conn.SetReadDeadline(time.Now().Add(15 * time.Second))
	buf := make([]byte, 100)
	n, from, err := conn.ReadFrom(buf)
	if err != nil || string(buf[:n]) != "from b" {
		t.Fatalf("got %q from %v, %v", buf[:n], from, err)
	}
	if want := b.LocalAddr().(*net.UDPAddr).Port; from.(*net.UDPAddr).Port != want {
		t.Fatalf("reply came from port %d, want B's %d", from.(*net.UDPAddr).Port, want)
	}
}

// A reply bigger than the tunnel's MTU arrives in IPv4 fragments and the device puts it together.
func TestABigUDPReplyArrivesWhole(t *testing.T) {
	_, c := setup(t)
	conn, err := c.net.Dial("udp", udpEcho(t))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	msg := make([]byte, 1600) // over MTU - 28
	for i := range msg {
		msg[i] = byte(i)
	}
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	conn.Write(msg)
	buf := make([]byte, 2000)
	n, err := conn.Read(buf)
	if err != nil || n != len(msg) || string(buf[:n]) != string(msg) {
		t.Fatalf("got %d bytes, %v", n, err)
	}
}

func TestReplyPacketsAreValidIPv4(t *testing.T) {
	src, dst := netip.MustParseAddrPort("1.2.3.4:53"), netip.MustParseAddrPort("10.7.0.2:5000")
	ps := replyPackets(src, dst, make([]byte, 3000), 7)
	if len(ps) != 3 {
		t.Fatalf("%d fragments, want 3 for 3008 bytes at MTU %d", len(ps), MTU)
	}
	total := 0
	for i, p := range ps {
		ip := header.IPv4(p)
		if !ip.IsValid(len(p)) || !ip.IsChecksumValid() || len(p) > MTU {
			t.Fatalf("fragment %d is not a valid IPv4 packet of at most the MTU", i)
		}
		if ip.ID() != 7 || int(ip.FragmentOffset()) != total || ip.More() != (i < 2) {
			t.Fatalf("fragment %d: id %d offset %d more %v", i, ip.ID(), ip.FragmentOffset(), ip.More())
		}
		total += len(ip.Payload())
	}
	if total != 3008 {
		t.Fatalf("fragments carry %d bytes, want 3008", total)
	}
}

func TestTheBindsEndpointsAndOptions(t *testing.T) {
	b := &hostBind{host: loopback}
	ep, err := b.ParseEndpoint("127.0.0.1:51820")
	if err != nil {
		t.Fatal(err)
	}
	if ep.DstToString() != "127.0.0.1:51820" || ep.DstIP() != loopback || ep.SrcIP().IsValid() || ep.SrcToString() != "" || len(ep.DstToBytes()) == 0 {
		t.Fatalf("endpoint %+v", ep)
	}
	ep.ClearSrc()
	if _, err := b.ParseEndpoint("nonsense"); err == nil {
		t.Fatal("a bad endpoint should be refused")
	}
	if b.SetMark(1) != nil || b.BatchSize() != 1 {
		t.Fatal("SetMark is a no-op and the batch is one packet")
	}
	if err := b.Send([][]byte{{1}}, ep); err == nil {
		t.Fatal("sending on a closed bind should fail")
	}
	if _, _, err := b.Open(0); err != nil {
		t.Fatal(err)
	}
	if _, _, err := b.Open(0); err == nil {
		t.Fatal("opening twice should fail")
	}
	if err := b.Close(); err != nil || b.Close() != nil {
		t.Fatal("Close should work, and twice is fine")
	}
}

// When wireguard-go falls behind, packets are dropped instead of stalling the stack.
func TestAFullQueueDropsInsteadOfBlocking(t *testing.T) {
	tun := newStackTun()
	defer tun.Close()
	for i := 0; i < cap(tun.incoming)+10; i++ {
		done := make(chan struct{})
		go func() { tun.inject([]byte{0x45}); close(done) }()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Fatal("inject blocked on a full queue")
		}
	}
	if len(tun.incoming) != cap(tun.incoming) {
		t.Fatalf("queue holds %d, want it full at %d", len(tun.incoming), cap(tun.incoming))
	}
	tun.Close()
	tun.inject([]byte{0x45}) // after Close it must not block either
}

// A burst as deep as the stack's own queue waits for wireguard-go instead of being dropped.
func TestTheQueueHoldsABurstFromTheStack(t *testing.T) {
	tun := newStackTun()
	defer tun.Close()
	for i := 0; i < queueLen; i++ {
		tun.inject([]byte{0x45})
	}
	if len(tun.incoming) != queueLen {
		t.Fatalf("queue holds %d of a %d packet burst", len(tun.incoming), queueLen)
	}
}

// setupRouter starts a server with one device that sends from lan, as a travel router does when it
// doesn't rewrite its clients' addresses to its own tunnel address. Nothing says it's a router.
func setupRouter(t *testing.T, lan netip.Addr) (*Server, *client) {
	sPriv, sPub := keyPair(t)
	cPriv, cPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	if err := s.SetPeers([]Peer{{PublicKey: cPub, Address: netip.MustParseAddr("10.7.0.2")}}); err != nil {
		t.Fatal(err)
	}
	return s, newClient(t, s, sPub, cPriv, lan)
}

// routerOf is the tunnel address that has the private ranges now, invalid without one.
func (s *Server) routerOf() netip.Addr {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.router
}

func TestARoutersClientsGoThroughTheTunnel(t *testing.T) {
	s, c := setupRouter(t, netip.MustParseAddr("192.168.4.20"))
	n, err := fetch(t, c, tcpServer(t, 50_000))
	if err != nil || n != 50_000 {
		t.Fatalf("got %d bytes, %v", n, err)
	}
	if st := s.Stats(); st.Down != 50_000 || st.Up != 5 {
		t.Fatalf("counted up %d down %d, want the clients' traffic in the totals", st.Up, st.Down)
	}
}

func TestARoutersClientsGetUDP(t *testing.T) {
	s, c := setupRouter(t, netip.MustParseAddr("10.20.0.5"))
	conn, err := c.net.Dial("udp", udpEcho(t))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	// The first packet is the one that shows the device is a router, and it's dropped. A real
	// client sends again, like this.
	buf := make([]byte, 100)
	var got string
	for try := 0; try < 5 && got != "ping"; try++ {
		conn.Write([]byte("ping"))
		conn.SetReadDeadline(time.Now().Add(time.Second))
		if n, err := conn.Read(buf); err == nil {
			got = string(buf[:n])
		}
	}
	if got != "ping" {
		t.Fatalf("echo: %q", got)
	}
	if n := s.tracked(netip.MustParseAddr("10.7.0.2")); n != 1 {
		t.Fatalf("want the flow under the router, got %d", n)
	}
	if st := s.Stats(); st.Up == 0 || st.Down == 0 {
		t.Fatalf("counted up %d down %d, want the clients' traffic in the totals", st.Up, st.Down)
	}
}

func TestADeviceThatSendsForOthersBecomesTheRouter(t *testing.T) {
	s, c := setupRouter(t, netip.MustParseAddr("192.168.4.20"))
	if s.routerOf().IsValid() {
		t.Fatal("a router before any traffic")
	}
	if _, err := fetch(t, c, tcpServer(t, 10)); err != nil {
		t.Fatal(err)
	}
	if r := s.routerOf(); r != netip.MustParseAddr("10.7.0.2") {
		t.Fatalf("router %v, want the device that sent from its client's address", r)
	}
}

func TestADeviceThatSendsOnlyAsItselfIsNotARouter(t *testing.T) {
	s, c := setup(t)
	if _, err := fetch(t, c, tcpServer(t, 10)); err != nil {
		t.Fatal(err)
	}
	if s.routerOf().IsValid() {
		t.Fatal("a plain device became the router")
	}
}

func TestARouterCantSendFromAPublicAddress(t *testing.T) {
	_, c := setupRouter(t, netip.MustParseAddr("203.0.113.9"))
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := c.net.DialContext(ctx, "tcp", tcpServer(t, 10)); err == nil {
		t.Fatal("a router got through from a public address")
	}
}

// twoRouters starts a server with two devices that both send for clients behind them, a from
// 192.168.4.20 and b from 192.168.8.30, and makes a the router with a first connection.
func twoRouters(t *testing.T) (s *Server, a, b netip.Addr, cb *client, target string) {
	sPriv, sPub := keyPair(t)
	aPriv, aPub := keyPair(t)
	bPriv, bPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	a, b = netip.MustParseAddr("10.7.0.2"), netip.MustParseAddr("10.7.0.3")
	if err := s.SetPeers([]Peer{{PublicKey: aPub, Address: a}, {PublicKey: bPub, Address: b}}); err != nil {
		t.Fatal(err)
	}
	ca := newClient(t, s, sPub, aPriv, netip.MustParseAddr("192.168.4.20"))
	cb = newClient(t, s, sPub, bPriv, netip.MustParseAddr("192.168.8.30"))
	target = tcpServer(t, 10)
	if _, err := fetch(t, ca, target); err != nil {
		t.Fatal(err)
	}
	if s.routerOf() != a {
		t.Fatalf("router %v, want %v", s.routerOf(), a)
	}
	return s, a, b, cb, target
}

// Only a router sends for others, but a device that does so by mistake mustn't cut off the
// devices behind the real one.
func TestAnOnlineRouterKeepsItsRole(t *testing.T) {
	s, a, _, cb, target := twoRouters(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := cb.net.DialContext(ctx, "tcp", target); err == nil {
		t.Fatal("another device sent for others while the router was online")
	}
	if s.routerOf() != a {
		t.Fatalf("router %v, want it to stay %v", s.routerOf(), a)
	}
}

func TestTheRoleMovesOnceTheRouterIsOffline(t *testing.T) {
	s, _, b, cb, target := twoRouters(t)
	s.mu.Lock()
	s.now = func() time.Time { return time.Now().Add(onlineWithin) }
	s.mu.Unlock()
	if _, err := fetch(t, cb, target); err != nil {
		t.Fatal(err)
	}
	if s.routerOf() != b {
		t.Fatalf("router %v, want %v once the old one went quiet", s.routerOf(), b)
	}
}

func TestRemovingTheRouterLocksItsClientsOut(t *testing.T) {
	sPriv, sPub := keyPair(t)
	cPriv, cPub := keyPair(t)
	_, otherPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	addr := netip.MustParseAddr("10.7.0.2")
	other := Peer{PublicKey: otherPub, Address: netip.MustParseAddr("10.7.0.3")}
	if err := s.SetPeers([]Peer{{PublicKey: cPub, Address: addr}, other}); err != nil {
		t.Fatal(err)
	}
	c := newClient(t, s, sPub, cPriv, netip.MustParseAddr("192.168.4.20"))
	target := tcpServer(t, 10)
	if _, err := fetch(t, c, target); err != nil {
		t.Fatal(err)
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
	if err := s.SetPeers([]Peer{other}); err != nil {
		t.Fatal(err)
	}
	if s.routerOf().IsValid() {
		t.Fatal("a removed device is still the router")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := c.net.DialContext(ctx, "tcp", target); err == nil {
		t.Fatal("the router's clients still got through after it was removed")
	}
	deadline := time.Now().Add(2 * time.Second)
	for s.tracked(addr) > 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if n := s.tracked(addr); n != 0 {
		t.Fatalf("%d of its clients' flows still open", n)
	}
}

func TestTheRouterStaysTheRouterWhenAnotherDeviceIsAdded(t *testing.T) {
	s, c := setupRouter(t, netip.MustParseAddr("192.168.4.20"))
	if _, err := fetch(t, c, tcpServer(t, 10)); err != nil {
		t.Fatal(err)
	}
	router := s.routerOf()
	_, pub := keyPair(t)
	peers := []Peer{{PublicKey: s.keyOf(router), Address: router}, {PublicKey: pub, Address: netip.MustParseAddr("10.7.0.3")}}
	if err := s.SetPeers(peers); err != nil {
		t.Fatal(err)
	}
	if s.routerOf() != router {
		t.Fatal("adding a device took the router's ranges away")
	}
}

func (s *Server) keyOf(addr netip.Addr) [32]byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, a := range s.peers {
		if a == addr {
			return k
		}
	}
	return [32]byte{}
}

// tracked is how many sockets of the device's open connections and UDP flows the server holds.
func (s *Server) tracked(addr netip.Addr) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.flows[addr])
}

func TestARouterCantSendFromAnUnusedTunnelAddress(t *testing.T) {
	// The router's 10/8 covers the tunnel's free addresses. A flow from one would go to whichever
	// device gets that address later.
	_, c := setupRouter(t, netip.MustParseAddr("10.7.0.9"))
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := c.net.DialContext(ctx, "tcp", tcpServer(t, 10)); err == nil {
		t.Fatal("a router got through from a tunnel address that isn't its own")
	}
}

func TestRoutedNetsLeaveTheTunnelOut(t *testing.T) {
	inside := []string{"10.0.0.1", "10.6.255.255", "10.7.1.0", "10.7.255.255", "10.8.0.0", "10.255.255.255", "172.16.0.1", "192.168.4.20", "fd12::1"}
	outside := []string{"10.7.0.0", "10.7.0.2", "10.7.0.255", "172.32.0.1", "8.8.8.8", "fe80::1"}
	covered := func(a netip.Addr) (n int) {
		for _, p := range routedNets {
			if p.Contains(a) {
				n++
			}
		}
		return
	}
	for _, a := range inside {
		if n := covered(netip.MustParseAddr(a)); n != 1 {
			t.Errorf("%s is in %d of the router's ranges, want 1", a, n)
		}
	}
	for _, a := range outside {
		if n := covered(netip.MustParseAddr(a)); n != 0 {
			t.Errorf("%s is in the router's ranges", a)
		}
	}
}

// A router is found by its IPv4 clients, and its IPv6 ones come with the role.
func TestARoutersIPv6ClientsGoThroughTheTunnel(t *testing.T) {
	sPriv, sPub := keyPair(t)
	cPriv, cPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	if err := s.SetPeers([]Peer{{PublicKey: cPub, Address: netip.MustParseAddr("10.7.0.2")}}); err != nil {
		t.Fatal(err)
	}
	c := newClientAt(t, s, sPub, cPriv, netip.MustParseAddr("192.168.4.20"), netip.MustParseAddr("fd12::20"))
	target := tcpServer(t, 20_000)
	if _, err := fetch(t, c, target); err != nil {
		t.Fatal(err)
	}
	_, port, _ := net.SplitHostPort(target)
	n, err := fetch(t, c, net.JoinHostPort("2001:db8::7", port))
	if err != nil || n != 20_000 {
		t.Fatalf("got %d bytes, %v", n, err)
	}
	if st := s.Stats(); st.Down != 40_000 {
		t.Fatalf("counted down %d, want the IPv6 client's traffic in the totals", st.Down)
	}
}

// A Linux laptop with wg-quick routes IPv6 into the tunnel from its Wi-Fi address, since the client
// config sends ::/0 there but gives it no IPv6 address. wireguard-go drops those packets, and that
// mustn't make the laptop the router, or a real one is refused while the laptop is online.
func TestAnIPv6SourceDoesntMakeARouter(t *testing.T) {
	sPriv, sPub := keyPair(t)
	lPriv, lPub := keyPair(t)
	rPriv, rPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	laptop, router := netip.MustParseAddr("10.7.0.2"), netip.MustParseAddr("10.7.0.3")
	if err := s.SetPeers([]Peer{{PublicKey: lPub, Address: laptop}, {PublicKey: rPub, Address: router}}); err != nil {
		t.Fatal(err)
	}
	l := newClientAt(t, s, sPub, lPriv, laptop, netip.MustParseAddr("2001:db8::5"))
	target := tcpServer(t, 10)
	fetchAndShake(t, s, l, target)
	_, port, _ := net.SplitHostPort(target)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := l.net.DialContext(ctx, "tcp", net.JoinHostPort("2001:db8::7", port)); err == nil {
		t.Fatal("IPv6 from the laptop's Wi-Fi address got through")
	}
	if r := s.routerOf(); r.IsValid() {
		t.Fatalf("router %v after an IPv6 packet from a Wi-Fi address", r)
	}
	r := newClient(t, s, sPub, rPriv, netip.MustParseAddr("192.168.8.30"))
	if _, err := fetch(t, r, target); err != nil {
		t.Fatalf("the real router was refused while the laptop was online: %v", err)
	}
	if s.routerOf() != router {
		t.Fatalf("router %v, want %v", s.routerOf(), router)
	}
}

// A device can take the role with a packet from an address no client has, like a tunnel address
// that isn't its own. Until a client's flow goes through it, it holds no claim, and a real router
// takes over even while it's online.
func TestARouterThatCarriedNothingGivesTheRoleUp(t *testing.T) {
	sPriv, sPub := keyPair(t)
	aPriv, aPub := keyPair(t)
	bPriv, bPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	a, b := netip.MustParseAddr("10.7.0.2"), netip.MustParseAddr("10.7.0.3")
	if err := s.SetPeers([]Peer{{PublicKey: aPub, Address: a}, {PublicKey: bPub, Address: b}}); err != nil {
		t.Fatal(err)
	}
	ca := newClient(t, s, sPub, aPriv, netip.MustParseAddr("10.7.0.9"))
	target := tcpServer(t, 10)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := ca.net.DialContext(ctx, "tcp", target); err == nil {
		t.Fatal("a device got through from a tunnel address that isn't its own")
	}
	cb := newClient(t, s, sPub, bPriv, netip.MustParseAddr("192.168.8.30"))
	if _, err := fetch(t, cb, target); err != nil {
		t.Fatalf("the real router was refused: %v", err)
	}
	if s.routerOf() != b {
		t.Fatalf("router %v, want %v", s.routerOf(), b)
	}
}

func TestARemovedDevicesAddressDoesntFallToTheRouter(t *testing.T) {
	sPriv, sPub := keyPair(t)
	rPriv, rPub := keyPair(t)
	dPriv, dPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	routerPeer := Peer{PublicKey: rPub, Address: netip.MustParseAddr("10.7.0.2")}
	device := Peer{PublicKey: dPub, Address: netip.MustParseAddr("10.7.0.3")}
	if err := s.SetPeers([]Peer{routerPeer, device}); err != nil {
		t.Fatal(err)
	}
	r := newClient(t, s, sPub, rPriv, netip.MustParseAddr("192.168.4.20"))
	d := newClient(t, s, sPub, dPriv, device.Address)
	if _, err := fetch(t, r, tcpServer(t, 10)); err != nil {
		t.Fatal(err)
	}
	if s.routerOf() != routerPeer.Address {
		t.Fatal("the router wasn't found")
	}
	if _, err := fetch(t, d, tcpServer(t, 10)); err != nil {
		t.Fatal(err)
	}
	if err := s.SetPeers([]Peer{routerPeer}); err != nil {
		t.Fatal(err)
	}
	status, _ := s.dev.IpcGet()
	for _, line := range strings.Split(status, "\n") {
		if v, ok := strings.CutPrefix(line, "allowed_ip="); ok && netip.MustParsePrefix(v).Contains(device.Address) {
			t.Fatalf("the router's %s still covers the removed device's address", v)
		}
	}
}

// silent is a host that never answers, so a dial to it waits for its timeout.
const silent = "198.51.100.99"

// A device dialing hosts that never answer, like a port scan, fills only its own share of the
// connections being made.
func TestADeviceAtItsDialCapLeavesOthersDialing(t *testing.T) {
	s, a, b := setupTwo(t)
	var started atomic.Int32
	s.mu.Lock()
	s.maxDials = 2
	normal := s.dial
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		if strings.HasPrefix(address, silent+":") {
			started.Add(1)
			<-ctx.Done() // Close ends it
			return nil, ctx.Err()
		}
		return normal(ctx, network, address)
	}
	s.mu.Unlock()
	dialSilent := func(wait time.Duration) error {
		ctx, cancel := context.WithTimeout(context.Background(), wait)
		defer cancel()
		_, err := a.net.DialContext(ctx, "tcp", net.JoinHostPort(silent, "9"))
		return err
	}
	for range 2 {
		go dialSilent(3 * time.Second)
	}
	deadline := time.Now().Add(5 * time.Second)
	for started.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if started.Load() != 2 {
		t.Fatalf("%d dials started, want 2", started.Load())
	}
	// Refused means a reset came back, where a dial let through would hang until the deadline. How
	// fast the reset comes depends on the machine: under -race on a CI runner it took 2 s.
	if err := dialSilent(15 * time.Second); err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("a dial past the cap wasn't refused: %v", err)
	}
	if n := started.Load(); n != 2 {
		t.Fatalf("%d dials started past a cap of 2", n)
	}
	if _, err := fetch(t, b, tcpServer(t, 10)); err != nil {
		t.Fatalf("the other device couldn't connect: %v", err)
	}
}

// holdServer answers each connection with "hi" and keeps it open until the device closes it.
func holdServer(t *testing.T) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				c.Write([]byte("hi"))
				io.Copy(io.Discard, c)
			}()
		}
	}()
	return viaRemote(l.Addr().String())
}

// openHeld connects to a holdServer and reads its greeting.
func openHeld(c *client, addr string) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	conn, err := c.net.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(conn, make([]byte, 2)); err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

// A device with many open connections, like a torrent client, fills only its own share, and gets
// its room back as they close.
func TestADeviceAtItsConnectionCapLeavesOthersConnecting(t *testing.T) {
	s, a, b := setupTwo(t)
	s.mu.Lock()
	s.maxConns = 2
	s.mu.Unlock()
	hold := holdServer(t)
	var open []net.Conn
	for i := range 2 {
		conn, err := openHeld(a, hold)
		if err != nil {
			t.Fatalf("connection %d under the cap: %v", i, err)
		}
		defer conn.Close()
		open = append(open, conn)
	}
	if conn, err := openHeld(a, hold); err == nil {
		conn.Close()
		t.Fatal("a third connection was made past a cap of 2")
	}
	if _, err := fetch(t, b, tcpServer(t, 10)); err != nil {
		t.Fatalf("the other device couldn't connect: %v", err)
	}
	open[0].Close()
	deadline := time.Now().Add(5 * time.Second)
	for {
		conn, err := openHeld(a, hold)
		if err == nil {
			conn.Close()
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("no room after a connection closed: %v", err)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// One device sending from many ports, a cone each, leaves the others theirs, DNS included.
func TestADeviceAtItsConeCapLeavesOthersTheirs(t *testing.T) {
	s, _, _ := setupTwo(t)
	s.mu.Lock()
	s.maxCones = 2
	s.mu.Unlock()
	for port := uint16(5000); port < 5002; port++ {
		if s.cone(netip.AddrPortFrom(netip.MustParseAddr("10.7.0.2"), port)) == nil {
			t.Fatalf("cone %d refused under the cap", port)
		}
	}
	if s.cone(netip.MustParseAddrPort("10.7.0.2:5002")) != nil {
		t.Fatal("a third cone was made past a cap of 2")
	}
	if s.cone(netip.MustParseAddrPort("10.7.0.3:5000")) == nil {
		t.Fatal("the other device got no cone")
	}
}

// Only the device's own packets keep a cone open. A host that keeps sending to the port can't hold
// one of the device's cones forever.
func TestRepliesAloneDontKeepAConeOpen(t *testing.T) {
	s := &Server{fromNet: func(a netip.AddrPort) netip.AddrPort { return a }, tun: newStackTun()}
	defer s.tun.Close()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	c := &cone{device: netip.MustParseAddrPort("10.7.0.2:5000"), owner: netip.MustParseAddr("10.7.0.2"), conn: conn, done: make(chan struct{}), lock: &s.mu}
	defer c.Close()
	c.last.Store(time.Now().Add(-udpIdle + 300*time.Millisecond).UnixNano())
	sender, err := net.DialUDP("udp4", nil, conn.LocalAddr().(*net.UDPAddr))
	if err != nil {
		t.Fatal(err)
	}
	defer sender.Close()
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		for {
			sender.Write([]byte("spam"))
			select {
			case <-stop:
				return
			case <-time.After(20 * time.Millisecond):
			}
		}
	}()
	done := make(chan struct{})
	go func() { s.receive(c); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("a host that kept sending held the cone open")
	}
}

// startUnclosed is setup without Close in cleanup, for a test that closes the server itself.
func startUnclosed(t *testing.T) (*Server, *client) {
	sPriv, sPub := keyPair(t)
	cPriv, cPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	viaLoopback(s)
	addr := netip.MustParseAddr("10.7.0.2")
	if err := s.SetPeers([]Peer{{PublicKey: cPub, Address: addr}}); err != nil {
		t.Fatal(err)
	}
	return s, newClient(t, s, sPub, cPriv, addr)
}

// acceptOne listens for one iPhone-side connection, and hands it over once it's made.
func acceptOne(t *testing.T) (addr string, accepted <-chan net.Conn) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	ch := make(chan net.Conn, 1)
	go func() {
		c, err := l.Accept()
		if err == nil {
			t.Cleanup(func() { c.Close() })
			ch <- c
		}
	}()
	return viaRemote(l.Addr().String()), ch
}

// closedSoon says whether the far end closes conn within a few seconds.
func closedSoon(conn net.Conn) bool {
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, err := conn.Read(make([]byte, 1))
	return err == io.EOF
}

// A dial that ends after Close mustn't leave an iPhone-side connection that nothing closes, so
// Close waits for it, and it isn't kept.
func TestCloseWaitsForADialInFlight(t *testing.T) {
	s, c := startUnclosed(t)
	target, accepted := acceptOne(t)
	dialing, release := make(chan struct{}, 1), make(chan struct{})
	free := sync.OnceFunc(func() { close(release) })
	t.Cleanup(free)
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		dialing <- struct{}{}
		<-release // a dial that finishes whatever Close does
		return toLoopback(context.Background(), network, address)
	}
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go c.net.DialContext(ctx, "tcp", target)
	select {
	case <-dialing:
	case <-time.After(5 * time.Second):
		t.Fatal("no dial")
	}
	closed := make(chan struct{})
	go func() { s.Close(); close(closed) }()
	select {
	case <-closed:
		t.Fatal("Close returned while a dial was in flight")
	case <-time.After(300 * time.Millisecond):
	}
	free()
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("Close didn't return once the dial ended")
	}
	select {
	case conn := <-accepted:
		if !closedSoon(conn) {
			t.Fatal("the connection dialed after Close is still open")
		}
	case <-time.After(time.Second):
		t.Fatal("the dial never reached the listener")
	}
}

// Close ends the dials still being made instead of waiting out their timeout.
func TestCloseEndsDials(t *testing.T) {
	s, c := startUnclosed(t)
	dialing := make(chan struct{}, 1)
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		dialing <- struct{}{}
		<-ctx.Done()
		return nil, ctx.Err()
	}
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go c.net.DialContext(ctx, "tcp", net.JoinHostPort(silent, "9"))
	select {
	case <-dialing:
	case <-time.After(5 * time.Second):
		t.Fatal("no dial")
	}
	closed := make(chan struct{})
	go func() { s.Close(); close(closed) }()
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("Close waited for a dial instead of ending it")
	}
}

// A connection the old key asked for, still being dialed when its address goes to a new key,
// mustn't open: its replies would go to the new key's device.
func TestADialInFlightDoesntOpenForTheNextKey(t *testing.T) {
	s, c := setup(t)
	addr := netip.MustParseAddr("10.7.0.2")
	target, accepted := acceptOne(t)
	dialing, release := make(chan struct{}, 1), make(chan struct{})
	free := sync.OnceFunc(func() { close(release) })
	t.Cleanup(free)
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		dialing <- struct{}{}
		<-release
		return toLoopback(ctx, network, address)
	}
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	go c.net.DialContext(ctx, "tcp", target)
	select {
	case <-dialing:
	case <-time.After(5 * time.Second):
		t.Fatal("no dial")
	}
	_, next := keyPair(t)
	if err := s.SetPeers([]Peer{{PublicKey: next, Address: addr}}); err != nil {
		t.Fatal(err)
	}
	free()
	select {
	case conn := <-accepted:
		if !closedSoon(conn) {
			t.Fatal("the old key's connection opened under the new key")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the dial never reached the listener")
	}
	if n := s.tracked(addr); n != 0 {
		t.Fatalf("%d sockets tracked for the new key", n)
	}
}

// While wireguard-go still has a removed key, that key's packets can still come in, so its address
// mustn't belong to anyone yet. Otherwise they would start flows as the next key's.
func TestAnAddressHasNoOwnerWhileItsOldKeyGoes(t *testing.T) {
	s, _ := setup(t)
	addr := netip.MustParseAddr("10.7.0.2")
	_, next := keyPair(t)
	var mu sync.Mutex
	var owners []netip.Addr
	heard := func(line string) {
		if strings.HasSuffix(line, "UAPI: Removing") {
			mu.Lock()
			owners = append(owners, s.owner(addr))
			mu.Unlock()
		}
	}
	s.heard.Store(&heard)
	err := s.SetPeers([]Peer{{PublicKey: next, Address: addr}})
	s.heard.Store(nil)
	if err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(owners) != 1 || owners[0].IsValid() {
		t.Fatalf("owners while the old key was removed: %v, want one, invalid", owners)
	}
	if s.owner(addr) != addr {
		t.Fatal("the new key doesn't own the address once it's in")
	}
}

// A client's flow that is refused, here at the cone cap, doesn't count as the router carrying it.
func TestARefusedFlowDoesntMakeTheRouterInUse(t *testing.T) {
	s, _ := setup(t)
	s.mu.Lock()
	s.router, s.routed, s.maxCones = netip.MustParseAddr("10.7.0.2"), false, 0
	s.mu.Unlock()
	if s.cone(netip.MustParseAddrPort("192.168.4.20:5000")) != nil {
		t.Fatal("a cone past a cap of 0")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.routed {
		t.Fatal("a refused flow marked the router as in use")
	}
}
