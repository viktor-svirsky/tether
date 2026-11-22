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
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// The HTTP proxy (#78): a device without WireGuard sets 172.20.10.1:8118 as its Wi-Fi proxy, and
// its connections are made again from the iPhone, under the rules a tunnel device has. The tests
// listen on loopback and take loopback clients as the hotspot's, and the far ends are at remote,
// see viaLoopback.

// proxyOn starts a server with no devices and the proxy on, and returns where it listens.
func proxyOn(t *testing.T) (*Server, string) {
	t.Helper()
	s := proxyReady(t)
	s.SetProxy(true, false)
	return s, proxyListening(t, s)
}

// proxyReady starts a server whose proxy, once on, listens on loopback for loopback clients.
func proxyReady(t *testing.T) *Server {
	t.Helper()
	s := startAlone(t)
	s.mu.Lock() // the server reads them after taking s.mu, so the race detector sees the order (#250)
	viaLoopback(s)
	s.proxy.at = netip.MustParseAddrPort("127.0.0.1:0")
	s.proxy.clients = netip.MustParsePrefix("127.0.0.0/8")
	s.mu.Unlock()
	return s
}

// proxyListening waits for the proxy to listen, and returns where, as the stats say.
func proxyListening(t *testing.T, s *Server) string {
	t.Helper()
	var at string
	if !waitFor(5*time.Second, func() bool {
		if all := s.statsMessage().Proxy.Addresses; len(all) > 0 {
			at = all[0]
		}
		return at != ""
	}) {
		t.Fatal("the proxy isn't listening")
	}
	return at
}

// tunnel asks the proxy at proxy to CONNECT to target, and returns the connection and the
// proxy's status. On 200 the connection carries the far end's bytes.
func tunnel(t *testing.T, proxy, target string) (net.Conn, *bufio.Reader, int) {
	t.Helper()
	conn, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	conn.SetDeadline(time.Now().Add(fetchTimeout()))
	fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target)
	r := bufio.NewReader(conn)
	resp, err := http.ReadResponse(r, &http.Request{Method: http.MethodConnect})
	if err != nil {
		return conn, r, 0 // closed without an answer
	}
	return conn, r, resp.StatusCode
}

// echoes says whether a tunnel carries bytes to an echoing far end and back.
func echoes(conn net.Conn, r *bufio.Reader) bool {
	if _, err := conn.Write([]byte("hello")); err != nil {
		return false
	}
	b := make([]byte, 5)
	_, err := io.ReadFull(r, b)
	return err == nil && string(b) == "hello"
}

func echoFarEnd(t *testing.T) string {
	return farEnd(t, func(conn *net.TCPConn) { io.Copy(conn, conn) })
}

// ended says whether conn is closed by the proxy within a few seconds.
func ended(conn net.Conn, r *bufio.Reader) bool {
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		if _, err := r.ReadByte(); err != nil {
			var ne net.Error
			return !errors.As(err, &ne) || !ne.Timeout()
		}
	}
}

// viaProxy is an HTTP client that sends everything through the proxy, one connection a request.
func viaProxy(proxy string) *http.Client {
	u, _ := url.Parse("http://" + proxy)
	return &http.Client{Timeout: fetchTimeout(), Transport: &http.Transport{Proxy: http.ProxyURL(u), DisableKeepAlives: true}}
}

// namesDoH is a DoH server that answers A and AAAA lookups from names, and counts the lookups.
type namesDoH struct {
	*httptest.Server
	asked atomic.Int32
	// While held, every answer waits for free or for its request to end. holdAAAA holds only AAAA ones.
	held     atomic.Bool
	holdAAAA atomic.Bool
	free     chan struct{}
	freeOnce sync.Once
}

func (d *namesDoH) release() { d.freeOnce.Do(func() { close(d.free) }) }

func newNamesDoH(t *testing.T, names map[string][]string) *namesDoH {
	d := &namesDoH{free: make(chan struct{})}
	t.Cleanup(d.release)
	d.Server = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		d.asked.Add(1)
		q, _ := io.ReadAll(r.Body)
		if d.held.Load() {
			select {
			case <-d.free:
			case <-r.Context().Done():
				return
			}
		}
		var p dnsmessage.Parser
		h, err := p.Start(q)
		if err != nil {
			http.Error(w, "not DNS", http.StatusBadRequest)
			return
		}
		qs, err := p.AllQuestions()
		if err != nil || len(qs) != 1 {
			http.Error(w, "not one question", http.StatusBadRequest)
			return
		}
		if qs[0].Type == dnsmessage.TypeAAAA && d.holdAAAA.Load() {
			select {
			case <-d.free:
			case <-r.Context().Done():
				return
			}
		}
		b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: h.ID, Response: true, RecursionDesired: true, RecursionAvailable: true})
		b.StartQuestions()
		b.Question(qs[0])
		b.StartAnswers()
		rh := dnsmessage.ResourceHeader{Name: qs[0].Name, Class: dnsmessage.ClassINET, TTL: 60}
		for _, text := range names[strings.TrimSuffix(qs[0].Name.String(), ".")] {
			a := netip.MustParseAddr(text)
			switch {
			case a.Is4() && qs[0].Type == dnsmessage.TypeA:
				rh.Type = dnsmessage.TypeA
				b.AResource(rh, dnsmessage.AResource{A: a.As4()})
			case !a.Is4() && qs[0].Type == dnsmessage.TypeAAAA:
				rh.Type = dnsmessage.TypeAAAA
				b.AAAAResource(rh, dnsmessage.AAAAResource{AAAA: a.As16()})
			}
		}
		m, _ := b.Finish()
		w.Header().Set("Content-Type", "application/dns-message")
		w.Write(m)
	}))
	d.EnableHTTP2 = true
	d.StartTLS()
	t.Cleanup(d.Close)
	return d
}

// viaNames points s's lookups at d, see viaDoH.
func viaNames(s *Server, d *namesDoH) {
	s.dohClient = d.Client()
	spare := d.Client().Transport.(*http.Transport).Clone()
	spare.DisableKeepAlives = true
	s.dohSpare = &http.Client{Transport: spare}
	s.SetDNS(&dnsUpstream{doh: d.URL + "/abc123"})
}

func port(addr string) string {
	_, p, _ := net.SplitHostPort(addr)
	return p
}

func TestAConnectThroughTheProxyMovesBytesBothWays(t *testing.T) {
	_, proxy := proxyOn(t)
	conn, r, status := tunnel(t, proxy, echoFarEnd(t))
	if status != http.StatusOK {
		t.Fatalf("CONNECT got %d, want 200", status)
	}
	big := strings.Repeat("tether", 100_000)
	go conn.Write([]byte(big))
	b := make([]byte, len(big))
	if _, err := io.ReadFull(r, b); err != nil || string(b) != big {
		t.Fatalf("the far end's echo came back wrong: %v", err)
	}
}

// A client may send its TLS hello right behind the CONNECT, before the answer. Those bytes are
// already read by the proxy, and must still reach the far end.
func TestBytesSentRightBehindTheConnectReachTheFarEnd(t *testing.T) {
	_, proxy := proxyOn(t)
	target := echoFarEnd(t)
	conn, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(fetchTimeout()))
	fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\nearly", target, target)
	r := bufio.NewReader(conn)
	if resp, err := http.ReadResponse(r, &http.Request{Method: http.MethodConnect}); err != nil || resp.StatusCode != http.StatusOK {
		t.Fatalf("CONNECT: %v %v", resp, err)
	}
	b := make([]byte, 5)
	if _, err := io.ReadFull(r, b); err != nil || string(b) != "early" {
		t.Fatalf("got %q, %v, want the early bytes echoed", b, err)
	}
}

// A plain http:// request is forwarded with its own headers. The ones meant for the proxy, and
// the hop-by-hop ones, stay behind: the far end must not learn anything the device told the proxy.
func TestAPlainGETIsForwardedWithoutTheProxysHeaders(t *testing.T) {
	_, proxy := proxyOn(t)
	got := make(chan *http.Request, 1)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	far := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got <- r
		w.Header().Set("X-Far", "yes")
		io.WriteString(w, "page")
	})}
	go far.Serve(l)
	t.Cleanup(func() { far.Close() })
	target := "http://" + viaRemote(l.Addr().String()) + "/some/path?q=1"
	req, _ := http.NewRequest(http.MethodGet, target, nil)
	req.Header.Set("X-Mine", "kept")
	req.Header.Set("Proxy-Authorization", "Basic c2VjcmV0OnNlY3JldA==")
	req.Header.Set("Proxy-Connection", "keep-alive")
	req.Header.Set("Connection", "X-Hop")
	req.Header.Set("X-Hop", "dropped")
	resp, err := viaProxy(proxy).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || string(body) != "page" || resp.Header.Get("X-Far") != "yes" {
		t.Fatalf("got %d %q %v, want the far end's page", resp.StatusCode, body, resp.Header)
	}
	r := <-got
	if r.URL.RequestURI() != "/some/path?q=1" || r.Header.Get("X-Mine") != "kept" {
		t.Fatalf("the far end got %s with %v", r.URL.RequestURI(), r.Header)
	}
	for _, h := range []string{"Proxy-Authorization", "Proxy-Connection", "X-Hop", "X-Forwarded-For", "Forwarded", "Via"} {
		if v := r.Header.Get(h); v != "" {
			t.Errorf("the far end got %s: %s", h, v)
		}
	}
}

// A request in origin form ("GET / HTTP/1.1") is one for a web server, not a proxy: it doesn't say
// where to go, and the proxy isn't a page.
func TestAnOriginFormRequestIsABadRequest(t *testing.T) {
	_, proxy := proxyOn(t)
	conn, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(fetchTimeout()))
	io.WriteString(conn, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil || resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("got %v %v, want 400", resp, err)
	}
}

// Anything that isn't HTTP, a SOCKS greeting or a TLS hello say, gets no tunnel and is closed.
func TestGarbageFirstBytesAreRefused(t *testing.T) {
	_, proxy := proxyOn(t)
	for _, first := range []string{"\x05\x01\x00", "\x16\x03\x01\x00\x05hello\r\n\r\n", "\r\n\r\n", "CONNECT\r\n\r\n", "CONNECT :443 HTTP/1.1\r\n\r\n", "CONNECT example.com HTTP/1.1\r\nHost: example.com\r\n\r\n"} {
		conn, err := net.Dial("tcp", proxy)
		if err != nil {
			t.Fatal(err)
		}
		conn.SetDeadline(time.Now().Add(fetchTimeout()))
		io.WriteString(conn, first)
		r := bufio.NewReader(conn)
		resp, err := http.ReadResponse(r, nil)
		if err == nil && resp.StatusCode < 400 {
			t.Errorf("%q got %d", first, resp.StatusCode)
		}
		if !ended(conn, r) {
			t.Errorf("%q left the connection open", first)
		}
		conn.Close()
	}
}

// Only the hotspot's clients are served: never the cellular side or a Wi-Fi the iPhone is on. A
// refusal is logged with where it came from, at most once a minute.
func TestAClientOffTheHotspotIsRefused(t *testing.T) {
	s := proxyReady(t)
	s.mu.Lock()
	s.proxy.clients = netip.MustParsePrefix("172.20.10.0/28")
	s.mu.Unlock()
	serverLog.reset()
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	for range 3 {
		conn, r, status := tunnel(t, proxy, echoFarEnd(t))
		if status != 0 || !ended(conn, r) {
			t.Fatalf("a client off the hotspot got %d", status)
		}
	}
	m, _ := serverLog.take(time.Now())
	var refusals int
	for _, l := range m.Lines {
		if strings.Contains(l.Text, "proxy refused 127.0.0.1") {
			refusals++
		}
	}
	if refusals != 1 {
		t.Fatalf("logged %q, want one refusal naming the client", texts(m))
	}
}

// A name is looked up through Tether's own DNS, the upstream set in Settings, so Control D applies
// to the proxy's devices too.
func TestAHostnameGoesThroughTethersDNS(t *testing.T) {
	s, proxy := proxyOn(t)
	d := newNamesDoH(t, map[string][]string{"far.example": {remote}})
	viaNames(s, d)
	conn, r, status := tunnel(t, proxy, "far.example:"+port(echoFarEnd(t)))
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("CONNECT far.example got %d", status)
	}
	if d.asked.Load() == 0 {
		t.Fatal("the DoH server was never asked")
	}
	if _, _, status := tunnel(t, proxy, "nowhere.example:443"); status != http.StatusBadGateway {
		t.Fatalf("a name with no address got %d, want 502", status)
	}
}

// A name with both families is tried on both: when its IPv4 address doesn't answer, its IPv6 one
// still makes the connection. NAT64 can't help an IPv4 far end that refuses.
func TestANameWhoseIPv4FarEndRefusesIsReachedOverIPv6(t *testing.T) {
	s, proxy := proxyOn(t)
	d := newNamesDoH(t, map[string][]string{"both.example": {remote, "2001:db8::7"}})
	viaNames(s, d)
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		if strings.HasPrefix(address, remote+":") {
			return nil, errors.New("connection refused")
		}
		return toLoopback(ctx, network, address)
	}
	s.mu.Unlock()
	conn, r, status := tunnel(t, proxy, "both.example:"+port(echoFarEnd(t)))
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("CONNECT both.example got %d, want its IPv6 address tried", status)
	}
}

// A DNS server that answers A but never AAAA doesn't hold the connection up: once one family has
// addresses, the other gets a short grace, as in Happy Eyeballs, not the lookup's whole timeout.
func TestAnAAAAThatNeverAnswersDoesntHoldTheConnection(t *testing.T) {
	s, proxy := proxyOn(t)
	d := newNamesDoH(t, map[string][]string{"slow.example": {remote}})
	d.holdAAAA.Store(true)
	viaNames(s, d)
	start := time.Now()
	conn, r, status := tunnel(t, proxy, "slow.example:"+port(echoFarEnd(t)))
	if took := time.Since(start); status != http.StatusOK || !echoes(conn, r) || took > time.Second {
		t.Fatalf("CONNECT slow.example got %d after %v, want 200 well under a second", status, took)
	}
}

// Without an upstream in Settings, names are looked up the way the iPhone's own apps do.
func TestWithoutADNSUpstreamTheIPhonesResolverAnswers(t *testing.T) {
	s := proxyReady(t)
	var asked atomic.Int32
	s.mu.Lock()
	s.proxy.systemLookup = func(_ context.Context, host string) ([]netip.Addr, error) {
		asked.Add(1)
		if host == "far.example" {
			return []netip.Addr{netip.MustParseAddr(remote)}, nil
		}
		return nil, fmt.Errorf("no such host %s", host)
	}
	s.mu.Unlock()
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	conn, r, status := tunnel(t, proxy, "far.example:"+port(echoFarEnd(t)))
	if status != http.StatusOK || !echoes(conn, r) || asked.Load() != 1 {
		t.Fatalf("got %d with %d lookups", status, asked.Load())
	}
}

// A name is checked by the address it resolves to, the one that's dialed, so a name can't reach
// what an address can't: the iPhone itself, loopback, an IPv4-mapped loopback, or a local network
// with Block.
func TestAHostnameIsCheckedByItsAddress(t *testing.T) {
	s, proxy := proxyOn(t)
	ownAre(s, "172.20.10.1/28", "203.0.113.5/32")
	s.refreshLocal()
	d := newNamesDoH(t, map[string][]string{
		"own.example":     {"203.0.113.5"},
		"localhost":       {"127.0.0.1"},
		"mapped.example":  {"::ffff:127.0.0.1"},
		"hotspot.example": {"172.20.10.1"},
		"lan.example":     {"192.168.1.50"},
	})
	viaNames(s, d)
	echo := port(echoFarEnd(t))
	for _, name := range []string{"own.example", "localhost", "mapped.example", "hotspot.example"} {
		if _, _, status := tunnel(t, proxy, name+":"+echo); status != http.StatusForbidden {
			t.Errorf("%s got %d, want 403", name, status)
		}
	}
	conn, r, status := tunnel(t, proxy, "lan.example:"+echo)
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("a local network with Allow got %d", status)
	}
	blockLocal(s, true)
	if _, _, status := tunnel(t, proxy, "lan.example:"+echo); status != http.StatusForbidden {
		t.Fatalf("a local network with Block got %d, want 403", status)
	}
}

// Literal addresses follow the same rules, IPv4-mapped IPv6 ones read as the IPv4 address they
// carry, and the proxy's own port is the iPhone's like any other.
func TestLiteralAddressesFollowTheRules(t *testing.T) {
	s, proxy := proxyOn(t)
	ownAre(s, "172.20.10.1/28")
	s.refreshLocal()
	var dialed atomic.Int32
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		dialed.Add(1)
		return toLoopback(ctx, network, address)
	}
	s.mu.Unlock()
	echo := port(echoFarEnd(t))
	for _, target := range []string{
		"127.0.0.1:" + echo,
		"[::ffff:127.0.0.1]:" + echo,
		"[::ffff:172.20.10.1]:" + echo,
		"172.20.10.1:8118",
		proxy,
		"[::1]:" + echo,
		"10.7.0.1:53",
		"0.0.0.0:" + echo,
	} {
		if _, _, status := tunnel(t, proxy, target); status != http.StatusForbidden {
			t.Errorf("%s got %d, want 403", target, status)
		}
	}
	if n := dialed.Load(); n != 0 {
		t.Fatalf("refused targets were dialed %d times", n)
	}
	blockLocal(s, true)
	if _, _, status := tunnel(t, proxy, "[::ffff:192.168.1.50]:"+echo); status != http.StatusForbidden {
		t.Fatalf("a mapped local address with Block got %d, want 403", status)
	}
}

// The config page is on the iPhone's own address, and stays reachable through the proxy, as it is
// through the tunnel.
func TestTheConfigPageIsReachableThroughTheProxy(t *testing.T) {
	s, proxy := proxyOn(t)
	ownAre(s, "172.20.10.1/28")
	s.refreshLocal()
	echo := echoFarEnd(t)
	page := netip.AddrPortFrom(netip.MustParseAddr("172.20.10.1"), netip.MustParseAddrPort(echo).Port())
	s.SetPage([]netip.AddrPort{page})
	blockLocal(s, true)
	conn, r, status := tunnel(t, proxy, page.String())
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("the config page got %d", status)
	}
}

func TestAFarEndThatRefusesIsABadGateway(t *testing.T) {
	_, proxy := proxyOn(t)
	if _, _, status := tunnel(t, proxy, refusedPort(t)); status != http.StatusBadGateway {
		t.Fatalf("got %d, want 502", status)
	}
	resp, err := viaProxy(proxy).Get("http://" + refusedPort(t) + "/")
	if err != nil || resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("a GET got %v %v, want 502", resp, err)
	}
	resp.Body.Close()
}

// Block turning on resets a proxy connection to a local address that's open, as it does a tunnel
// device's.
func TestBlockTurningOnEndsAnOpenProxyConnectionToALocalAddress(t *testing.T) {
	s, proxy := proxyOn(t)
	conn, r, status := tunnel(t, proxy, "192.168.1.50:"+port(echoFarEnd(t)))
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("got %d", status)
	}
	other, otherR, _ := tunnel(t, proxy, echoFarEnd(t))
	blockLocal(s, true)
	if !ended(conn, r) {
		t.Fatal("the connection to a local address is still open with Block")
	}
	if !echoes(other, otherR) {
		t.Fatal("Block ended a connection to the internet")
	}
}

// Paused, the proxy ends the open connections, answers a new CONNECT with 403, and resumed it
// serves again.
func TestPauseEndsOpenProxyConnectionsAndAnswersNewOnesWith403(t *testing.T) {
	s, proxy := proxyOn(t)
	echo := echoFarEnd(t)
	conn, r, _ := tunnel(t, proxy, echo)
	idle, err := net.Dial("tcp", proxy) // connected, no request yet
	if err != nil {
		t.Fatal(err)
	}
	defer idle.Close()
	// Admitted first: paused, admit keeps a new connection to answer its request.
	if !waitFor(5*time.Second, func() bool { return s.statsMessage().Proxy.Open == 2 }) {
		t.Fatal("the idle connection wasn't admitted")
	}
	s.SetProxy(true, true)
	if !ended(conn, r) || !ended(idle, bufio.NewReader(idle)) {
		t.Fatal("pause left a connection open")
	}
	if _, _, status := tunnel(t, proxy, echo); status != http.StatusForbidden {
		t.Fatalf("paused, CONNECT got %d, want 403", status)
	}
	if !s.statsMessage().Proxy.Paused {
		t.Fatal("the stats don't say it's paused")
	}
	s.SetProxy(true, false)
	conn, r, status := tunnel(t, proxy, echo)
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("resumed, got %d", status)
	}
}

// The proxy's bytes count to it, one device for all its clients, and to the totals.
func TestTheProxysBytesAreCountedToIt(t *testing.T) {
	s, proxy := proxyOn(t)
	conn, r, _ := tunnel(t, proxy, echoFarEnd(t))
	if !echoes(conn, r) {
		t.Fatal("no echo")
	}
	// A tunnel counts its bytes once each way: the 5 sent and the 5 echoed.
	var m statsMessage
	if !waitFor(5*time.Second, func() bool { m = s.statsMessage(); return m.Proxy.Up == 5 && m.Proxy.Down == 5 }) {
		t.Fatalf("after the tunnel %+v, want 5 up and 5 down", m.Proxy)
	}
	conn.Close()
	// A plain request counts what crossed to the far end once: the request, and the page with its
	// headers, well under twice the page.
	resp, err := viaProxy(proxy).Get("http://" + tcpPage(t, 1000) + "/")
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	if !waitFor(5*time.Second, func() bool { m = s.statsMessage(); return m.Proxy.Down >= 5+1000 }) {
		t.Fatalf("after the page %+v, want it counted", m.Proxy)
	}
	time.Sleep(100 * time.Millisecond) // anything counted twice would come now
	m = s.statsMessage()
	if up, down := m.Proxy.Up-5, m.Proxy.Down-5; up < 30 || up > 400 || down < 1000 || down > 1400 {
		t.Fatalf("the page counted %d up and %d down, want a request and 1000 bytes with headers", up, down)
	}
	if m.Up != m.Proxy.Up || m.Down != m.Proxy.Down {
		t.Fatalf("proxy %+v, totals up %d down %d, want the same with no device", m.Proxy, m.Up, m.Down)
	}
}

// tcpPage is a far end that answers each HTTP request with n bytes.
func tcpPage(t *testing.T, n int) string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(make([]byte, n))
	})}
	go srv.Serve(l)
	t.Cleanup(func() { srv.Close() })
	return viaRemote(l.Addr().String())
}

// Close ends every proxy connection and stops listening before it returns.
func TestCloseEndsEveryProxyConnection(t *testing.T) {
	s, proxy := proxyOn(t)
	conn, r, _ := tunnel(t, proxy, echoFarEnd(t))
	idle, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	defer idle.Close()
	done := make(chan struct{})
	go func() { s.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Close didn't return")
	}
	if !ended(conn, r) || !ended(idle, bufio.NewReader(idle)) {
		t.Fatal("Close left a proxy connection open")
	}
	if c, err := net.DialTimeout("tcp", proxy, time.Second); err == nil {
		c.Close()
		t.Fatal("the proxy still listens after Close")
	}
	if left := s.proxyFlowsLeft(); left != 0 {
		t.Fatalf("%d proxy connections still kept", left)
	}
}

// Close during a dial returns at once, and a connection the dial makes anyway isn't left open.
func TestCloseDuringAProxyDialClosesWhatItMade(t *testing.T) {
	s, proxy := proxyOn(t)
	dialing := make(chan struct{}, 1)
	made := make(chan net.Conn, 1)
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		dialing <- struct{}{}
		<-ctx.Done()
		// Made as the context ended, as a dial already done when Close came would be.
		c, err := toLoopback(context.Background(), network, address)
		if err == nil {
			made <- c
		}
		return c, err
	}
	s.mu.Unlock()
	conn, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\n\r\n", echoFarEnd(t))
	<-dialing
	done := make(chan struct{})
	go func() { s.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Close waited for the dial")
	}
	closedConn(t, madeConn(t, made))
}

// madeConn is the connection the test's dial made, failing the test if it made none.
func madeConn(t *testing.T, made chan net.Conn) net.Conn {
	t.Helper()
	select {
	case c := <-made:
		return c
	case <-time.After(10 * time.Second):
		t.Fatal("the dial made no connection")
		return nil
	}
}

// closedConn fails the test unless c is closed on this side, within a few seconds.
func closedConn(t *testing.T, c net.Conn) {
	t.Helper()
	if !waitFor(5*time.Second, func() bool {
		_, err := c.Write([]byte("x"))
		return errors.Is(err, net.ErrClosed)
	}) {
		c.Close()
		t.Fatal("the dialed connection was left open")
	}
}

// Pause during a dial: the connection it makes is closed, not kept.
func TestPauseDuringAProxyDialClosesWhatItMade(t *testing.T) {
	s, proxy := proxyOn(t)
	dialing, release := make(chan struct{}, 1), make(chan struct{})
	made := make(chan net.Conn, 1)
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		dialing <- struct{}{}
		<-release
		// Pause closed the client, which ended ctx: a dial already done would come back anyway.
		c, err := toLoopback(context.Background(), network, address)
		if err == nil {
			made <- c
		}
		return c, err
	}
	s.mu.Unlock()
	conn, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\n\r\n", echoFarEnd(t))
	<-dialing
	s.SetProxy(true, true)
	close(release)
	closedConn(t, madeConn(t, made))
	if left := s.proxyFlowsLeft(); left != 0 {
		t.Fatalf("%d proxy connections kept while paused", left)
	}
}

// Turned off, the proxy stops listening and ends its connections, and turned on again it listens.
func TestTurningTheProxyOffStopsItAndOnStartsIt(t *testing.T) {
	s, proxy := proxyOn(t)
	conn, r, _ := tunnel(t, proxy, echoFarEnd(t))
	s.SetProxy(false, false)
	if !ended(conn, r) {
		t.Fatal("off left a connection open")
	}
	if c, err := net.DialTimeout("tcp", proxy, time.Second); err == nil {
		c.Close()
		t.Fatal("the proxy still listens when off")
	}
	if at := s.statsMessage().Proxy.Addresses; len(at) != 0 {
		t.Fatalf("the stats say it listens on %q when off", at)
	}
	s.SetProxy(true, false)
	again := proxyListening(t, s)
	conn, r, status := tunnel(t, again, echoFarEnd(t))
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("on again, got %d", status)
	}
}

// A client that connects and never finishes its request is closed after the handshake time, so a
// stuck or hostile client can't hold a connection slot.
func TestASlowClientThatNeverSendsARequestIsClosed(t *testing.T) {
	s := proxyReady(t)
	s.mu.Lock()
	s.proxy.handshake = 300 * time.Millisecond
	s.mu.Unlock()
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	conn, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	io.WriteString(conn, "CONNECT far.example:443 HTTP/1.1\r\n") // and nothing more
	if !ended(conn, bufio.NewReader(conn)) {
		t.Fatal("a client that never finished its request is still connected")
	}
}

// A listener whose Accept fails is listened on again, on the same address, so the devices' settings
// keep working.
func TestTheProxyListensAgainAfterIOSClosesItsSocket(t *testing.T) {
	s := proxyReady(t)
	s.mu.Lock()
	s.proxy.retry = 50 * time.Millisecond
	s.mu.Unlock()
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	s.mu.Lock()
	ln := s.proxy.run.socks[0].ln
	s.mu.Unlock()
	ln.Close() // what iOS does underneath
	var status int
	var conn net.Conn
	var r *bufio.Reader
	echo := echoFarEnd(t)
	if !waitFor(5*time.Second, func() bool {
		c, err := net.DialTimeout("tcp", proxy, time.Second)
		if err != nil {
			return false
		}
		c.Close()
		conn, r, status = tunnel(t, proxy, echo)
		return status == http.StatusOK
	}) || !echoes(conn, r) {
		t.Fatalf("the proxy didn't listen again on %s", proxy)
	}
	if at := s.statsMessage().Proxy.Addresses; len(at) != 1 || at[0] != proxy {
		t.Fatalf("listening on %q, want %s again", at, proxy)
	}
}

// iOS shuts a suspended app's sockets down with pid_shutdown_sockets, during a phone call say. A
// listener's Accept then blocks for good, unlike above, while new connections to it are refused,
// so the proxy itself sees nothing. The WireGuard socket's reads fail, and the server listens again
// on both. It runs in a process of its own, since the call ends every socket of the process.
func TestTheProxyListensAgainAfterIOSShutsTheSocketsDown(t *testing.T) {
	if os.Getenv("TETHER_OWN_PROCESS") == "" {
		inOwnProcess(t)
		return
	}
	s := proxyReady(t)
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	if conn, r, status := tunnel(t, proxy, echoFarEnd(t)); status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("before: status %d", status)
	}
	if _, _, e := syscall.Syscall(syscall.SYS_PID_SHUTDOWN_SOCKETS, uintptr(os.Getpid()), 2, 0); e != 0 {
		t.Fatalf("pid_shutdown_sockets: %v", e)
	}
	echo := echoFarEnd(t) // the first one's socket is gone too
	var conn net.Conn
	var r *bufio.Reader
	var status int
	if !waitFor(5*time.Second, func() bool {
		c, err := net.DialTimeout("tcp", proxy, time.Second)
		if err != nil {
			return false // refused until it listens again
		}
		c.Close()
		conn, r, status = tunnel(t, proxy, echo)
		return status == http.StatusOK
	}) || !echoes(conn, r) {
		t.Fatalf("the proxy didn't listen again on %s: status %d", proxy, status)
	}
}

// inOwnProcess runs the test that calls it again in a new process, with TETHER_OWN_PROCESS set,
// and fails it if that run fails.
func inOwnProcess(t *testing.T) {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^"+t.Name()+"$", "-test.count=1", "-test.v")
	cmd.Env = append(os.Environ(), "TETHER_OWN_PROCESS=1")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v:\n%s", err, out)
	}
}

// shutDownUnseen shuts the process's sockets down as iOS does, but the server never hears of it:
// the bind was opened again, by ListenOn say, before its failed read was seen, which forgets it.
// So reopen doesn't run, and only ListenOn can bring the proxy back.
func shutDownUnseen(t *testing.T, s *Server) {
	t.Helper()
	s.bind.mu.Lock()
	s.bind.died = func() {}
	s.bind.mu.Unlock()
	if _, _, e := syscall.Syscall(syscall.SYS_PID_SHUTDOWN_SOCKETS, uintptr(os.Getpid()), 2, 0); e != 0 {
		t.Fatalf("pid_shutdown_sockets: %v", e)
	}
	if !waitFor(5*time.Second, func() bool {
		s.bind.mu.Lock()
		defer s.bind.mu.Unlock()
		return s.bind.broken
	}) {
		t.Fatal("the bind didn't see its socket fail")
	}
	s.bind.mu.Lock()
	s.bind.broken = false
	s.bind.mu.Unlock()
}

// proxyWorksAgain fails the test unless a tunnel through the proxy at proxy works within a few seconds.
func proxyWorksAgain(t *testing.T, proxy string) {
	t.Helper()
	echo := echoFarEnd(t)
	var conn net.Conn
	var r *bufio.Reader
	var status int
	if !waitFor(5*time.Second, func() bool {
		c, err := net.DialTimeout("tcp", proxy, time.Second)
		if err != nil {
			return false // refused until it listens again
		}
		c.Close()
		conn, r, status = tunnel(t, proxy, echo)
		return status == http.StatusOK
	}) || !echoes(conn, r) {
		t.Fatalf("the proxy didn't listen again on %s: status %d", proxy, status)
	}
}

// ListenOn brings back a proxy listener iOS shut down even when the server never heard of the
// shutdown, and the address didn't change: it sees the listener is dead.
func TestListeningAgainBringsBackADeadProxyListenerUnheardOf(t *testing.T) {
	if os.Getenv("TETHER_OWN_PROCESS") == "" {
		inOwnProcess(t)
		return
	}
	s := proxyReady(t)
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	shutDownUnseen(t, s)
	if err := s.ListenOn([]netip.Addr{loopback}); err != nil {
		t.Fatal(err)
	}
	proxyWorksAgain(t, proxy)
}

// When the new addresses can't be listened on and the old ones are listened on again, the proxy
// comes back too.
func TestAFailedListenOnStillBringsBackADeadProxyListener(t *testing.T) {
	if os.Getenv("TETHER_OWN_PROCESS") == "" {
		inOwnProcess(t)
		return
	}
	s := proxyReady(t)
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	shutDownUnseen(t, s)
	// An address on no interface here, like a new IPv6 address that can't take a socket yet.
	if err := s.ListenOn([]netip.Addr{netip.MustParseAddr("192.0.2.1")}); err == nil {
		t.Fatal("listened on an address that isn't here")
	}
	proxyWorksAgain(t, proxy)
}

// A client that half-closes a CONNECT and then leaves, asleep say, ends its tunnel, though the far
// end stays silent: its own direction ended, so nothing read its socket to see it go. The reset
// stands for keepalive giving up, which leaves the same error on the socket.
func TestAClientThatHalfClosedAndLeftEndsItsTunnel(t *testing.T) {
	s := proxyReady(t)
	s.mu.Lock()
	s.proxy.goneCheck = 50 * time.Millisecond
	s.mu.Unlock()
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	finished := make(chan struct{})
	silent := make(chan struct{})
	t.Cleanup(func() { close(silent) })
	far := farEnd(t, func(conn *net.TCPConn) {
		io.Copy(io.Discard, conn) // to the client's FIN
		close(finished)
		<-silent
	})
	conn, _, status := tunnel(t, proxy, far)
	if status != http.StatusOK {
		t.Fatalf("status %d", status)
	}
	conn.(*net.TCPConn).CloseWrite()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("the client's FIN didn't reach the far end")
	}
	resetTCP(conn)
	if !waitFor(5*time.Second, func() bool { return s.statsMessage().Proxy.Open == 0 && s.proxyFlowsLeft() == 0 }) {
		t.Fatalf("still open: %d connections, %d sockets", s.statsMessage().Proxy.Open, s.proxyFlowsLeft())
	}
}

// A proxy that can't listen, its port taken say, says so in the stats, so the screen doesn't look
// fine. Once the port is free it listens, and stops saying so.
func TestAProxyThatCantListenSaysSo(t *testing.T) {
	taken, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	s := proxyReady(t)
	s.mu.Lock()
	s.proxy.at = netip.MustParseAddrPort(taken.Addr().String())
	s.proxy.retry = 50 * time.Millisecond
	s.mu.Unlock()
	s.SetProxy(true, false)
	if !waitFor(5*time.Second, func() bool { return s.statsMessage().Proxy.CantListen }) {
		t.Fatal("the stats don't say it can't listen")
	}
	if at := s.statsMessage().Proxy.Addresses; len(at) != 0 {
		t.Fatalf("listening on %q", at)
	}
	taken.Close()
	proxyListening(t, s)
	if s.statsMessage().Proxy.CantListen {
		t.Fatal("listening, and the stats still say it can't")
	}
}

// Past the cap a new connection is closed at once, and one that ends makes room again.
func TestTheProxysConnectionsStopAtTheCap(t *testing.T) {
	s := proxyReady(t)
	s.mu.Lock()
	s.proxy.maxConns = 2
	s.mu.Unlock()
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	echo := echoFarEnd(t)
	first, r1, _ := tunnel(t, proxy, echo)
	second, r2, _ := tunnel(t, proxy, echo)
	if !echoes(first, r1) || !echoes(second, r2) {
		t.Fatal("the two under the cap don't work")
	}
	if conn, r, status := tunnel(t, proxy, echo); status != 0 || !ended(conn, r) {
		t.Fatalf("one past the cap got %d", status)
	}
	first.Close()
	if !waitFor(5*time.Second, func() bool { return s.statsMessage().Proxy.Open == 1 }) {
		t.Fatalf("%d open after one closed", s.statsMessage().Proxy.Open)
	}
	conn, r, status := tunnel(t, proxy, echo)
	if status != http.StatusOK || !echoes(conn, r) {
		t.Fatalf("after one closed, got %d", status)
	}
}

// Many requests at once, each with its far end, are all served, and counted down to none after.
func TestManyProxyConnectionsAtOnce(t *testing.T) {
	s, proxy := proxyOn(t)
	echo := echoFarEnd(t)
	var wg sync.WaitGroup
	var failed atomic.Int32
	for range 30 {
		wg.Go(func() {
			conn, err := net.Dial("tcp", proxy)
			if err != nil {
				failed.Add(1)
				return
			}
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(fetchTimeout()))
			fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", echo, echo)
			r := bufio.NewReader(conn)
			resp, err := http.ReadResponse(r, &http.Request{Method: http.MethodConnect})
			if err != nil || resp.StatusCode != http.StatusOK || !echoes(conn, r) {
				failed.Add(1)
			}
		})
	}
	wg.Wait()
	if n := failed.Load(); n > 0 {
		t.Fatalf("%d of 30 failed", n)
	}
	if !waitFor(5*time.Second, func() bool { return s.statsMessage().Proxy.Open == 0 && s.proxyFlowsLeft() == 0 }) {
		t.Fatalf("%d open, %d kept after they all closed", s.statsMessage().Proxy.Open, s.proxyFlowsLeft())
	}
}

// proxyFlowsLeft is how many connections the server keeps for the proxy.
func (s *Server) proxyFlowsLeft() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.flows[proxyFlows])
}

// The config message turns the proxy on and pauses it. Without the key it's off, as before.
func TestTheConfigMessageCarriesTheProxy(t *testing.T) {
	for js, want := range map[string]configProxy{
		`{"v":1,"peers":[]}`:                                    {},
		`{"v":1,"peers":[],"proxy":{"on":true}}`:                {On: true},
		`{"v":1,"peers":[],"proxy":{"on":true,"paused":true}}`:  {On: true, Paused: true},
		`{"v":1,"peers":[],"proxy":{"on":false,"paused":true}}`: {Paused: true},
		`{"v":1,"peers":[],"proxy":{"on":true,"password":"x"}}`: {On: true},
	} {
		_, _, _, got, err := parseConfig(js)
		if err != nil || got != want {
			t.Errorf("%s: %+v, %v, want %+v", js, got, err, want)
		}
	}
	s := proxyReady(t)
	exported(t, s)
	if err := configure(`{"v":1,"peers":[],"proxy":{"on":true}}`); err != nil {
		t.Fatal(err)
	}
	proxyListening(t, s)
	if err := configure(`{"v":1,"peers":[],"proxy":{"on":true,"paused":true}}`); err != nil || !s.statsMessage().Proxy.Paused {
		t.Fatalf("not paused: %v", err)
	}
	if err := configure(`{"v":1,"peers":[]}`); err != nil {
		t.Fatal(err)
	}
	if at := s.statsMessage().Proxy.Addresses; len(at) != 0 {
		t.Fatalf("a message without the proxy left it on at %q", at)
	}
}

// Without a 172.20.10.x address or an IPv6 one of the hotspot's the proxy has nowhere to listen,
// and says so.
func TestTheProxyListensOnlyOnTheHotspotsAddresses(t *testing.T) {
	s := startAlone(t) // on loopback, not the hotspot
	serverLog.reset()
	s.SetProxy(true, false)
	if at := s.statsMessage().Proxy.Addresses; len(at) != 0 {
		t.Fatalf("listening on %q", at)
	}
	waitForLine(t, "proxy: no hotspot address to listen on")
	if at, ok := hotspotHost([]netip.Addr{netip.MustParseAddr("2607:fb90:1:2::5"), netip.MustParseAddr("172.20.10.1")}); !ok || at != netip.MustParseAddr("172.20.10.1") {
		t.Fatalf("picked %v", at)
	}
	if at, ok := hotspotHost([]netip.Addr{netip.MustParseAddr("2607:fb90:1:2::5")}); ok {
		t.Fatalf("picked %v on IPv6 only", at)
	}
	for hosts, want := range map[string]string{
		"172.20.10.1,2607:fb90:1:2::5":  "2607:fb90:1:2::5",
		"2607:fb90:1:2::5":              "2607:fb90:1:2::5",
		"172.20.10.1":                   "",
		"172.20.10.1,fe80::1%bridge100": "",
		"::ffff:172.20.10.1":            "",
	} {
		var addrs []netip.Addr
		for _, h := range strings.Split(hosts, ",") {
			addrs = append(addrs, netip.MustParseAddr(h))
		}
		at, ok := hotspotHost6(addrs)
		if want == "" && ok || want != "" && at.String() != want {
			t.Errorf("%s: picked %v %v, want %q", hosts, at, ok, want)
		}
	}
}

// The stats carry the proxy, and stats.json, which Swift reads, has its keys.
func TestTheStatsCarryTheProxy(t *testing.T) {
	s, proxy := proxyOn(t)
	exported(t, s)
	js, _ := statsJSON()
	var m map[string]any
	if err := json.Unmarshal([]byte(js), &m); err != nil {
		t.Fatal(err)
	}
	p, ok := m["proxy"].(map[string]any)
	if at, _ := p["addresses"].([]any); !ok || len(at) != 1 || at[0] != proxy || p["paused"] != false {
		t.Fatalf("stats %s", js)
	}
}

// The target a request names, as the proxy reads it, never panics, and a target it takes always
// has a host and a port that isn't 0. `go test` runs the seeds. Fuzz with:
// go test -run '^$' -fuzz FuzzProxyTarget
func FuzzProxyTarget(f *testing.F) {
	for _, seed := range []string{
		"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n",
		"CONNECT [::ffff:127.0.0.1]:443 HTTP/1.1\r\n\r\n",
		"CONNECT [fe80::1%25en0]:443 HTTP/1.1\r\n\r\n",
		"CONNECT example.com:0 HTTP/1.1\r\n\r\n",
		"CONNECT example.com:99999 HTTP/1.1\r\n\r\n",
		"GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n",
		"GET http://example.com:8080/x?y HTTP/1.1\r\n\r\n",
		"GET https://example.com/ HTTP/1.1\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n",
		"GET http://user:pw@[::1]:80/ HTTP/1.1\r\n\r\n",
		"GET http:///nohost HTTP/1.1\r\n\r\n",
	} {
		f.Add(seed)
	}
	f.Fuzz(func(t *testing.T, raw string) {
		r, err := http.ReadRequest(bufio.NewReader(strings.NewReader(raw)))
		if err != nil {
			return
		}
		host, p, ok := proxyTarget(r)
		if !ok {
			return
		}
		if host == "" || p == 0 || strings.ContainsAny(host, "[]%") {
			t.Fatalf("%q gave host %q port %d", raw, host, p)
		}
	})
}

// An IPv6 literal with a zone isn't one Tether checks: the zone hides it from the iPhone's own
// addresses and from Block's ranges, so a zoned target is refused before anything is dialed, on
// both paths.
func TestAZonedAddressIsRefused(t *testing.T) {
	s, proxy := proxyOn(t)
	ownAre(s, "2607:fb90:1:2::5/64")
	s.refreshLocal()
	blockLocal(s, true)
	var dialed atomic.Int32
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		dialed.Add(1)
		return toLoopback(ctx, network, address)
	}
	s.mu.Unlock()
	echo := port(echoFarEnd(t))
	for _, host := range []string{"[2607:fb90:1:2::5%25en0]", "[fd00::5%25en0]", "[fe80::1%25en0]"} {
		if _, _, status := tunnel(t, proxy, host+":"+echo); status == http.StatusOK {
			t.Errorf("CONNECT %s got %d", host, status)
		}
		resp, err := viaProxy(proxy).Get("http://" + host + ":" + echo + "/")
		if err == nil {
			if resp.StatusCode == http.StatusOK {
				t.Errorf("GET %s got %d", host, resp.StatusCode)
			}
			resp.Body.Close()
		}
	}
	if n := dialed.Load(); n != 0 {
		t.Fatalf("zoned targets were dialed %d times", n)
	}
}

// pageAt is a far end that answers each request with its RawQuery, and counts the connections it
// saw closed, so a test can tell the proxy's pooled one went.
func pageAt(t *testing.T) (string, *atomic.Int32) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var closed atomic.Int32
	srv := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, r.URL.RawQuery) }),
		ConnState: func(_ net.Conn, st http.ConnState) {
			if st == http.StateClosed {
				closed.Add(1)
			}
		},
	}
	go srv.Serve(l)
	t.Cleanup(func() { srv.Close() })
	return viaRemote(l.Addr().String()), &closed
}

// rawGet sends one absolute-form GET for target as written, and returns the status and body.
func rawGet(t *testing.T, proxy, target string) (int, string) {
	t.Helper()
	conn, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(fetchTimeout()))
	u, _ := url.Parse(target)
	fmt.Fprintf(conn, "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", target, u.Host)
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		return 0, ""
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

// The query reaches the far end as the device wrote it, even one Go's own parsing would reject:
// the proxy passes requests on, it doesn't clean them.
func TestAPlainRequestKeepsItsQueryAsWritten(t *testing.T) {
	_, proxy := proxyOn(t)
	far, _ := pageAt(t)
	for _, q := range []string{"b=2;a=1", "z=1&a=%zz&b=2", "x"} {
		if status, got := rawGet(t, proxy, "http://"+far+"/p?"+q); status != http.StatusOK || got != q {
			t.Errorf("?%s reached the far end as ?%s (%d)", q, got, status)
		}
	}
}

// A device's name lookups are capped like a tunnel device's. A client that gives up doesn't free
// its slot while its lookup still runs, so closing and asking again can't pile lookups up.
func TestTheProxysLookupsStopAtTheCap(t *testing.T) {
	s := proxyReady(t)
	s.mu.Lock()
	s.proxy.maxLookups = 2
	s.mu.Unlock()
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	d := newNamesDoH(t, map[string][]string{"far.example": {remote}})
	d.held.Store(true)
	viaNames(s, d)
	for i := range 2 {
		conn, err := net.Dial("tcp", proxy)
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(conn, "CONNECT name%d.example:443 HTTP/1.1\r\n\r\n", i)
		if !waitFor(5*time.Second, func() bool { return d.asked.Load() > int32(i) }) {
			t.Fatal("the lookup never reached the DoH server")
		}
		conn.Close()
	}
	start := time.Now()
	if _, _, status := tunnel(t, proxy, "far.example:"+port(echoFarEnd(t))); status != http.StatusBadGateway || time.Since(start) > time.Second {
		t.Fatalf("one past the cap got %d after %v, want 502 at once", status, time.Since(start))
	}
	d.release()
	echo := echoFarEnd(t)
	var conn net.Conn
	var r *bufio.Reader
	if !waitFor(10*time.Second, func() bool {
		var status int
		conn, r, status = tunnel(t, proxy, "far.example:"+port(echo))
		return status == http.StatusOK
	}) || !echoes(conn, r) {
		t.Fatal("the lookups that ended didn't free their slots")
	}
}

// A plain request's dial goes on after its client leaves, since the transport keeps what it makes
// for its pool. Those dials are capped too, so a client that asks for a far end that never answers
// and leaves, again and again, can't pile them up past its slot. Once they end, their slots are free.
func TestTheProxysPlainDialsStopAtTheCap(t *testing.T) {
	s := proxyReady(t)
	var started atomic.Int32
	release := make(chan struct{})
	var once sync.Once
	free := func() { once.Do(func() { close(release) }) }
	t.Cleanup(free) // before the server's Close, which doesn't wait for them
	s.mu.Lock()
	s.proxy.maxDials = 2
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		if !slices.Contains([]string{"80", "81", "82"}, port(address)) {
			return toLoopback(ctx, network, address)
		}
		started.Add(1)
		<-release // a far end that never answers, even after the client left
		return nil, errors.New("no answer")
	}
	s.mu.Unlock()
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	for i := range 2 {
		conn, err := net.Dial("tcp", proxy)
		if err != nil {
			t.Fatal(err)
		}
		fmt.Fprintf(conn, "GET http://%s:%d/ HTTP/1.1\r\nHost: x\r\n\r\n", remote, 80+i)
		if !waitFor(5*time.Second, func() bool { return started.Load() > int32(i) }) {
			t.Fatal("the dial never started")
		}
		conn.Close()
	}
	if !waitFor(5*time.Second, func() bool { return s.statsMessage().Proxy.Open == 0 }) {
		t.Fatal("the clients that left still hold their slots")
	}
	start := time.Now()
	if status, _ := rawGet(t, proxy, fmt.Sprintf("http://%s:82/", remote)); status != http.StatusBadGateway || time.Since(start) > time.Second {
		t.Fatalf("one past the cap got %d after %v, want 502 at once", status, time.Since(start))
	}
	if n := started.Load(); n != 2 {
		t.Fatalf("%d dials started past a cap of 2", n)
	}
	free()
	far, _ := pageAt(t)
	if !waitFor(5*time.Second, func() bool { status, _ := rawGet(t, proxy, "http://"+far+"/"); return status == http.StatusOK }) {
		t.Fatal("the dials that ended didn't free their slots")
	}
}

// One device can't take every slot: past its share, its own next connection is refused while the
// proxy still has room for others.
func TestOneClientCantTakeEveryProxySlot(t *testing.T) {
	s := proxyReady(t)
	s.mu.Lock()
	s.proxy.maxConns, s.proxy.maxPerClient = 4, 2
	s.mu.Unlock()
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	echo := echoFarEnd(t)
	for range 2 {
		if conn, r, status := tunnel(t, proxy, echo); status != http.StatusOK || !echoes(conn, r) {
			t.Fatalf("under its share got %d", status)
		}
	}
	if conn, r, status := tunnel(t, proxy, echo); status != 0 || !ended(conn, r) {
		t.Fatalf("past its share got %d", status)
	}
}

// Turned on while the hotspot's address isn't back, the proxy fails to listen, says so once, and
// listens as soon as the server is told to listen again, not at its next retry.
func TestTheProxyListensWhenTheServerListensAgain(t *testing.T) {
	s := proxyReady(t)
	taken, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	s.proxy.at = netip.MustParseAddrPort(taken.Addr().String())
	s.proxy.retry = time.Hour
	s.mu.Unlock()
	serverLog.reset()
	s.SetProxy(true, false)
	waitForLine(t, "proxy: can't listen")
	taken.Close()
	if err := s.ListenOn([]netip.Addr{loopback}); err != nil {
		t.Fatal(err)
	}
	proxyListening(t, s)
}

// While it can't listen, the proxy retries without a line each time: one says so, and the next says
// it listens again.
func TestTheProxySaysOnceThatItCantListen(t *testing.T) {
	s := proxyReady(t)
	taken, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	s.mu.Lock()
	s.proxy.at = netip.MustParseAddrPort(taken.Addr().String())
	s.proxy.retry = 10 * time.Millisecond
	s.mu.Unlock()
	serverLog.reset()
	s.SetProxy(true, false)
	time.Sleep(500 * time.Millisecond)
	m, _ := serverLog.take(time.Now())
	var lines int
	for _, l := range m.Lines {
		if strings.Contains(l.Text, "proxy: can't listen") {
			lines++
		}
	}
	if lines != 1 {
		t.Fatalf("logged %q, want one line that it can't listen", texts(m))
	}
}

// failingListener is a socket iOS broke: it listens, and every Accept fails.
type failingListener struct{ net.Listener }

func (failingListener) Accept() (net.Conn, error) {
	return nil, errors.New("software caused connection abort")
}

// A socket that listens but can't accept isn't working, so the retries keep backing off instead of
// starting again from the first wait each time it listens.
func TestTheProxyBacksOffWhileItsSocketCantAccept(t *testing.T) {
	s := proxyReady(t)
	var listens atomic.Int32
	s.mu.Lock()
	s.proxy.retry = 50 * time.Millisecond
	s.proxy.listen = func(ctx context.Context, address string) (net.Listener, error) {
		listens.Add(1)
		l, err := net.Listen("tcp4", address)
		if err != nil {
			return nil, err
		}
		return failingListener{l}, nil
	}
	s.mu.Unlock()
	s.SetProxy(true, false)
	time.Sleep(time.Second)
	// Backing off: at 0, 50, 150, 350 and 750 ms. Starting over each time: about 20.
	if n := listens.Load(); n > 6 {
		t.Fatalf("listened %d times in a second", n)
	}
}

// The plain path follows the same rules as CONNECT: no iPhone-own address, loopback or local
// network with Block, and nothing refused is dialed.
func TestThePlainPathFollowsTheRules(t *testing.T) {
	s, proxy := proxyOn(t)
	ownAre(s, "172.20.10.1/28")
	s.refreshLocal()
	var dialed atomic.Int32
	s.mu.Lock()
	s.dial = func(ctx context.Context, network, address string) (net.Conn, error) {
		dialed.Add(1)
		return toLoopback(ctx, network, address)
	}
	s.mu.Unlock()
	far, _ := pageAt(t)
	blockLocal(s, true)
	for _, target := range []string{
		"http://127.0.0.1:" + port(far) + "/",
		"http://[::ffff:127.0.0.1]:" + port(far) + "/",
		"http://172.20.10.1:8118/",
		"http://192.168.1.50:" + port(far) + "/",
	} {
		if status, _ := rawGet(t, proxy, target); status != http.StatusForbidden {
			t.Errorf("%s got %d, want 403", target, status)
		}
	}
	if n := dialed.Load(); n != 0 {
		t.Fatalf("refused targets were dialed %d times", n)
	}
}

// Pause ends the plain path's pooled connections to the far ends too, answers a request while
// paused with a 403 page that says Tether paused it, and resumed the path works again.
func TestPauseEndsThePlainPathsPooledConnections(t *testing.T) {
	s, proxy := proxyOn(t)
	far, closed := pageAt(t)
	if status, _ := rawGet(t, proxy, "http://"+far+"/"); status != http.StatusOK {
		t.Fatalf("got %d", status)
	}
	if !waitFor(5*time.Second, func() bool { return s.proxyFlowsLeft() == 1 }) {
		t.Fatalf("%d kept, want the pooled connection to the far end", s.proxyFlowsLeft())
	}
	s.SetProxy(true, true)
	if !waitFor(5*time.Second, func() bool { return closed.Load() == 1 && s.proxyFlowsLeft() == 0 }) {
		t.Fatalf("pause left the pooled connection open: %d closed, %d kept", closed.Load(), s.proxyFlowsLeft())
	}
	if status, body := rawGet(t, proxy, "http://"+far+"/"); status != http.StatusForbidden || !strings.Contains(body, "Tether paused") {
		t.Fatalf("paused, got %d %q, want 403 saying Tether paused it", status, body)
	}
	s.SetProxy(true, false)
	if status, _ := rawGet(t, proxy, "http://"+far+"/"); status != http.StatusOK {
		t.Fatalf("resumed, got %d", status)
	}
}

// Block ends a pooled connection to a local address, and the next request there is refused.
func TestBlockEndsAPooledConnectionToALocalAddress(t *testing.T) {
	s, proxy := proxyOn(t)
	far, closed := pageAt(t)
	local := "http://192.168.1.50:" + port(far) + "/"
	if status, _ := rawGet(t, proxy, local); status != http.StatusOK {
		t.Fatalf("with Allow got %d", status)
	}
	if !waitFor(5*time.Second, func() bool { return s.proxyFlowsLeft() == 1 }) {
		t.Fatalf("%d kept, want the pooled connection", s.proxyFlowsLeft())
	}
	blockLocal(s, true)
	if !waitFor(5*time.Second, func() bool { return closed.Load() == 1 }) {
		t.Fatal("Block left the pooled connection to a local address open")
	}
	if status, _ := rawGet(t, proxy, local); status != http.StatusForbidden {
		t.Fatalf("with Block got %d, want 403", status)
	}
}

// Turning the proxy off ends a relay that's draining at once, not when drainGrace runs out (#287).
// On loopback a send queue empties at once, so the test's queue never does: the relay stays in
// drain until something ends it.
func TestTurningTheProxyOffEndsADrainingRelayAtOnce(t *testing.T) {
	s := proxyReady(t)
	draining := make(chan struct{})
	var once sync.Once
	s.mu.Lock()
	s.proxy.queued = func(net.Conn) int { once.Do(func() { close(draining) }); return 1 }
	s.mu.Unlock()
	s.SetProxy(true, false)
	proxy := proxyListening(t, s)
	reset := make(chan struct{})
	target := farEnd(t, func(conn *net.TCPConn) {
		<-reset
		conn.SetLinger(0) // the deferred Close sends a reset, so the relay drains toward the client
	})
	if _, _, status := tunnel(t, proxy, target); status != http.StatusOK {
		t.Fatalf("got %d", status)
	}
	close(reset)
	select {
	case <-draining:
	case <-time.After(5 * time.Second):
		t.Fatal("the relay never started draining")
	}
	start := time.Now()
	s.SetProxy(false, false)
	if took := time.Since(start); took > drainGrace/2 {
		t.Fatalf("turning the proxy off took %v", took)
	}
}

// Served lists the clients the far end answered, so Add a device can tell a new device from one
// already on the proxy (#285). A request that fails doesn't serve its client, a tunnel's first
// bytes back and a plain response do.
func TestTheProxyListsTheClientsTheFarEndAnswered(t *testing.T) {
	s, proxy := proxyOn(t)
	served := func() []string { return s.statsMessage().Proxy.Served }
	if got := served(); got == nil || len(got) != 0 {
		t.Fatalf("served %v before anything, want an empty list", got)
	}
	if _, _, status := tunnel(t, proxy, refusedPort(t)); status != http.StatusBadGateway {
		t.Fatalf("a tunnel to a closed port got %d", status)
	}
	resp, err := viaProxy(proxy).Get("http://" + refusedPort(t) + "/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if got := served(); len(got) != 0 {
		t.Fatalf("served %v after two failed requests, want none", got)
	}
	conn, r, _ := tunnel(t, proxy, echoFarEnd(t))
	defer conn.Close()
	if !echoes(conn, r) {
		t.Fatal("no echo")
	}
	if !waitFor(5*time.Second, func() bool { return slices.Equal(served(), []string{"127.0.0.1"}) }) {
		t.Fatalf("served %v after a tunnel echoed, want 127.0.0.1", served())
	}
	s.mu.Lock()
	s.proxy.served = map[netip.Addr]time.Time{}
	s.mu.Unlock()
	resp, err = viaProxy(proxy).Get("http://" + tcpPage(t, 10) + "/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if got := served(); !slices.Equal(got, []string{"127.0.0.1"}) {
		t.Fatalf("served %v after a page, want 127.0.0.1", got)
	}
}

// A client served longer than servedFor ago drops out of the list, so one that comes back counts as
// new, and past maxServed clients the one served longest ago goes (#285).
func TestTheServedClientsAgeOutAndAreCapped(t *testing.T) {
	s, _ := proxyOn(t)
	served := func() []string { return s.statsMessage().Proxy.Served }
	laptop := netip.MustParseAddr("172.20.10.5")
	s.markServed(laptop)
	if got := served(); !slices.Equal(got, []string{"172.20.10.5"}) {
		t.Fatalf("served %v, want the laptop", got)
	}
	s.mu.Lock()
	s.proxy.served[laptop] = time.Now().Add(-servedFor - time.Second)
	s.mu.Unlock()
	if got := served(); len(got) != 0 {
		t.Fatalf("served %v after the laptop was idle, want none", got)
	}
	s.markServed(laptop)
	if got := served(); !slices.Equal(got, []string{"172.20.10.5"}) {
		t.Fatalf("served %v after the laptop came back, want it", got)
	}
	s.mu.Lock()
	s.proxy.served[laptop] = time.Now().Add(-time.Minute) // the oldest
	s.mu.Unlock()
	for i := range maxServed {
		s.markServed(netip.AddrFrom16([16]byte{0x20, 0x01, 0x0d, 0xb8, 15: byte(i + 1)}))
	}
	got := served()
	if len(got) != maxServed || slices.Contains(got, "172.20.10.5") {
		t.Fatalf("%d served, laptop in it %v, want %d without the laptop", len(got), slices.Contains(got, "172.20.10.5"), maxServed)
	}
}

// A long tunnel marks its client again while bytes keep coming, so a TV streaming through one
// stays served past servedFor.
func TestATunnelKeepsMarkingItsClientServed(t *testing.T) {
	var now time.Time
	marks := 0
	r := &servedReading{Reader: strings.NewReader(strings.Repeat("x", 100)), mark: func() { marks++ }, now: func() time.Time { return now }}
	now = time.Unix(1000, 0)
	b := make([]byte, 10)
	r.Read(b)
	r.Read(b)
	now = now.Add(servedEvery)
	r.Read(b)
	if marks != 2 {
		t.Fatalf("%d marks, want one at the start and one after servedEvery", marks)
	}
}

// A plain request that upgrades, a websocket say, goes through with its body as it is, which
// ReverseProxy needs to carry the connection, and marks its client served once (#285).
func TestAnUpgradeGoesThroughAndServesItsClient(t *testing.T) {
	s, proxy := proxyOn(t)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		c, err := l.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		br := bufio.NewReader(c)
		if _, err := http.ReadRequest(br); err != nil {
			return
		}
		io.WriteString(c, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\r\n")
		io.Copy(c, br)
	}()
	far := viaRemote(l.Addr().String())
	c, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	fmt.Fprintf(c, "GET http://%s/ HTTP/1.1\r\nHost: %s\r\nConnection: Upgrade\r\nUpgrade: echo\r\n\r\n", far, far)
	r := bufio.NewReader(c)
	resp, err := http.ReadResponse(r, nil)
	if err != nil || resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("got %v, %v, want 101", resp, err)
	}
	if !echoes(c, r) {
		t.Fatal("the upgraded connection doesn't carry bytes")
	}
	if got := s.statsMessage().Proxy.Served; !slices.Equal(got, []string{"127.0.0.1"}) {
		t.Fatalf("served %v, want the client", got)
	}
}
