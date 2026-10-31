package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/netip"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fleet is a server with devices configured at 10.7.0.2 and up. It keeps the server's keys and the
// devices' private keys, so a test can connect any of them, add more, or start the server again.
type fleet struct {
	s         *Server
	close     func() // closes s once, also from cleanup
	priv, pub [32]byte
	peers     []Peer
	privs     [][32]byte
}

// startFleet starts a server with n devices configured and none connected yet.
func startFleet(t *testing.T, n int) *fleet {
	f := &fleet{}
	f.priv, f.pub = keyPair(t)
	for i := range n {
		priv, pub := keyPair(t)
		f.peers = append(f.peers, Peer{PublicKey: pub, Address: netip.AddrFrom4([4]byte{10, 7, 0, byte(2 + i)})})
		f.privs = append(f.privs, priv)
	}
	f.start(t, 0)
	return f
}

func (f *fleet) start(t *testing.T, port int) {
	s, err := Start(loopback, port, f.priv)
	if err != nil {
		t.Fatal(err)
	}
	f.s, f.close = s, sync.OnceFunc(s.Close)
	t.Cleanup(f.close)
	viaLoopback(s)
	if err := s.SetPeers(f.peers); err != nil {
		t.Fatal(err)
	}
}

// restart closes the server and starts it again on the same port with the same key and peers, as
// the app does when the hotspot goes off and on.
func (f *fleet) restart(t *testing.T) {
	port := f.s.port(t)
	f.close()
	f.start(t, port)
}

// device connects the i'th configured device.
func (f *fleet) device(t *testing.T, i int) *client {
	return newClient(t, f.s, f.pub, f.privs[i], f.peers[i].Address)
}

// connectPair opens a TCP connection from c to a new listener, and returns the device's end and the
// far end.
func connectPair(t *testing.T, c *client) (device, far net.Conn) {
	target, accepted := acceptOne(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	device, err := c.net.DialContext(ctx, "tcp", target)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { device.Close() })
	select {
	case far = <-accepted:
	case <-time.After(15 * time.Second):
		t.Fatal("the connection never reached the listener")
	}
	return device, far
}

// talk checks that a TCP connection carries data both ways. The device sends first, as an app
// would, which also makes its WireGuard handshake when it needs one.
func talk(device, far net.Conn, msg string) error {
	defer device.SetDeadline(time.Time{})
	defer far.SetDeadline(time.Time{})
	device.SetDeadline(time.Now().Add(15 * time.Second))
	far.SetDeadline(time.Now().Add(15 * time.Second))
	buf := make([]byte, len(msg))
	if _, err := device.Write([]byte(msg)); err != nil {
		return fmt.Errorf("device write: %v", err)
	}
	if _, err := io.ReadFull(far, buf); err != nil || string(buf) != msg {
		return fmt.Errorf("far end got %q, %v", buf, err)
	}
	if _, err := far.Write([]byte(msg)); err != nil {
		return fmt.Errorf("far end write: %v", err)
	}
	if _, err := io.ReadFull(device, buf); err != nil || string(buf) != msg {
		return fmt.Errorf("device got %q, %v", buf, err)
	}
	return nil
}

// echoOn sends msg on a UDP conn until its echo comes back. WireGuard may drop the first packets
// while it makes a handshake, and a real app sends again too.
func echoOn(conn net.Conn, msg string, within time.Duration) error {
	defer conn.SetReadDeadline(time.Time{})
	deadline := time.Now().Add(within)
	buf := make([]byte, 1500)
	for time.Now().Before(deadline) {
		if _, err := conn.Write([]byte(msg)); err != nil {
			return err
		}
		conn.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		for {
			n, err := conn.Read(buf)
			if err != nil {
				break
			}
			if string(buf[:n]) == msg {
				return nil
			}
		}
	}
	return fmt.Errorf("no echo of %q within %v", msg, within)
}

// waitFor polls cond until it holds, and says whether it did within the time.
func waitFor(within time.Duration, cond func() bool) bool {
	deadline := time.Now().Add(within)
	for !cond() {
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(20 * time.Millisecond)
	}
	return true
}

// leftOver says what the server still holds for a device: sockets, connections and dials counted
// against its caps, and UDP cones. Empty when it holds nothing.
func (s *Server) leftOver(addr netip.Addr) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var held []string
	if n := len(s.flows[addr]); n > 0 {
		held = append(held, fmt.Sprintf("%d sockets", n))
	}
	if n := s.conns[addr]; n > 0 {
		held = append(held, fmt.Sprintf("%d connections", n))
	}
	if n := s.dials[addr]; n > 0 {
		held = append(held, fmt.Sprintf("%d dials", n))
	}
	if n := s.conesOf[addr]; n > 0 {
		held = append(held, fmt.Sprintf("%d cones", n))
	}
	for _, a := range s.arriving {
		if a.owner == addr {
			held = append(held, "a connection arriving")
			break
		}
	}
	return strings.Join(held, ", ")
}

// drained waits until the server holds nothing for the device, and fails the test if it still does.
func drained(t *testing.T, s *Server, addr netip.Addr, why string) {
	t.Helper()
	if !waitFor(10*time.Second, func() bool { return s.leftOver(addr) == "" }) {
		t.Fatalf("%s: %v still holds %s", why, addr, s.leftOver(addr))
	}
}

// expireCones ages a device's UDP cones past their idle time, as if it had sent nothing for a
// minute, and wakes each one's reader so it notices without waiting for its deadline.
func (s *Server) expireCones(addr netip.Addr) {
	s.mu.Lock()
	var cones []*cone
	for _, c := range s.cones {
		if c.owner == addr {
			cones = append(cones, c)
		}
	}
	s.mu.Unlock()
	for _, c := range cones {
		c.last.Store(time.Now().Add(-udpIdle - time.Second).UnixNano())
		c.conn.SetReadDeadline(time.Now())
	}
}

// handshakeAgain waits until WireGuard will take another handshake from a key. Within 20 ms of one it
// drops it as a flood, or as a replay since it rounds the timestamps down to 2^24 ns, and the device
// retries 5 seconds later. A person can't toggle a tunnel that fast, a test can.
func handshakeAgain() { time.Sleep(25 * time.Millisecond) }

// When the hotspot goes off and on, the app closes the server and starts it again with the same key,
// port and peers. Devices carry on with the config they have, and the connections they had end
// instead of hanging, so their apps reconnect.
func TestDevicesResumeAfterTheHotspotGoesOffAndOn(t *testing.T) {
	f := startFleet(t, 2)
	target, echo := tcpServer(t, 1000), udpEcho(t)
	var clients []*client
	var udps, old, fars []net.Conn
	for i := range f.peers {
		c := f.device(t, i)
		clients = append(clients, c)
		if n, err := fetch(t, c, target); err != nil || n != 1000 {
			t.Fatalf("device %d before: got %d bytes, %v", i, n, err)
		}
		udp, err := c.net.Dial("udp", echo)
		if err != nil {
			t.Fatal(err)
		}
		defer udp.Close()
		if err := echoOn(udp, "before", 10*time.Second); err != nil {
			t.Fatal(err)
		}
		udps = append(udps, udp)
		device, far := connectPair(t, c)
		old, fars = append(old, device), append(fars, far)
	}
	f.restart(t)
	for i, far := range fars {
		if !closedSoon(far) {
			t.Fatalf("device %d's connection is still open on the iPhone's side after Close", i)
		}
	}
	for i, c := range clients {
		// The device's tunnel restarts when its Wi-Fi comes back, which makes a new handshake at
		// once. TestLoadADeviceThatKeepsItsSessionResumesAfterTheHotspotGoesOffAndOn waits for
		// WireGuard's own retry instead.
		c.dev.Down()
		if err := c.dev.Up(); err != nil {
			t.Fatal(err)
		}
		if n, err := fetch(t, c, target); err != nil || n != 1000 {
			t.Fatalf("device %d after: got %d bytes, %v", i, n, err)
		}
		if err := echoOn(udps[i], "after", 10*time.Second); err != nil {
			t.Fatalf("device %d: %v", i, err)
		}
		// The new server doesn't know the old connection, so it resets it as soon as the device
		// uses it.
		old[i].SetDeadline(time.Now().Add(10 * time.Second))
		old[i].Write([]byte("still there?"))
		if _, err := old[i].Read(make([]byte, 1)); err == nil {
			t.Fatalf("device %d's old connection still works", i)
		} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
			t.Fatalf("device %d's old connection hangs instead of ending", i)
		}
	}
	f.s.readHandshakes()
	if st := f.s.Stats(); len(st.Connected) != 2 {
		t.Fatalf("connected %v after the restart, want both devices", st.Connected)
	}
}

// A device that keeps its session through the restart sends with keys the new server doesn't have.
// It gets nothing back until WireGuard makes a new handshake by itself, 15 seconds later.
func TestLoadADeviceThatKeepsItsSessionResumesAfterTheHotspotGoesOffAndOn(t *testing.T) {
	needLoad(t)
	f := startFleet(t, 1)
	c := f.device(t, 0)
	target := tcpServer(t, 1000)
	if _, err := fetch(t, c, target); err != nil {
		t.Fatal(err)
	}
	f.restart(t)
	began := time.Now()
	ok := waitFor(40*time.Second, func() bool {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		conn, err := c.net.DialContext(ctx, "tcp", target)
		if err == nil {
			conn.Close()
		}
		return err == nil
	})
	if !ok {
		t.Fatal("the device never resumed")
	}
	f.s.readHandshakes()
	if st := f.s.Stats(); len(st.Connected) != 1 {
		t.Fatalf("connected %v, want the device", st.Connected)
	}
	t.Logf("resumed after %v", time.Since(began).Round(time.Millisecond))
}

// A device that changes networks, or whose router gives it a new port, keeps its session, since
// WireGuard follows it to its new address. Its tunnel switched off and on with the same key makes a
// new session instead. Either way, its open connection and UDP flow carry on.
func TestADeviceKeepsItsConnectionsWhenItRoams(t *testing.T) {
	s, c := setup(t)
	addr := netip.MustParseAddr("10.7.0.2")
	device, far := connectPair(t, c)
	udp, err := c.net.Dial("udp", udpEcho(t))
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	check := func(when string) {
		t.Helper()
		if err := echoOn(udp, when, 10*time.Second); err != nil {
			t.Fatalf("%s: %v", when, err)
		}
		if err := talk(device, far, when); err != nil {
			t.Fatalf("%s: %v", when, err)
		}
	}
	check("before")
	flows := s.tracked(addr)
	// The device's own port, read the way the server's is.
	devicePort := func() int { return (&Server{dev: c.dev}).port(t) }
	before := devicePort()
	if err := c.dev.IpcSet("listen_port=0\n"); err != nil {
		t.Fatal(err)
	}
	roamed := devicePort()
	if roamed == before {
		t.Fatalf("the device kept port %d", before)
	}
	check("roamed")
	status, _ := s.dev.IpcGet()
	if want := fmt.Sprintf("endpoint=127.0.0.1:%d", roamed); !strings.Contains(status, want) {
		t.Fatalf("the server didn't follow the device to port %d:\n%s", roamed, status)
	}
	handshakeAgain()
	c.dev.Down()
	if err := c.dev.Up(); err != nil {
		t.Fatal(err)
	}
	check("toggled")
	if n := s.tracked(addr); n != flows {
		t.Fatalf("%d sockets tracked, want the same %d as before: the flows were made again", n, flows)
	}
}

// A device asleep longer than onlineWithin drops off the connected list, and its UDP flows expire.
// When it wakes, its next handshake lists it again and new traffic works.
func TestASleepingDeviceComesBackWhenItWakes(t *testing.T) {
	s, c := setup(t)
	addr := netip.MustParseAddr("10.7.0.2")
	udp, err := c.net.Dial("udp", udpEcho(t))
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	if err := echoOn(udp, "before", 10*time.Second); err != nil {
		t.Fatal(err)
	}
	target := tcpServer(t, 10)
	fetchAndShake(t, s, c, target)
	s.mu.Lock()
	shook := s.shaken[addr]
	s.mu.Unlock()
	if shook.IsZero() {
		t.Fatal("no handshake before sleeping")
	}
	// The clock moves on to onlineWithin after that handshake, and stays there.
	asleep := shook.Add(onlineWithin)
	s.mu.Lock()
	s.now = func() time.Time { return asleep }
	s.mu.Unlock()
	if st := s.Stats(); len(st.Connected) != 0 {
		t.Fatalf("connected %v while asleep, want none", st.Connected)
	}
	s.expireCones(addr)
	drained(t, s, addr, "asleep")
	// Handshake times are whole seconds, so the next one must fall in a later second to be told apart.
	waitFor(2*time.Second, func() bool { return time.Now().Unix() > shook.Unix() })
	// Asleep that long, its session is past WireGuard's 3 minute RejectAfterTime, so it handshakes
	// again. Restarting its tunnel does the same without the wait.
	c.dev.Down()
	if err := c.dev.Up(); err != nil {
		t.Fatal(err)
	}
	if err := echoOn(udp, "awake", 10*time.Second); err != nil {
		t.Fatal(err)
	}
	fetchAndShake(t, s, c, target)
	if st := s.Stats(); len(st.Connected) != 1 || st.Connected[0] != addr.String() {
		t.Fatalf("connected %v after waking, want the device", st.Connected)
	}
}

// Two devices set up from one QR code share a key. WireGuard keeps one session per key, so only the
// one that sent or handshook last works, never both, and the server holds nothing for the other.
func TestTwoDevicesWithTheSameKeyDontBothWork(t *testing.T) {
	f := startFleet(t, 1)
	addr := f.peers[0].Address
	a, b := f.device(t, 0), f.device(t, 0)
	target := tcpServer(t, 10)
	if _, err := fetch(t, a, target); err != nil {
		t.Fatalf("a alone: %v", err)
	}
	handshakeAgain()
	if _, err := fetch(t, b, target); err != nil {
		t.Fatalf("b, after its handshake replaced a's: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if conn, err := a.net.DialContext(ctx, "tcp", target); err == nil {
		conn.Close()
		t.Fatal("a and b both work")
	}
	if _, err := fetch(t, b, target); err != nil {
		t.Fatalf("b after a tried: %v", err)
	}
	a.dev.Close()
	if _, err := fetch(t, b, target); err != nil {
		t.Fatalf("b once a stopped: %v", err)
	}
	drained(t, f.s, addr, "after both devices' connections ended")
}

// When one of two devices with the same key stops, the other gets a session of its own once
// WireGuard retries its handshake, 15 seconds after its packets stopped being answered.
func TestLoadTheOtherDeviceWithTheSameKeyTakesOverWhenOneStops(t *testing.T) {
	needLoad(t)
	f := startFleet(t, 1)
	a, b := f.device(t, 0), f.device(t, 0)
	target := tcpServer(t, 10)
	if _, err := fetch(t, a, target); err != nil {
		t.Fatal(err)
	}
	handshakeAgain()
	if _, err := fetch(t, b, target); err != nil {
		t.Fatal(err)
	}
	b.dev.Close()
	began := time.Now()
	ok := waitFor(40*time.Second, func() bool {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		conn, err := a.net.DialContext(ctx, "tcp", target)
		if err == nil {
			conn.Close()
		}
		return err == nil
	})
	if !ok {
		t.Fatal("a never took over")
	}
	t.Logf("a took over after %v", time.Since(began).Round(time.Millisecond))
	// Each of a's tries left a connection half made, waiting for an ACK that went to b's session.
	// They end when a resets them, or when gVisor stops sending their SYN-ACK.
	began = time.Now()
	addr := f.peers[0].Address
	if !waitFor(2*time.Minute, func() bool { return f.s.leftOver(addr) == "" }) {
		t.Fatalf("after a took over, %v still holds %s", addr, f.s.leftOver(addr))
	}
	t.Logf("the half made connections ended after %v", time.Since(began).Round(time.Millisecond))
}

// Devices joining and leaving, a SetPeers each time, don't disturb the devices streaming meanwhile,
// and a device that leaves takes all its flows with it. The address that comes and goes changes
// hands each round. Every fifth key connects before it goes, and the streaming devices' UDP is
// checked then, since each costs seconds under the race detector.
func TestChurnLeavesStreamingDevicesAlone(t *testing.T) {
	streamers, rounds, connectEvery := 3, 20, 5
	if raceEnabled {
		streamers, rounds = 2, 6
	}
	f := startFleet(t, streamers)
	echo, hold := udpEcho(t), holdServer(t)
	type stream struct {
		device, far, udp net.Conn
		flows            int
		sent, got        atomic.Int64
		readErr, wrote   chan error
	}
	stop := make(chan struct{})
	var streams []*stream
	for i := range streamers {
		c := f.device(t, i)
		st := &stream{readErr: make(chan error, 1), wrote: make(chan error, 1)}
		st.device, st.far = connectPair(t, c)
		udp, err := c.net.Dial("udp", echo)
		if err != nil {
			t.Fatal(err)
		}
		defer udp.Close()
		st.udp = udp
		if err := echoOn(udp, "start", 10*time.Second); err != nil {
			t.Fatal(err)
		}
		go func() {
			buf := make([]byte, 32<<10)
			for {
				n, err := st.device.Read(buf)
				st.got.Add(int64(n))
				if err != nil {
					st.readErr <- err
					return
				}
			}
		}()
		go func() {
			chunk := make([]byte, 1<<10)
			for {
				select {
				case <-stop:
					st.wrote <- nil
					return
				default:
				}
				st.far.SetWriteDeadline(time.Now().Add(15 * time.Second))
				n, err := st.far.Write(chunk)
				st.sent.Add(int64(n))
				if err != nil {
					st.wrote <- err
					return
				}
				time.Sleep(50 * time.Millisecond)
			}
		}()
		streams = append(streams, st)
	}
	for i, st := range streams {
		// Data reaching the device means the server has tracked both ends of its connection.
		if !waitFor(15*time.Second, func() bool { return st.got.Load() > 0 }) {
			t.Fatalf("streaming device %d got nothing", i)
		}
		st.flows = f.s.tracked(f.peers[i].Address)
	}
	udpWorks := func(when string) {
		t.Helper()
		for i, st := range streams {
			if err := echoOn(st.udp, when, 10*time.Second); err != nil {
				t.Fatalf("%s: streaming device %d: %v", when, i, err)
			}
		}
	}
	churn := netip.MustParseAddr("10.7.0.100")
	var last *client
	for r := range rounds {
		priv, pub := keyPair(t)
		if err := f.s.SetPeers(append(f.peers[:streamers:streamers], Peer{PublicKey: pub, Address: churn})); err != nil {
			t.Fatal(err)
		}
		drained(t, f.s, churn, fmt.Sprintf("round %d, the last key's flows", r))
		if last != nil {
			last.dev.Close()
			last = nil
		}
		if r%connectEvery == 0 {
			last = newClient(t, f.s, f.pub, priv, churn)
			conn, err := openHeld(last, hold)
			if err != nil {
				t.Fatalf("round %d: the new device couldn't connect: %v", r, err)
			}
			defer conn.Close()
			udp, err := last.net.Dial("udp", echo)
			if err != nil {
				t.Fatal(err)
			}
			defer udp.Close()
			if err := echoOn(udp, "churn", 10*time.Second); err != nil {
				t.Fatalf("round %d: the new device: %v", r, err)
			}
			udpWorks(fmt.Sprintf("round %d", r))
		}
	}
	if err := f.s.SetPeers(f.peers); err != nil {
		t.Fatal(err)
	}
	drained(t, f.s, churn, "the last churned device removed")
	udpWorks("the end")
	close(stop)
	for i, st := range streams {
		select {
		case err := <-st.wrote:
			if err != nil {
				t.Fatalf("streaming device %d's far end: %v", i, err)
			}
		case <-time.After(20 * time.Second):
			t.Fatalf("streaming device %d's far end is stuck", i)
		}
		if !waitFor(15*time.Second, func() bool { return st.got.Load() == st.sent.Load() }) {
			t.Fatalf("streaming device %d got %d of %d bytes", i, st.got.Load(), st.sent.Load())
		}
		select {
		case err := <-st.readErr:
			t.Fatalf("streaming device %d's connection ended: %v", i, err)
		default:
		}
		st.device.Write([]byte("up"))
		st.far.SetReadDeadline(time.Now().Add(10 * time.Second))
		if _, err := io.ReadFull(st.far, make([]byte, 2)); err != nil {
			t.Fatalf("streaming device %d can't send anymore: %v", i, err)
		}
		if n := f.s.tracked(f.peers[i].Address); n != st.flows {
			t.Fatalf("streaming device %d has %d sockets tracked, want its %d", i, n, st.flows)
		}
		t.Logf("streaming device %d got %d KB during the churn", i, st.got.Load()>>10)
	}
}

// Once the devices are done and the server is closed, nothing of theirs is left: no sockets, no
// counts against their caps, no goroutines. So the hotspot going off and on all day doesn't grow
// the app.
func TestNothingIsLeftBehind(t *testing.T) {
	target, echo, hold := tcpServer(t, 10_000), udpEcho(t), holdServer(t)
	before := runtime.NumGoroutine()
	f := startFleet(t, 2)
	var clients []*client
	for i := range f.peers {
		c := f.device(t, i)
		clients = append(clients, c)
		if n, err := fetch(t, c, target); err != nil || n != 10_000 {
			t.Fatalf("device %d got %d bytes, %v", i, n, err)
		}
		udp, err := c.net.Dial("udp", echo)
		if err != nil {
			t.Fatal(err)
		}
		if err := echoOn(udp, "ping", 10*time.Second); err != nil {
			t.Fatal(err)
		}
		udp.Close()
		conn, err := openHeld(c, hold)
		if err != nil {
			t.Fatal(err)
		}
		conn.Close()
	}
	for _, p := range f.peers {
		f.s.expireCones(p.Address)
		drained(t, f.s, p.Address, "once its connections closed and its cones expired")
	}
	for _, c := range clients {
		c.dev.Close()
	}
	f.close()
	var now int
	if !waitFor(10*time.Second, func() bool { now = runtime.NumGoroutine(); return now <= before+2 }) {
		buf := make([]byte, 1<<20)
		t.Fatalf("%d goroutines before Start, %d after Close:\n%s", before, now, buf[:runtime.Stack(buf, true)])
	}
}

// Taking one device off the hotspot mid-download stops only its download. The others carry on and
// get every byte.
func TestRemovingADeviceMidDownloadLeavesTheOthersAlone(t *testing.T) {
	const half = 16 << 10
	f := startFleet(t, 3)
	data := make([]byte, 2*half)
	for i := range data {
		data[i] = byte(i % 251)
	}
	var devices, fars []net.Conn
	for i := range f.peers {
		device, far := connectPair(t, f.device(t, i))
		if _, err := far.Write(data[:half]); err != nil {
			t.Fatal(err)
		}
		device.SetReadDeadline(time.Now().Add(15 * time.Second))
		got := make([]byte, half)
		if _, err := io.ReadFull(device, got); err != nil || string(got) != string(data[:half]) {
			t.Fatalf("device %d's first half: %v", i, err)
		}
		devices, fars = append(devices, device), append(fars, far)
	}
	if err := f.s.SetPeers(f.peers[1:]); err != nil {
		t.Fatal(err)
	}
	if !closedSoon(fars[0]) {
		t.Fatal("the removed device's download is still open on the iPhone's side")
	}
	drained(t, f.s, f.peers[0].Address, "removed mid-download")
	for i := 1; i < len(f.peers); i++ {
		if _, err := fars[i].Write(data[half:]); err != nil {
			t.Fatalf("device %d's far end: %v", i, err)
		}
		fars[i].Close()
		devices[i].SetReadDeadline(time.Now().Add(15 * time.Second))
		got, err := io.ReadAll(devices[i])
		if err != nil || string(got) != string(data[half:]) {
			t.Fatalf("device %d got %d of %d bytes of its second half intact, %v", i, len(got), half, err)
		}
	}
}

// A /24 tunnel holds 253 devices, 10.7.0.2 to 10.7.0.254. All of them can be configured at once, and
// the last address works like the first.
func TestAFullHouseOf253Devices(t *testing.T) {
	f := startFleet(t, 253)
	if last := f.peers[252].Address; last != netip.MustParseAddr("10.7.0.254") {
		t.Fatalf("the last device is at %v", last)
	}
	status, _ := f.s.dev.IpcGet()
	if n := strings.Count(status, "public_key="); n != 253 {
		t.Fatalf("wireguard-go has %d peers, want 253", n)
	}
	target, echo := tcpServer(t, 1000), udpEcho(t)
	want := map[string]bool{}
	for _, i := range []int{0, 126, 252} {
		c := f.device(t, i)
		if n, err := fetch(t, c, target); err != nil || n != 1000 {
			t.Fatalf("%v got %d bytes, %v", f.peers[i].Address, n, err)
		}
		udp, err := c.net.Dial("udp", echo)
		if err != nil {
			t.Fatal(err)
		}
		defer udp.Close()
		if err := echoOn(udp, "ping", 10*time.Second); err != nil {
			t.Fatalf("%v: %v", f.peers[i].Address, err)
		}
		want[f.peers[i].Address.String()] = true
	}
	f.s.readHandshakes()
	st := f.s.Stats()
	if len(st.Connected) != len(want) {
		t.Fatalf("connected %v, want the 3 that connected", st.Connected)
	}
	for _, a := range st.Connected {
		if !want[a] {
			t.Fatalf("connected %v, want the 3 that connected", st.Connected)
		}
	}
}
