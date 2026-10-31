package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// counted is how many of the device's TCP connections the server counts as being dialed and as
// open, and how many SYNs of anyone's still wait for their dial.
func (s *Server) counted(addr netip.Addr) (dials, conns, arriving int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dials[addr], s.conns[addr], len(s.arriving)
}

// uncounted waits until the server counts nothing of the device's. A count left behind would hold
// part of the device's caps until the app restarts.
func uncounted(t *testing.T, s *Server, addr netip.Addr) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		d, c, a := s.counted(addr)
		if d == 0 && c == 0 && a == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%v still counted: %d dials, %d connections, %d arriving", addr, d, c, a)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// refusedPort is a loopback port nothing listens on, like a host with that port closed.
func refusedPort(t *testing.T) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()
	return viaRemote(addr)
}

// farEnd stands in for a host on the internet that runs serve on each connection.
func farEnd(t *testing.T, serve func(*net.TCPConn)) string {
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
				serve(c.(*net.TCPConn))
			}()
		}
	}()
	return viaRemote(l.Addr().String())
}

// connect opens a TCP connection from the device, with a deadline so a hang fails the test.
func connect(t *testing.T, c *client, addr string) net.Conn {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	conn, err := c.net.DialContext(ctx, "tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	conn.SetDeadline(time.Now().Add(15 * time.Second))
	return conn
}

// A closed port answers with a reset, and the device must hear it at once rather than wait out a
// timeout, so an app tries its next address or shows its error straight away.
func TestAFarEndThatRefusesFailsTheDialAtOnce(t *testing.T) {
	s, c := setup(t)
	var dialed atomic.Int32
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		dialed.Add(1)
		return toLoopback(ctx, network, address)
	}
	s.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	began := time.Now()
	_, err := c.net.DialContext(ctx, "tcp", refusedPort(t))
	took := time.Since(began)
	if err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("got %v, want the far end's refusal", err)
	}
	// Under -race on a CI runner a reset took 2 s, see TestADeviceAtItsDialCapLeavesOthersDialing.
	if took >= dialTimeout {
		t.Fatalf("the refusal took %v, as long as a dial that times out", took)
	}
	if dialed.Load() == 0 {
		t.Fatal("refused without dialing the far end")
	}
	uncounted(t, s, netip.MustParseAddr("10.7.0.2"))
}

// A far end that drops SYNs keeps the server's dial waiting, and the device waits with it. When
// the dial gives up, the device gets a reset instead of a connection that never opens. The real
// dialer gives up after dialTimeout, see the LOAD version below. forwardTCP passes it s.ctx, which
// has no deadline, so this dialer gives up when the test says.
func TestADialThatGivesUpResetsTheDevice(t *testing.T) {
	s, c := setup(t)
	addr := netip.MustParseAddr("10.7.0.2")
	dialing, giveUp := make(chan struct{}, 1), make(chan struct{})
	free := sync.OnceFunc(func() { close(giveUp) })
	t.Cleanup(free)
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		select {
		case dialing <- struct{}{}:
		default:
		}
		select {
		case <-giveUp:
		case <-ctx.Done():
		}
		return nil, &net.OpError{Op: "dial", Net: network, Err: errors.New("i/o timeout")}
	}
	s.mu.Unlock()
	result := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		conn, err := c.net.DialContext(ctx, "tcp", net.JoinHostPort(silent, "9"))
		if conn != nil {
			conn.Close()
		}
		result <- err
	}()
	select {
	case <-dialing:
	case <-time.After(15 * time.Second):
		t.Fatal("no dial")
	}
	if d, n, _ := s.counted(addr); d != 1 || n != 1 {
		t.Fatalf("counted %d dials and %d connections while dialing, want 1 each", d, n)
	}
	select {
	case err := <-result:
		t.Fatalf("the device's dial ended while the server's was still waiting: %v", err)
	default:
	}
	free()
	select {
	case err := <-result:
		if err == nil || !strings.Contains(err.Error(), "refused") {
			t.Fatalf("got %v, want a reset once the dial gave up", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("the device kept waiting after the server's dial gave up")
	}
	uncounted(t, s, addr)
}

// The same with Start's own dialer: the device gets its reset dialTimeout after it asked, not
// later and not never. A measurement, since it waits dialTimeout for real.
func TestLoadAFarEndThatNeverAnswersTimesOutAfterTheDialTimeout(t *testing.T) {
	needLoad(t)
	// 127.0.0.2 isn't set up on macOS, so a SYN sent there gets no answer. On Linux it's a local
	// address that refuses at once, and there's nothing to measure.
	const blackhole = "127.0.0.2:9"
	var ne net.Error
	if _, err := (&net.Dialer{Timeout: 300 * time.Millisecond}).Dial("tcp", blackhole); !errors.As(err, &ne) || !ne.Timeout() {
		t.Skipf("%s answers on this machine: %v", blackhole, err)
	}
	sPriv, sPub := keyPair(t)
	cPriv, cPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	real := s.dial // Start's, with dialTimeout
	viaLoopback(s)
	s.dial = func(ctx context.Context, network, _ string) (net.Conn, error) { return real(ctx, network, blackhole) }
	addr := netip.MustParseAddr("10.7.0.2")
	if err := s.SetPeers([]Peer{{PublicKey: cPub, Address: addr}}); err != nil {
		t.Fatal(err)
	}
	c := newClient(t, s, sPub, cPriv, addr)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	began := time.Now()
	_, err = c.net.DialContext(ctx, "tcp", net.JoinHostPort(silent, "9"))
	took := time.Since(began)
	if err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("got %v after %v, want a reset", err, took)
	}
	if took < dialTimeout || took > dialTimeout+5*time.Second {
		t.Fatalf("the reset came after %v, want just over %v", took, dialTimeout)
	}
	t.Logf("the device's dial ended after %v", took)
	uncounted(t, s, addr)
}

// A far end that closes after its reply, like an HTTP/1.0 server, ends the device's side the same
// way: every byte, then EOF. And the server lets go of the connection, so it doesn't hold a cap.
func TestAFarEndThatClosesGivesEveryByteThenEOF(t *testing.T) {
	s, c := setup(t)
	if n, err := fetch(t, c, tcpServer(t, 200_000)); err != nil || n != 200_000 {
		t.Fatalf("got %d bytes, %v", n, err)
	}
	uncounted(t, s, netip.MustParseAddr("10.7.0.2"))
}

// A far end that resets mid-reply must end the device's connection with an error. A clean EOF
// would let a download whose length isn't given, like an HTTP/1.0 body, look complete when it isn't.
func TestAFarEndThatResetsEndsTheDevicesConnectionWithAnError(t *testing.T) {
	t.Skip("#48: the server closes the device's side with a FIN, so the device gets a clean EOF")
	s, c := setup(t)
	target := farEnd(t, func(conn *net.TCPConn) {
		io.ReadFull(conn, make([]byte, 5))
		conn.Write(make([]byte, 64<<10))
		conn.SetLinger(0) // so Close sends a reset
	})
	n, err := fetch(t, c, target)
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		t.Fatalf("the device hung after the reset, %d bytes in", n)
	}
	if err == nil {
		t.Fatalf("got %d bytes and a clean EOF, want an error after the far end's reset", n)
	}
	uncounted(t, s, netip.MustParseAddr("10.7.0.2"))
}

// A device that closes its sending side once its request is out, as some HTTP and rsync clients
// do, still gets the whole reply. The far end sees the half close and keeps sending.
func TestTheDeviceClosingItsSendingSideStillGetsTheWholeReply(t *testing.T) {
	s, c := setup(t)
	const chunk = 64 << 10
	sawEOF := make(chan bool, 1)
	target := farEnd(t, func(conn *net.TCPConn) {
		io.ReadFull(conn, make([]byte, 5))
		conn.Write(make([]byte, chunk))
		// The rest waits for the device's half close, so the reply is mid-stream when it comes.
		_, err := io.Copy(io.Discard, conn)
		sawEOF <- err == nil
		conn.Write(make([]byte, chunk))
	})
	conn := connect(t, c, target)
	conn.Write([]byte("hello"))
	if _, err := io.ReadFull(conn, make([]byte, chunk)); err != nil {
		t.Fatal(err)
	}
	if err := conn.(interface{ CloseWrite() error }).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	rest, err := io.ReadAll(conn)
	if err != nil || len(rest) != chunk {
		t.Fatalf("got %d of the last %d bytes after the half close, %v", len(rest), chunk, err)
	}
	select {
	case clean := <-sawEOF:
		if !clean {
			t.Fatal("the far end got an error instead of the device's half close")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the far end never saw the device's half close")
	}
	conn.Close()
	uncounted(t, s, netip.MustParseAddr("10.7.0.2"))
}

// A far end that has said all it will and closes its sending side, like a server that answers
// before reading the whole upload, still gets everything the device sends after that.
func TestTheFarEndClosingItsSendingSideStillGetsTheWholeUpload(t *testing.T) {
	s, c := setup(t)
	const chunk = 64 << 10
	got := make(chan int64, 1)
	target := farEnd(t, func(conn *net.TCPConn) {
		conn.Write([]byte("hi"))
		conn.CloseWrite()
		n, _ := io.Copy(io.Discard, conn)
		got <- n
	})
	conn := connect(t, c, target)
	if _, err := conn.Write(make([]byte, chunk)); err != nil {
		t.Fatal(err)
	}
	if b, err := io.ReadAll(conn); err != nil || string(b) != "hi" {
		t.Fatalf("got %q, %v, want the far end's reply, then its half close", b, err)
	}
	if _, err := conn.Write(make([]byte, chunk)); err != nil {
		t.Fatalf("the upload stopped at the far end's half close: %v", err)
	}
	if err := conn.(interface{ CloseWrite() error }).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	select {
	case n := <-got:
		if n != 2*chunk {
			t.Fatalf("the far end got %d of %d bytes", n, 2*chunk)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("the upload never finished")
	}
	conn.Close()
	uncounted(t, s, netip.MustParseAddr("10.7.0.2"))
}

// While the iPhone's own network isn't up, like behind a captive portal, every dial fails. Once it
// is, the device's next connection goes through, with nothing to reset or reconnect on its side.
func TestDialsWorkAgainOnceTheNetworkIsUp(t *testing.T) {
	s, c := setup(t)
	var up atomic.Bool
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		if !up.Load() {
			return nil, &net.OpError{Op: "dial", Net: network, Err: syscall.ENETUNREACH}
		}
		return toLoopback(ctx, network, address)
	}
	s.mu.Unlock()
	target := tcpServer(t, 1000)
	for i := range 3 {
		if _, err := fetch(t, c, target); err == nil {
			t.Fatalf("connection %d got through while the network was down", i)
		}
	}
	up.Store(true)
	if n, err := fetch(t, c, target); err != nil || n != 1000 {
		t.Fatalf("got %d bytes once the network was up, %v", n, err)
	}
	uncounted(t, s, netip.MustParseAddr("10.7.0.2"))
}

// A device whose connections all fail, like an app retrying a dead server, gets its share of the
// caps back each time. It never keeps another device from connecting, nor later itself.
func TestADeviceWhoseDialsFailLeavesOthersConnecting(t *testing.T) {
	s, a, b := setupTwo(t)
	s.mu.Lock()
	s.maxDials, s.maxConns = 2, 2
	s.mu.Unlock()
	dead, live := refusedPort(t), tcpServer(t, 10)
	var failed atomic.Int32
	stop := make(chan struct{})
	var retrying sync.WaitGroup
	for range 4 { // twice the cap at once
		retrying.Add(1)
		go func() {
			defer retrying.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				if _, err := fetch(t, a, dead); err != nil {
					failed.Add(1)
				}
			}
		}()
	}
	for i := range 3 {
		if _, err := fetch(t, b, live); err != nil {
			close(stop)
			retrying.Wait()
			t.Fatalf("the other device's connection %d failed: %v", i, err)
		}
	}
	// A few rounds past the cap, so a count that leaks would have filled it.
	deadline := time.Now().Add(30 * time.Second)
	for failed.Load() < 6 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	close(stop)
	retrying.Wait()
	if n := failed.Load(); n < 6 {
		t.Fatalf("only %d failed connections, want 6", n)
	}
	uncounted(t, s, netip.MustParseAddr("10.7.0.2"))
	if _, err := fetch(t, a, live); err != nil {
		t.Fatalf("the device couldn't connect once its server was back: %v", err)
	}
	uncounted(t, s, netip.MustParseAddr("10.7.0.3"))
}

// A device that sends from another device's tunnel address gets nothing through: wireguard-go
// drops the packet before the stack sees it. The drop makes it the router, which is all a router
// looks like, but the router's ranges leave the tunnel out. So the other device keeps its address,
// its open flow and new connections, and the role holds no claim until a client's flow goes
// through it, see TestARouterThatCarriedNothingGivesTheRoleUp.
func TestADeviceSendingAsAnotherGetsNothingThrough(t *testing.T) {
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
	var dropped atomic.Int32
	heard := func(line string) {
		if strings.HasPrefix(line, "IPv4 packet with disallowed source address") {
			dropped.Add(1)
		}
	}
	s.heard.Store(&heard)
	t.Cleanup(func() { s.heard.Store(nil) })
	ping := func(conn net.Conn, msg string) error {
		buf := make([]byte, 100)
		for range 10 {
			conn.Write([]byte(msg))
			conn.SetReadDeadline(time.Now().Add(time.Second))
			if n, err := conn.Read(buf); err == nil && string(buf[:n]) == msg {
				return nil
			}
		}
		return errors.New("no echo of " + msg)
	}
	cb := newClient(t, s, sPub, bPriv, b)
	flow, err := cb.net.Dial("udp", udpEcho(t))
	if err != nil {
		t.Fatal(err)
	}
	defer flow.Close()
	if err := ping(flow, "before"); err != nil {
		t.Fatal(err)
	}
	far, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer far.Close()
	var reached atomic.Int32
	go func() {
		buf := make([]byte, 100)
		for {
			if _, _, err := far.ReadFrom(buf); err != nil {
				return
			}
			reached.Add(1)
		}
	}()
	impostor := newClient(t, s, sPub, aPriv, b) // a's key, b's address
	spoofed, err := impostor.net.Dial("udp", viaRemote(far.LocalAddr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer spoofed.Close()
	deadline := time.Now().Add(15 * time.Second)
	for dropped.Load() == 0 || s.routerOf() != a {
		if time.Now().After(deadline) {
			t.Fatalf("%d drops heard, router %v, want a drop and %v", dropped.Load(), s.routerOf(), a)
		}
		spoofed.Write([]byte("spoofed"))
		time.Sleep(100 * time.Millisecond)
	}
	if n := reached.Load(); n != 0 {
		t.Fatalf("%d spoofed packets reached the far end", n)
	}
	if s.owner(b) != b {
		t.Fatalf("%v's owner is %v", b, s.owner(b))
	}
	if na, nb := s.tracked(a), s.tracked(b); na != 0 || nb != 1 {
		t.Fatalf("flows: %d under the impostor, %d under %v, want 0 and its own 1", na, nb, b)
	}
	s.mu.Lock()
	routed := s.routed
	s.mu.Unlock()
	if routed {
		t.Fatal("the impostor's role counts as carrying a client's flow")
	}
	if err := ping(flow, "after"); err != nil {
		t.Fatalf("the other device's open flow broke: %v", err)
	}
	if _, err := fetch(t, cb, tcpServer(t, 10)); err != nil {
		t.Fatalf("the other device couldn't connect: %v", err)
	}
}

// A cone that idled out is gone for good. The device's next packet from the same port gets a new
// iPhone port, and a host still sending to the old one reaches nobody, like any NAT whose mapping
// timed out. Cones age on the real clock, not s.now, so the test ages the cone's last send.
func TestAnExpiredConeGetsAFreshMapping(t *testing.T) {
	s, c := setup(t)
	device := netip.MustParseAddrPort("10.7.0.2:40001")
	far, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer far.Close()
	go func() {
		buf := make([]byte, 100)
		for {
			n, from, err := far.ReadFromUDPAddrPort(buf)
			if err != nil {
				return
			}
			far.WriteToUDPAddrPort(buf[:n], from)
		}
	}()
	conn, err := c.net.ListenUDP(net.UDPAddrFromAddrPort(device))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	to := &net.UDPAddr{IP: net.ParseIP(remote), Port: far.LocalAddr().(*net.UDPAddr).Port}
	// exchange sends msg until it comes back, and fails on anything sent to the old port.
	exchange := func(msg string) {
		buf := make([]byte, 100)
		for range 15 {
			conn.WriteTo([]byte(msg), to)
			conn.SetReadDeadline(time.Now().Add(time.Second))
			n, _, err := conn.ReadFrom(buf)
			if err == nil && string(buf[:n]) == "stale" {
				t.Fatal("a reply to the expired cone's port reached the device")
			}
			if err == nil && string(buf[:n]) == msg {
				return
			}
		}
		t.Fatalf("no echo of %q", msg)
	}
	coneOf := func() *cone {
		s.mu.Lock()
		defer s.mu.Unlock()
		return s.cones[device]
	}
	exchange("one")
	old := coneOf()
	if old == nil {
		t.Fatal("no cone")
	}
	oldPort := old.conn.LocalAddr().(*net.UDPAddr).Port
	// Its last send a minute ago, and its waiting read woken to notice.
	deadline := time.Now().Add(10 * time.Second)
	for coneOf() == old {
		if time.Now().After(deadline) {
			t.Fatal("the aged cone stayed open")
		}
		old.last.Store(time.Now().Add(-udpIdle - time.Second).UnixNano())
		old.conn.SetReadDeadline(time.Now())
		time.Sleep(20 * time.Millisecond)
	}
	for s.tracked(device.Addr()) != 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if n := s.tracked(device.Addr()); n != 0 {
		t.Fatalf("%d flows still tracked after the cone expired", n)
	}
	// Sent before the new cone exists, so it can't land there even if the new port is the old one.
	far.WriteToUDPAddrPort([]byte("stale"), netip.AddrPortFrom(netip.MustParseAddr("127.0.0.1"), uint16(oldPort)))
	exchange("two")
	fresh := coneOf()
	if fresh == nil || fresh == old {
		t.Fatal("the device's port didn't get a fresh cone")
	}
	exchange("three")
	t.Logf("old iPhone port %d, new %d", oldPort, fresh.conn.LocalAddr().(*net.UDPAddr).Port)
}
