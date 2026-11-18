package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The proxy on the hotspot's IPv6 address (#78). On a carrier that gives the iPhone IPv6 only, a
// Mac, an iPhone or an iPad on the hotspot takes no IPv4 address and can't reach 172.20.10.1. The
// hotspot's IPv6 address is the iPhone's global one, so only clients in the hotspot's own IPv6
// network are served. The tests listen on ::1 and fake the iPhone's interfaces, see ownAre.

// hotspotIs makes hosts the hotspot's addresses, as ListenOn would, without listening for WireGuard
// there, so a test can use addresses no interface has.
func hotspotIs(s *Server, hosts ...netip.Addr) {
	s.bind.mu.Lock()
	s.bind.hosts = hosts
	s.bind.mu.Unlock()
	s.wakeProxy(false)
}

// proxyOn6 starts a server whose proxy listens on loopback for IPv4 and on host6 for IPv6, with
// own as the iPhone's interface addresses, and returns where each listens. The IPv6 socket listens
// on ::1 whatever address it's asked for, and asked gets each address it's asked for.
func proxyOn6(t *testing.T, host6 netip.Addr, own ...string) (s *Server, at4, at6 string, asked chan string) {
	t.Helper()
	s = proxyReady(t)
	ownAre(s, own...)
	asked = make(chan string, 16)
	s.mu.Lock()
	s.proxy.port6 = 0
	listen := s.proxy.listen
	s.proxy.listen = func(ctx context.Context, address string) (net.Listener, error) {
		ap := netip.MustParseAddrPort(address)
		if ap.Addr().Is4() {
			return listen(ctx, address)
		}
		select {
		case asked <- address:
		default:
		}
		return listen(ctx, netip.AddrPortFrom(netip.IPv6Loopback(), ap.Port()).String())
	}
	s.mu.Unlock()
	hotspotIs(s, loopback, host6)
	s.SetProxy(true, false)
	at := proxyListeningOn(t, s, 2)
	return s, at[0], at[1], asked
}

// proxyListeningOn waits for the proxy to listen on n addresses, and returns them as the stats say.
func proxyListeningOn(t *testing.T, s *Server, n int) []string {
	t.Helper()
	var at []string
	if !waitFor(5*time.Second, func() bool { at = s.statsMessage().Proxy.Addresses; return len(at) == n }) {
		t.Fatalf("the proxy listens on %q, want %d addresses", at, n)
	}
	return at
}

// refused says whether the proxy at proxy closes a client's CONNECT without an answer.
func refused(t *testing.T, proxy string) bool {
	t.Helper()
	conn, r, status := tunnel(t, proxy, echoFarEnd(t))
	return status == 0 && ended(conn, r)
}

// A client in the hotspot's IPv6 network is served, CONNECT and plain requests alike, and the
// stats list both addresses, IPv4 first.
func TestAClientInTheHotspotsIPv6NetworkIsServed(t *testing.T) {
	_, at4, at6, _ := proxyOn6(t, netip.IPv6Loopback(), "127.0.0.1/8", "::1/64")
	if !strings.HasPrefix(at4, "127.0.0.1:") || !strings.HasPrefix(at6, "[::1]:") {
		t.Fatalf("listening on %s and %s, want IPv4 first", at4, at6)
	}
	conn, r, status := tunnel(t, at6, echoFarEnd(t))
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("CONNECT over IPv6 got %d", status)
	}
	resp, err := viaProxy(at6).Get("http://" + tcpPage(t, 1000) + "/")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || len(body) != 1000 {
		t.Fatalf("a plain GET over IPv6 got %d with %d bytes", resp.StatusCode, len(body))
	}
}

// A client outside the hotspot's IPv6 network, the internet say, is closed with no answer, and
// logged once a minute at most, as an IPv4 one off the hotspot is. IPv4 still serves.
func TestAnIPv6ClientOutsideTheHotspotsNetworkIsRefused(t *testing.T) {
	serverLog.reset()
	_, at4, at6, _ := proxyOn6(t, netip.MustParseAddr("fd00:1::1"), "fd00:1::1/64")
	for range 3 {
		if !refused(t, at6) {
			t.Fatal("a client outside the hotspot's network was served")
		}
	}
	m, _ := serverLog.take(time.Now())
	var refusals int
	for _, l := range m.Lines {
		if strings.Contains(l.Text, "proxy refused ::1") {
			refusals++
		}
	}
	if refusals != 1 {
		t.Fatalf("logged %q, want one refusal naming the client", texts(m))
	}
	conn, r, status := tunnel(t, at4, echoFarEnd(t))
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("IPv4 got %d", status)
	}
}

// A link-local client is refused: its address can't be typed in a proxy field anyway.
func TestALinkLocalIPv6ClientIsRefused(t *testing.T) {
	_, _, at6, _ := proxyOn6(t, netip.IPv6Loopback(), "::1/64")
	d := net.Dialer{Timeout: time.Second, LocalAddr: &net.TCPAddr{IP: net.ParseIP("fe80::1"), Zone: "lo0"}}
	conn, err := d.Dial("tcp", at6)
	if err != nil {
		t.Skipf("no link-local loopback here: %v", err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: x\r\n\r\n", echoFarEnd(t))
	r := bufio.NewReader(conn)
	if _, err := http.ReadResponse(r, nil); err == nil || !ended(conn, r) {
		t.Fatal("a link-local client was answered")
	}
	for _, c := range []struct {
		net, from string
		want      bool
	}{
		{"2607:fb90:1:2::/64", "2607:fb90:1:2::9", true},
		{"2607:fb90:1:2::/64", "2607:fb90:1:3::9", false},
		{"fe80::/64", "fe80::9", false},
		{"fe80::/64", "fe80::9%bridge100", false},
		{"2607:fb90:1:2::/64", "172.20.10.2", false},
	} {
		if got := inHotspotNet6(netip.MustParsePrefix(c.net), netip.MustParseAddr(c.from)); got != c.want {
			t.Errorf("%s in %s: %v, want %v", c.from, c.net, got, c.want)
		}
	}
	if inHotspotNet6(netip.Prefix{}, netip.MustParseAddr("2607:fb90:1:2::9")) {
		t.Error("no network served a client")
	}
}

// The hotspot's IPv6 network is its address's on-link network, when that's /64 or narrower. A wider
// one isn't one link's, so it serves nobody on IPv6, and IPv4 still serves.
func TestAnIPv6NetworkWiderThanA64ServesNobody(t *testing.T) {
	_, at4, at6, _ := proxyOn6(t, netip.IPv6Loopback(), "::1/48")
	if !refused(t, at6) {
		t.Fatal("a client was served on a /48")
	}
	conn, r, status := tunnel(t, at4, echoFarEnd(t))
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("IPv4 got %d", status)
	}
	addrs := func(cidrs ...string) []net.Addr {
		var out []net.Addr
		for _, c := range cidrs {
			ip, n, _ := net.ParseCIDR(c)
			out = append(out, &net.IPNet{IP: ip, Mask: n.Mask})
		}
		return out
	}
	host := netip.MustParseAddr("2607:fb90:1:2::5")
	for _, c := range []struct {
		addrs []net.Addr
		want  string
	}{
		{addrs("172.20.10.1/28", "2607:fb90:1:2::5/64"), "2607:fb90:1:2::/64"},
		{addrs("2607:fb90:1:2::5/120"), "2607:fb90:1:2::/120"},
		{addrs("2607:fb90:1:2::5/56"), ""},
		{addrs("2607:fb90:1:2::6/64"), ""}, // not the hotspot's address
		{nil, ""},
	} {
		got, ok := hotspotNet6(c.addrs, host)
		if c.want == "" && ok || c.want != "" && got.String() != c.want {
			t.Errorf("%v: %v %v, want %q", c.addrs, got, ok, c.want)
		}
	}
}

// When the hotspot's IPv6 address changes, the proxy stops listening on the old one and listens on
// the new one, and when it goes, IPv4 alone listens until it's back.
func TestTheIPv6ListenerFollowsTheHotspotsAddress(t *testing.T) {
	first, second := netip.MustParseAddr("fd00:1::1"), netip.MustParseAddr("fd00:1::2")
	s, _, old, asked := proxyOn6(t, first, "fd00:1::1/64", "fd00:1::2/64")
	if a := <-asked; a != "[fd00:1::1]:0" {
		t.Fatalf("asked to listen on %s", a)
	}
	hotspotIs(s, loopback, second)
	select {
	case a := <-asked:
		if a != "[fd00:1::2]:0" {
			t.Fatalf("asked to listen on %s, want the new address", a)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("didn't listen on the new address")
	}
	if !waitFor(5*time.Second, func() bool {
		at := s.statsMessage().Proxy.Addresses
		return len(at) == 2 && at[1] != old
	}) {
		t.Fatalf("listening on %q, want the old IPv6 socket gone", s.statsMessage().Proxy.Addresses)
	}
	if c, err := net.DialTimeout("tcp", old, time.Second); err == nil {
		c.Close()
		t.Fatal("still listening on the old address")
	}
	hotspotIs(s, loopback)
	at := proxyListeningOn(t, s, 1)
	if !strings.HasPrefix(at[0], "127.0.0.1:") {
		t.Fatalf("listening on %q, want IPv4 only", at)
	}
	hotspotIs(s, loopback, first)
	proxyListeningOn(t, s, 2)
}

// ListenOn is what moves the hotspot's addresses on the iPhone: the proxy follows it on real sockets.
func TestTheIPv6ListenerFollowsListenOn(t *testing.T) {
	s := proxyReady(t)
	ownAre(s, "::1/64")
	s.mu.Lock()
	s.proxy.port6 = 0
	s.mu.Unlock()
	s.SetProxy(true, false)
	proxyListeningOn(t, s, 1)
	if err := s.ListenOn([]netip.Addr{loopback, netip.IPv6Loopback()}); err != nil {
		t.Fatal(err)
	}
	at6 := proxyListeningOn(t, s, 2)[1]
	conn, r, status := tunnel(t, at6, echoFarEnd(t))
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("over IPv6 got %d", status)
	}
	if err := s.ListenOn([]netip.Addr{loopback}); err != nil {
		t.Fatal(err)
	}
	proxyListeningOn(t, s, 1)
	if c, err := net.DialTimeout("tcp", at6, time.Second); err == nil {
		c.Close()
		t.Fatal("still listening on IPv6 after its address went")
	}
}

// Pause, Block and Close end IPv6 clients' connections as they do IPv4 ones'.
func TestPauseBlockAndCloseCoverIPv6Clients(t *testing.T) {
	s, _, at6, _ := proxyOn6(t, netip.IPv6Loopback(), "::1/64")
	echo := echoFarEnd(t)

	conn, r, _ := tunnel(t, at6, echo)
	s.SetProxy(true, true)
	if !ended(conn, r) {
		t.Fatal("pause left an IPv6 connection open")
	}
	if _, _, status := tunnel(t, at6, echo); status == http.StatusOK {
		t.Fatal("a paused proxy made a new IPv6 connection")
	}
	s.SetProxy(true, false)

	local, localR, status := tunnel(t, at6, "192.168.1.50:"+port(echo))
	if status != http.StatusOK || !echoes(local, localR) {
		t.Fatalf("got %d", status)
	}
	blockLocal(s, true)
	if !ended(local, localR) {
		t.Fatal("Block left an IPv6 client's connection to a local address open")
	}

	conn, r, status = tunnel(t, at6, echo)
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("resumed, got %d", status)
	}
	idle, err := net.Dial("tcp", at6)
	if err != nil {
		t.Fatal(err)
	}
	defer idle.Close()
	s.Close()
	if !ended(conn, r) || !ended(idle, bufio.NewReader(idle)) {
		t.Fatal("Close left an IPv6 connection open")
	}
	if c, err := net.DialTimeout("tcp", at6, time.Second); err == nil {
		c.Close()
		t.Fatal("the proxy still listens on IPv6 after Close")
	}
}

// Swift reads "addresses": IPv4 first, IPv6 in brackets, and an empty list while off.
func TestTheStatsListBothAddresses(t *testing.T) {
	s, at4, at6, _ := proxyOn6(t, netip.IPv6Loopback(), "::1/64")
	exported(t, s)
	read := func() []string {
		js, _ := statsJSON()
		var m struct {
			Proxy map[string]json.RawMessage `json:"proxy"`
		}
		if err := json.Unmarshal([]byte(js), &m); err != nil {
			t.Fatal(err)
		}
		if _, ok := m.Proxy["address"]; ok {
			t.Fatalf("stats %s still have the old key", js)
		}
		var at []string
		if err := json.Unmarshal(m.Proxy["addresses"], &at); err != nil || at == nil {
			t.Fatalf("stats %s: addresses %v", js, err)
		}
		return at
	}
	if at := read(); !slices.Equal(at, []string{at4, at6}) {
		t.Fatalf("addresses %q, want %q", at, []string{at4, at6})
	}
	s.SetProxy(false, false)
	if at := read(); len(at) != 0 {
		t.Fatalf("addresses %q while off", at)
	}
}

// iOS closes a suspended app's sockets: the IPv6 one listens again on the same address and port,
// so the devices' settings keep working.
func TestTheIPv6ListenerListensAgainAfterIOSClosesIt(t *testing.T) {
	s, _, at6, _ := proxyOn6(t, netip.MustParseAddr("2607:fb90:1:2::5"), "2607:fb90:1:2::5/64")
	s.mu.Lock()
	ln := s.proxy.run.socks[1].ln
	s.mu.Unlock()
	ln.Close() // what iOS does underneath
	if !waitFor(5*time.Second, func() bool {
		c, err := net.DialTimeout("tcp", at6, time.Second)
		if err == nil {
			c.Close()
		}
		return err == nil
	}) {
		t.Fatalf("didn't listen again on %s", at6)
	}
	if at := s.statsMessage().Proxy.Addresses; len(at) != 2 || at[1] != at6 {
		t.Fatalf("listening on %q, want %s again", at, at6)
	}
}

// Reading the iPhone's interfaces can fail. The IPv6 socket then doesn't listen with no network to
// serve, which would refuse every client until the socket failed: it tries again, as after a failed
// listen, and serves once the read works.
func TestTheIPv6ListenerReadsTheHotspotsNetworkAgainAfterAFailure(t *testing.T) {
	s, _, at6, _ := proxyOn6(t, netip.IPv6Loopback(), "::1/64")
	s.mu.Lock()
	list := s.listAddrs
	var failed atomic.Bool
	s.listAddrs = func() ([]net.Addr, error) {
		if !failed.Swap(true) {
			return nil, errors.New("no addresses for you")
		}
		return list()
	}
	ln := s.proxy.run.socks[1].ln
	s.mu.Unlock()
	ln.Close() // iOS closes it, and the next read fails
	echo := echoFarEnd(t)
	if !waitFor(10*time.Second, func() bool {
		c, err := net.DialTimeout("tcp", at6, time.Second)
		if err != nil {
			return false // not listening again yet
		}
		c.Close()
		conn, r, status := tunnel(t, at6, echo)
		return status == http.StatusOK && echoes(conn, r)
	}) {
		t.Fatalf("after one failed read, %s still refuses clients", at6)
	}
}

// One device can't take every plain dial either: past its share, its next plain request gets 502 at
// once, while another device's still goes through. The test's two devices are ::1 and 127.0.0.1.
func TestOneClientCantTakeEveryPlainDial(t *testing.T) {
	s, at4, at6, _ := proxyOn6(t, netip.IPv6Loopback(), "127.0.0.1/8", "::1/64")
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	var started atomic.Int32
	s.mu.Lock()
	s.proxy.maxDials, s.proxy.maxDialsPerClient = 4, 2
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		if !slices.Contains([]string{"80", "81", "82"}, port(address)) {
			return toLoopback(ctx, network, address)
		}
		started.Add(1)
		<-release // a far end that never answers
		return nil, errors.New("no answer")
	}
	s.mu.Unlock()
	for i := range 2 {
		conn, err := net.Dial("tcp", at4)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		fmt.Fprintf(conn, "GET http://%s:%d/ HTTP/1.1\r\nHost: x\r\n\r\n", remote, 80+i)
		if !waitFor(5*time.Second, func() bool { return started.Load() > int32(i) }) {
			t.Fatal("the dial never started")
		}
	}
	start := time.Now()
	if status, _ := rawGet(t, at4, fmt.Sprintf("http://%s:82/", remote)); status != http.StatusBadGateway || time.Since(start) > time.Second {
		t.Fatalf("past its share got %d after %v, want 502 at once", status, time.Since(start))
	}
	far, _ := pageAt(t)
	if status, _ := rawGet(t, at6, "http://"+far+"/"); status != http.StatusOK {
		t.Fatalf("the other device got %d", status)
	}
}
