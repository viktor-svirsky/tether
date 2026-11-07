package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// ownAre makes the iPhone's own addresses these, as net.InterfaceAddrs gives them: CIDR text, an
// IPv4 one in its 16-byte form, the way net.IP keeps it. Nil addrs makes the listing fail.
func ownAre(s *Server, addrs ...string) {
	s.mu.Lock()
	s.listAddrs = func() ([]net.Addr, error) {
		if addrs == nil {
			return nil, errors.New("no addresses for you")
		}
		var out []net.Addr
		for _, a := range addrs {
			ip, n, err := net.ParseCIDR(a)
			if err != nil {
				panic(err)
			}
			out = append(out, &net.IPNet{IP: ip, Mask: n.Mask})
		}
		return out, nil
	}
	s.mu.Unlock()
}

// startAlone starts a server with no devices, for what needs no traffic.
func startAlone(t *testing.T) *Server {
	priv, _ := keyPair(t)
	s, err := Start([]netip.Addr{loopback}, 0, priv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}

// The iPhone's own addresses are refused, and the networks they're in are not: the other devices
// on the hotspot, the other nodes of a VPN that shares the cellular range (Tailscale's 100.64/10),
// the Wi-Fi's other hosts.
func TestTheIPhonesOwnAddressesStayInside(t *testing.T) {
	s := startAlone(t)
	serverLog.reset()
	ownAre(s, "172.20.10.1/28", "100.70.12.34/10", "100.101.102.103/32", "192.168.1.5/24", "2607:fb90:1:2::5/64", "127.0.0.1/8", "fe80::1/64")
	s.refreshLocal()
	s.refreshLocal() // the same again, as every 5 s, logs nothing
	for _, a := range []string{"172.20.10.1", "100.70.12.34", "100.101.102.103", "192.168.1.5", "2607:fb90:1:2::5"} {
		if s.leaves(netip.MustParseAddr(a)) {
			t.Errorf("%s is the iPhone's own and went out", a)
		}
	}
	for _, a := range []string{"172.20.10.2", "100.70.12.35", "100.101.102.104", "192.168.1.6", "2607:fb90:1:2::6", "1.1.1.1"} {
		if !s.leaves(netip.MustParseAddr(a)) {
			t.Errorf("%s is a neighbour and stayed inside", a)
		}
	}
	// Loopback and link-local stay inside anyway, so the log leaves them out.
	want := "the iPhone's own addresses, which devices can't reach: 100.70.12.34, 100.101.102.103, 172.20.10.1, 192.168.1.5, 2607:fb90:1:2::5"
	if m, _ := serverLog.take(time.Now()); len(m.Lines) != 1 || m.Lines[0].Text != want {
		t.Fatalf("logged %q, want %q", texts(m), want)
	}
}

// The addresses are read again on their own, so a VPN coming up or a new cellular address is
// refused within seconds, and an address the iPhone no longer has goes out again. A failed read
// keeps the last ones.
func TestTheOwnAddressesFollowTheIPhone(t *testing.T) {
	s := startAlone(t)
	a, b := netip.MustParseAddr("198.51.100.8"), netip.MustParseAddr("198.51.100.9")
	ownAre(s, "198.51.100.8/32")
	if !waitFor(3*localEvery, func() bool { return !s.leaves(a) }) {
		t.Fatalf("%v still goes out %v after it became the iPhone's", a, 3*localEvery)
	}
	ownAre(s, "198.51.100.9/32")
	s.refreshLocal() // what the ticker does, shown above
	if s.leaves(b) || !s.leaves(a) {
		t.Fatalf("the change wasn't picked up: %v leaves %v, %v leaves %v", a, s.leaves(a), b, s.leaves(b))
	}
	ownAre(s)
	s.refreshLocal()
	if s.leaves(b) || !s.leaves(a) {
		t.Fatal("a failed read changed the addresses")
	}
}

// A connection to the iPhone itself is refused at once, without dialing, and counts nothing.
func TestAConnectionToTheIPhoneItselfIsRefusedAtOnce(t *testing.T) {
	s, c := setup(t)
	var dialed atomic.Int32
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		dialed.Add(1)
		return toLoopback(ctx, network, address)
	}
	s.mu.Unlock()
	addr := tcpServer(t, 100)
	if n, err := fetch(t, c, addr); err != nil || n != 100 {
		t.Fatalf("before it was the iPhone's: %d bytes, %v", n, err)
	}
	ownAre(s, remote+"/32")
	s.refreshLocal()
	before := dialed.Load()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	began := time.Now()
	_, err := c.net.DialContext(ctx, "tcp", addr)
	took := time.Since(began)
	if err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("got %v, want a refusal", err)
	}
	if took >= dialTimeout {
		t.Fatalf("the refusal took %v, as long as a dial that times out", took)
	}
	if dialed.Load() != before {
		t.Fatal("dialed the iPhone's own address")
	}
	uncounted(t, s, netip.MustParseAddr("10.7.0.2"))
}

// UDP and ping to the iPhone itself get nothing back, as for the tunnel's own addresses.
func TestUDPAndPingToTheIPhoneItselfGetNoReply(t *testing.T) {
	s, c := setup(t)
	echo := udpEcho(t)
	ask := func(wait time.Duration) error {
		conn, err := c.net.Dial("udp", echo)
		if err != nil {
			return err
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(wait))
		conn.Write([]byte("x"))
		_, err = conn.Read(make([]byte, 16))
		return err
	}
	if err := ask(5 * time.Second); err != nil { // the first packet of a cone is slow under -race
		t.Fatalf("UDP before it was the iPhone's: %v", err)
	}
	if _, err := pingFrom(c, remote, 0, []byte("x"), 5*time.Second); err != nil {
		t.Fatalf("ping before it was the iPhone's: %v", err)
	}
	ownAre(s, remote+"/32")
	s.refreshLocal()
	if err := ask(time.Second); err == nil {
		t.Fatal("UDP to the iPhone's own address got a reply")
	}
	if echo, err := pingFrom(c, remote, 1, []byte("x"), 500*time.Millisecond); err == nil {
		t.Fatalf("a ping to the iPhone's own address got %v", echo)
	}
}

// A device whose tunnel works opens the config page through it, at the address and port Tether
// listens on. That one stays reachable: the page's port on another own address doesn't, nor
// another port on the page's address.
func TestTheConfigPageStaysReachableThroughTheTunnel(t *testing.T) {
	s, c := setup(t)
	if want := []netip.AddrPort{netip.AddrPortFrom(loopback, pagePort)}; !slices.Equal(s.page, want) {
		t.Fatalf("the page is at %v, want %v: port 80 where WireGuard listens", s.page, want)
	}
	page, other := tcpServer(t, 100), tcpServer(t, 100)
	s.mu.Lock()
	s.page = []netip.AddrPort{netip.MustParseAddrPort(page)}
	s.mu.Unlock()
	ownAre(s, remote+"/32", "198.51.100.8/32")
	s.refreshLocal()
	if n, err := fetch(t, c, page); err != nil || n != 100 {
		t.Fatalf("the config page: %d bytes, %v", n, err)
	}
	// The test dialer reaches loopback whatever the address, so each of these would connect if let out.
	_, port, _ := net.SplitHostPort(page)
	for _, addr := range []string{other, net.JoinHostPort("198.51.100.8", port)} {
		if _, err := fetch(t, c, addr); err == nil {
			t.Errorf("%s isn't the page and connected", addr)
		}
	}
}

// A plain DNS server on one of the iPhone's own addresses, a VPN's resolver say, still answers
// lookups to 10.7.0.1, over UDP and TCP: where they go is Tether's choice. A device asking that
// address itself gets nothing.
func TestAPlainServerOnAnOwnAddressStillAnswersFor10701(t *testing.T) {
	s, c := setup(t)
	ownAre(s, remote+"/32")
	s.refreshLocal()
	echo := netip.MustParseAddrPort(udpEcho(t))
	s.SetDNS(&dnsUpstream{udp: []netip.AddrPort{echo}})
	q := lookupFor(t, 5, "example.com.", 0)
	if a, err := lookupUDP(c, q, 5*time.Second); err != nil || !bytes.Equal(a, q) {
		t.Fatalf("over UDP: got %x %v, want the echo of %x", a, err, q)
	}
	conn, err := c.net.Dial("udp", echo.String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(time.Second))
	conn.Write(q)
	if _, err := conn.Read(make([]byte, 512)); err == nil {
		t.Fatal("the device reached the iPhone's own address by asking it directly")
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			conn, err := l.Accept()
			if err != nil {
				return
			}
			go func() { defer conn.Close(); io.Copy(conn, conn) }()
		}
	}()
	s.SetDNS(&dnsUpstream{udp: []netip.AddrPort{netip.MustParseAddrPort(viaRemote(l.Addr().String()))}})
	if answers, err := lookupsTCP(c, 5*time.Second, q); err != nil || !bytes.Equal(answers[0], q) {
		t.Fatalf("over TCP: got %x %v, want the echo of %x", answers, err, q)
	}
}
