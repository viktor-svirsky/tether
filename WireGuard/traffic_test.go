package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/netip"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"unsafe"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

// pattern is n bytes that only seed makes, so a byte lost, added or out of place changes them.
func pattern(seed uint64, n int) []byte {
	r := rand.New(rand.NewPCG(seed, seed))
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(r.Uint32())
	}
	return b
}

// uploadServer reads each connection to its end and answers with the SHA-256 of what came.
func uploadServer(t *testing.T) string {
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
				h := sha256.New()
				if _, err := io.Copy(h, c); err == nil {
					c.Write(h.Sum(nil))
				}
			}()
		}
	}()
	return viaRemote(l.Addr().String())
}

// patternServer reads an 8-byte seed from each connection and answers with n bytes of its pattern.
func patternServer(t *testing.T, n int) string {
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
				seed := make([]byte, 8)
				if _, err := io.ReadFull(c, seed); err == nil {
					c.Write(pattern(binary.BigEndian.Uint64(seed), n))
				}
			}()
		}
	}()
	return viaRemote(l.Addr().String())
}

// upload sends data from c to an uploadServer and checks the hash it answers with.
func upload(c *client, addr string, data []byte) error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	conn, err := c.net.DialContext(ctx, "tcp", addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(60 * time.Second))
	if _, err := conn.Write(data); err != nil {
		return err
	}
	conn.(*gonet.TCPConn).CloseWrite()
	got, err := io.ReadAll(conn)
	if want := sha256.Sum256(data); !bytes.Equal(got, want[:]) {
		return fmt.Errorf("the server got other bytes than were sent: hash %x, %v", got, err)
	}
	return nil
}

// download asks a patternServer for seed's pattern and checks every byte of it.
func download(c *client, addr string, seed uint64, n int) error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	conn, err := c.net.DialContext(ctx, "tcp", addr)
	if err != nil {
		return err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(60 * time.Second))
	conn.Write(binary.BigEndian.AppendUint64(nil, seed))
	got, err := io.ReadAll(conn)
	if !bytes.Equal(got, pattern(seed, n)) {
		return fmt.Errorf("got %d bytes of %d, not the pattern asked for: %v", len(got), n, err)
	}
	return nil
}

// Every device uploads and downloads at once, and the bytes arrive intact both ways. Each device
// asks for its own pattern, so a connection crossed with another device's would show.
func TestEveryDeviceUploadsAndDownloadsAtOnce(t *testing.T) {
	const devices, size = 6, 200 << 10
	s, clients, _ := setupMany(t, devices)
	up, down := uploadServer(t), patternServer(t, size)
	var wg sync.WaitGroup
	for i, c := range clients {
		wg.Add(2)
		go func() {
			defer wg.Done()
			if err := upload(c, up, pattern(uint64(i), size)); err != nil {
				t.Errorf("device %d upload: %v", i, err)
			}
		}()
		go func() {
			defer wg.Done()
			if err := download(c, down, uint64(100+i), size); err != nil {
				t.Errorf("device %d download: %v", i, err)
			}
		}()
	}
	wg.Wait()
	// Up is each upload and each download's seed, down each download and each upload's hash.
	if st := s.Stats(); st.Up != devices*(size+8) || st.Down != devices*(size+sha256.Size) {
		t.Errorf("counted up %d down %d, want %d and %d", st.Up, st.Down, devices*(size+8), devices*(size+sha256.Size))
	}
}

// A page load opens about a hundred short connections at once, and a few devices may load pages
// together. Each one works, and the counts the caps go by drop back to zero after, or a day of
// browsing would fill them.
func TestAPageLoadBurstFromSeveralDevicesLeavesNoCountBehind(t *testing.T) {
	const devices, each, size = 3, 100, 2 << 10
	s, clients, addrs := setupMany(t, devices)
	// download, not fetch: under -race on a busy machine the last of a burst can take longer than
	// fetch's 15 s, with no packet lost anywhere.
	target := patternServer(t, size)
	var wg sync.WaitGroup
	var failed atomic.Int32
	var firstErr atomic.Value
	for i, c := range clients {
		for q := range each {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if err := download(c, target, uint64(i*each+q), size); err != nil {
					failed.Add(1)
					firstErr.CompareAndSwap(nil, fmt.Sprintf("device %d: %v", i, err))
				}
			}()
		}
	}
	wg.Wait()
	if n := failed.Load(); n > 0 {
		t.Errorf("%d of %d connections failed, the queue dropped %d packets, the first: %v", n, devices*each, s.tun.dropped.Load(), firstErr.Load())
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		var left []string
		s.mu.Lock()
		for _, a := range addrs {
			if s.dials[a] != 0 || s.conns[a] != 0 || len(s.flows[a]) != 0 {
				left = append(left, fmt.Sprintf("%v: %d dialing, %d counted, %d sockets", a, s.dials[a], s.conns[a], len(s.flows[a])))
			}
		}
		arriving := len(s.arriving)
		s.mu.Unlock()
		if len(left) == 0 && arriving == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("after every connection closed: %v, %d still arriving", left, arriving)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// Lookups take a new port each, so a few devices browsing at once make many cones. Every lookup is
// answered, and once they've been quiet for dnsIdle the lookups' cones go, while a port that sent
// elsewhere keeps its minute.
func TestADNSStormIsAnsweredAndItsConesGoAfterDNSIdle(t *testing.T) {
	const devices, lookups = 4, 50
	s, clients, addrs := setupMany(t, devices)
	// A packet to port 53 is a lookup, see sentTo. Nothing listens on 53 here, so remote:53 goes to
	// an echo server, and its replies come back as from remote:53.
	_, p, _ := net.SplitHostPort(udpEcho(t))
	port, _ := strconv.Atoi(p)
	dns := netip.AddrPortFrom(netip.MustParseAddr(remote), 53)
	echo := netip.AddrPortFrom(loopback, uint16(port))
	s.mu.Lock()
	toNet, fromNet := s.toNet, s.fromNet
	s.toNet = func(a netip.AddrPort) netip.AddrPort {
		if a == dns {
			return echo
		}
		return toNet(a)
	}
	s.fromNet = func(a netip.AddrPort) netip.AddrPort {
		if a == echo {
			return dns
		}
		return fromNet(a)
	}
	s.mu.Unlock()
	// Every port stays open on the devices until the end, so their netstacks can't give one port
	// to two lookups, which would make one cone of two.
	var mu sync.Mutex
	var open []net.Conn
	defer func() {
		for _, conn := range open {
			conn.Close()
		}
	}()
	// ask checks the answered port has a cone of its own, at once, since under -race the whole storm
	// can take longer than dnsIdle and the first cones may already be gone by its end.
	ask := func(c *client, addr, msg string, dnsOnly bool) error {
		conn, err := c.net.Dial("udp", addr)
		if err != nil {
			return err
		}
		mu.Lock()
		open = append(open, conn)
		mu.Unlock()
		if err := answered(conn, msg); err != nil {
			return err
		}
		port := netip.MustParseAddrPort(conn.LocalAddr().String())
		s.mu.Lock()
		cn := s.cones[port]
		s.mu.Unlock()
		if cn == nil || cn.dnsOnly.Load() != dnsOnly {
			return fmt.Errorf("port %v has a cone %v, want one with dnsOnly %v", port, cn != nil, dnsOnly)
		}
		return nil
	}
	other := udpEcho(t)
	var wg sync.WaitGroup
	for i, c := range clients {
		// One port talks to something else, so it keeps the full minute.
		if err := ask(c, other, fmt.Sprintf("other %d", i), false); err != nil {
			t.Fatalf("device %d: %v", i, err)
		}
		for q := range lookups {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if err := ask(c, dns.String(), fmt.Sprintf("query %d %d", i, q), true); err != nil {
					t.Errorf("device %d lookup %d: %v", i, q, err)
				}
			}()
		}
	}
	wg.Wait()
	if t.Failed() {
		return
	}
	// The cones go by the time each one last sent, read by a read deadline, not by s.now. So their
	// clocks move back past dnsIdle, and the reads wake at once to look at them. Again on each pass,
	// since under -race a lookup's resend can land after its answer and open its port again.
	age := func() {
		s.mu.Lock()
		var cones []*cone
		for _, c := range s.cones {
			cones = append(cones, c)
		}
		s.mu.Unlock()
		aged := time.Now().Add(-dnsIdle - time.Second).UnixNano()
		for _, c := range cones {
			c.last.Store(aged)
			c.conn.SetReadDeadline(time.Now())
		}
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		age()
		var left []string
		for _, a := range addrs {
			if n := s.tracked(a); n != 1 {
				left = append(left, fmt.Sprintf("%v: %d", a, n))
			}
		}
		if len(left) == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("flows still open after dnsIdle, want only the one that isn't DNS: %v", left)
		}
		time.Sleep(20 * time.Millisecond)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, c := range s.cones {
		if c.dnsOnly.Load() {
			t.Errorf("a lookup's cone at %v outlived dnsIdle", c.device)
		}
	}
}

// answered sends msg on conn and waits for it to come back, sending again each second in case the
// first one is lost while the tunnel is busy.
func answered(conn net.Conn, msg string) error {
	buf := make([]byte, 100)
	for range 10 {
		conn.Write([]byte(msg))
		conn.SetReadDeadline(time.Now().Add(time.Second))
		if n, err := conn.Read(buf); err == nil && string(buf[:n]) == msg {
			return nil
		}
	}
	return fmt.Errorf("no answer to %q", msg)
}

// A call sends small numbered packets both ways while another device downloads as fast as it can.
// Some may be lost, but only where the queue to wireguard-go was full, never in the NAT.
func TestACallNextToADownloadLosesOnlyToTheQueue(t *testing.T) {
	const packets, every, streams = 100, 10 * time.Millisecond, 4
	s, clients, addrs := setupMany(t, 2)
	caller, downloader := clients[0], clients[1]
	// Both devices finish their handshake first, so no packet waits in wireguard-go for one.
	if _, err := fetch(t, downloader, tcpServer(t, 10)); err != nil {
		t.Fatal(err)
	}
	if rtts, err := pings(caller, udpEcho(t), 1, 10*time.Second); err != nil || len(rtts) != 1 {
		t.Fatalf("the caller's first echo: %v", err)
	}
	// The other end of the call notes each packet it gets, and starts its own once it knows where
	// the caller is.
	peer, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	var heard [packets]atomic.Bool
	var heardCount atomic.Int32
	peerDone := make(chan struct{})
	go func() {
		buf := make([]byte, 100)
		started := false
		for {
			n, from, err := peer.ReadFromUDPAddrPort(buf)
			if err != nil {
				return
			}
			var seq int
			if _, err := fmt.Sscanf(string(buf[:n]), "up %d", &seq); err == nil && seq < packets && !heard[seq].Swap(true) {
				heardCount.Add(1)
			}
			if !started {
				started = true
				go func() {
					defer close(peerDone)
					for seq := range packets {
						peer.WriteToUDPAddrPort(fmt.Appendf(nil, "down %d", seq), from)
						time.Sleep(every)
					}
				}()
			}
		}
	}()
	// Downloads of half a megabyte, one after another, that the device reads to their end. A device
	// that cut one off would answer its last packets with resets while its netstack closes, which
	// races, see TestCloseDuringUDPTrafficReturns. A dial still waiting when the call ends is given up,
	// since it may have hit the bug in TestReusingAPortRightAfterTheHostClosedConnects, and cleanup
	// waits for the server to let go of it, so the device has sent its reset by then.
	tcp := tcpServer(t, 512<<10)
	ctx, stop := context.WithCancel(context.Background())
	var dl sync.WaitGroup
	for range streams {
		dl.Add(1)
		go func() {
			defer dl.Done()
			for ctx.Err() == nil {
				conn, err := downloader.net.DialContext(ctx, "tcp", tcp)
				if err != nil {
					continue
				}
				conn.SetDeadline(time.Now().Add(60 * time.Second))
				conn.Write([]byte("hello"))
				io.Copy(io.Discard, conn)
				conn.Close()
			}
		}()
	}
	defer func() {
		stop()
		dl.Wait()
		deadline := time.Now().Add(10 * time.Second)
		for s.tracked(addrs[1]) > 0 && time.Now().Before(deadline) {
			time.Sleep(20 * time.Millisecond)
		}
	}()
	before := s.tun.dropped.Load()
	conn, err := caller.net.Dial("udp", viaRemote(peer.LocalAddr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	var got [packets]bool
	gotCount := 0
	read := make(chan struct{})
	go func() {
		defer close(read)
		buf := make([]byte, 100)
		for gotCount < packets {
			// Long past the peer's last packet, a missing one isn't coming.
			conn.SetReadDeadline(time.Now().Add(5 * time.Second))
			n, err := conn.Read(buf)
			if err != nil {
				return
			}
			var seq int
			if _, err := fmt.Sscanf(string(buf[:n]), "down %d", &seq); err == nil && seq < packets && !got[seq] {
				got[seq] = true
				gotCount++
			}
		}
	}()
	for seq := range packets {
		conn.Write(fmt.Appendf(nil, "up %d", seq))
		time.Sleep(every)
	}
	select {
	case <-peerDone:
	case <-time.After(30 * time.Second):
		t.Fatal("the peer never heard the caller, so it never sent")
	}
	<-read
	deadline := time.Now().Add(5 * time.Second)
	for heardCount.Load() < packets && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	dropped := s.tun.dropped.Load() - before
	upLost, downLost := packets-int(heardCount.Load()), packets-gotCount
	t.Logf("lost %d of %d up and %d of %d down, the queue dropped %d packets", upLost, packets, downLost, packets, dropped)
	// Nothing on the way up drops for a full queue at a call's rate, handleUDP's included.
	if upLost > 0 {
		t.Errorf("%d of %d packets from the caller never reached the other end", upLost, packets)
	}
	if uint64(downLost) > dropped {
		t.Errorf("%d of %d packets to the caller were lost, but the queue dropped only %d", downLost, packets, dropped)
	}
}

// The biggest datagram that fits the tunnel's MTU in one packet reaches the internet whole, and so
// does its echo. TestABigUDPReplyArrivesWhole sends a fragmented one each way.
func TestTheBiggestUnfragmentedUDPArrivesWhole(t *testing.T) {
	_, c := setup(t)
	l, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	arrived := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 65535)
		n, from, err := l.ReadFromUDPAddrPort(buf)
		if err != nil {
			return
		}
		arrived <- bytes.Clone(buf[:n])
		l.WriteToUDPAddrPort(buf[:n], from)
	}()
	msg := pattern(1, MTU-header.IPv4MinimumSize-header.UDPMinimumSize)
	if n := len(replyPackets(netip.MustParseAddrPort(remote+":1"), netip.MustParseAddrPort("10.7.0.2:1"), msg, 0)); n != 1 {
		t.Fatalf("the echo takes %d packets, want it to fit one", n)
	}
	conn, err := c.net.Dial("udp", viaRemote(l.LocalAddr().String()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	conn.Write(msg)
	select {
	case got := <-arrived:
		if !bytes.Equal(got, msg) {
			t.Fatalf("%d bytes reached the internet, not the %d sent", len(got), len(msg))
		}
	case <-time.After(10 * time.Second):
		t.Fatal("nothing reached the internet")
	}
	buf := make([]byte, 2000)
	n, err := conn.Read(buf)
	if err != nil || !bytes.Equal(buf[:n], msg) {
		t.Fatalf("echo of %d bytes, want the %d sent: %v", n, len(msg), err)
	}
}

// Only a router's clients have IPv6, see udp.go. A device with just its IPv4 tunnel address, like a
// laptop that sends IPv6 from its Wi-Fi address, gets no IPv6 UDP out and no socket for it, while
// its IPv4 keeps working.
func TestIPv6UDPFromADeviceThatIsntARouterIsDropped(t *testing.T) {
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
	c := newClientAt(t, s, sPub, cPriv, addr, netip.MustParseAddr("2001:db8::5"))
	if _, err := fetch(t, c, tcpServer(t, 10)); err != nil {
		t.Fatal(err)
	}
	// A listener the IPv6 packets would reach if they got out.
	l, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	v6 := netip.MustParseAddr("2001:db8::7")
	s.mu.Lock()
	toNet := s.toNet
	s.toNet = func(a netip.AddrPort) netip.AddrPort {
		if a.Addr() == v6 {
			return netip.AddrPortFrom(loopback, a.Port())
		}
		return toNet(a)
	}
	s.mu.Unlock()
	_, port, _ := net.SplitHostPort(l.LocalAddr().String())
	conn, err := c.net.Dial("udp", net.JoinHostPort(v6.String(), port))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	for range 3 {
		conn.Write([]byte("v6"))
	}
	// wireguard-go hands a device's packets on in order, so once this echo is back the IPv6 ones
	// have been through the server.
	if rtts, err := pings(c, udpEcho(t), 1, 10*time.Second); err != nil || len(rtts) != 1 {
		t.Fatalf("IPv4 UDP stopped working: %v", err)
	}
	if n := s.tracked(addr); n != 1 {
		t.Fatalf("%d flows, want only the IPv4 one", n)
	}
	if s.routerOf().IsValid() {
		t.Fatal("IPv6 from a Wi-Fi address made the device the router")
	}
	l.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	if n, _, err := l.ReadFromUDPAddrPort(make([]byte, 100)); err == nil {
		t.Fatalf("%d bytes of IPv6 UDP got out", n)
	}
}

// deviceStack is the gVisor stack inside a test device's netstack, which wireguard-go doesn't
// export. A test needs it to pick the device's source port, which a real device does by chance.
func deviceStack(c *client) *stack.Stack {
	return (*stack.Stack)(unsafe.Pointer(reflect.ValueOf(c.net).Elem().FieldByName("stack").Pointer()))
}

// A device connects again from a port it used a moment ago, to the same host, and gets through.
// Devices pick ports by chance, so many short connections to one host do this within minutes.
func TestReusingAPortRightAfterTheHostClosedConnects(t *testing.T) {
	t.Skip("#50: the server's side of the last connection waits out gVisor's 60 s TIME_WAIT and drops the new SYN")
	_, c := setup(t)
	target := netip.MustParseAddrPort(tcpServer(t, 10)) // it closes first, after its 10 bytes
	from := tcpip.FullAddress{Addr: tcpip.AddrFrom4([4]byte{10, 7, 0, 2}), Port: 40000}
	to := tcpip.FullAddress{Addr: tcpip.AddrFrom4(target.Addr().As4()), Port: target.Port()}
	connect := func() error {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for {
			conn, err := gonet.DialTCPWithBind(ctx, deviceStack(c), from, to, header.IPv4ProtocolNumber)
			if err != nil && strings.Contains(err.Error(), "in use") && ctx.Err() == nil {
				time.Sleep(20 * time.Millisecond) // the device's own side of the last one is closing
				continue
			}
			if err != nil {
				return err
			}
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(5 * time.Second))
			conn.Write([]byte("hello"))
			if b, err := io.ReadAll(conn); len(b) != 10 {
				return fmt.Errorf("got %d of 10 bytes: %v", len(b), err)
			}
			return nil
		}
	}
	if err := connect(); err != nil {
		t.Fatal(err)
	}
	if err := connect(); err != nil {
		t.Fatalf("again from the same port: %v", err)
	}
}
