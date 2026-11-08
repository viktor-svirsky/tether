package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// DNS on 10.7.0.1 (#100): a device whose config names 10.7.0.1 asks Tether, and Tether asks a
// DoH server, or the plain server it stands in for.

const tetherDNS = "10.7.0.1:53"

// lookupFor is a query for name's A record, with an EDNS0 size when size isn't 0.
func lookupFor(t testing.TB, id uint16, name string, size int) []byte {
	t.Helper()
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: id, RecursionDesired: true})
	b.StartQuestions()
	b.Question(dnsmessage.Question{Name: dnsmessage.MustNewName(name), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET})
	if size != 0 {
		b.StartAdditionals()
		var h dnsmessage.ResourceHeader
		if err := h.SetEDNS0(size, dnsmessage.RCodeSuccess, false); err != nil {
			t.Fatal(err)
		}
		b.OPTResource(h, dnsmessage.OPTResource{})
	}
	m, err := b.Finish()
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// answerTo answers q with n A records, 10 bytes of RDATA header and 4 of address each.
func answerTo(t testing.TB, q []byte, n int) []byte {
	t.Helper()
	var p dnsmessage.Parser
	h, err := p.Start(q)
	if err != nil {
		t.Fatal(err)
	}
	qs, err := p.AllQuestions()
	if err != nil || len(qs) != 1 {
		t.Fatalf("questions %v %v", qs, err)
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: h.ID, Response: true, RecursionDesired: h.RecursionDesired, RecursionAvailable: true})
	b.StartQuestions()
	b.Question(qs[0])
	b.StartAnswers()
	for i := range n {
		b.AResource(dnsmessage.ResourceHeader{Name: qs[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60},
			dnsmessage.AResource{A: [4]byte{192, 0, byte(i >> 8), byte(i)}})
	}
	m, err := b.Finish()
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// read is a DNS message's ID, flags and how many answers it has.
func read(t testing.TB, m []byte) (h dnsmessage.Header, answers int) {
	t.Helper()
	var p dnsmessage.Parser
	h, err := p.Start(m)
	if err != nil {
		t.Fatal(err)
	}
	if err := p.SkipAllQuestions(); err != nil {
		t.Fatal(err)
	}
	as, err := p.AllAnswers()
	if err != nil {
		t.Fatal(err)
	}
	return h, len(as)
}

// dohServer is a DoH server on HTTP/2 that answers each lookup with records A records.
type dohServer struct {
	*httptest.Server
	asked    chan []byte  // each query as it arrived
	requests atomic.Int32 // every request, a refused one too
	records  atomic.Int32
	// While held, every answer waits for release or for its request to end.
	held     atomic.Bool
	free     chan struct{}
	freeOnce sync.Once
}

func newDoH(t *testing.T, records int) *dohServer {
	d := &dohServer{asked: make(chan []byte, 100), free: make(chan struct{})}
	d.records.Store(int32(records))
	d.Server = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		d.requests.Add(1)
		if r.Method != http.MethodPost || r.URL.Path != "/abc123" ||
			r.Header.Get("Content-Type") != "application/dns-message" || r.Header.Get("Accept") != "application/dns-message" {
			http.Error(w, "not a DoH request", http.StatusBadRequest)
			return
		}
		q, _ := io.ReadAll(r.Body)
		d.asked <- q
		if d.held.Load() {
			select {
			case <-d.free:
			case <-r.Context().Done():
				return
			}
		}
		w.Header().Set("Content-Type", "application/dns-message")
		w.Write(answerTo(t, q, int(d.records.Load())))
	}))
	d.EnableHTTP2 = true
	d.StartTLS()
	t.Cleanup(d.Close)
	return d
}

// holding makes d keep its answers back until release, or the test's end.
func (d *dohServer) holding(t *testing.T) {
	d.held.Store(true)
	t.Cleanup(d.release)
}

func (d *dohServer) release() { d.freeOnce.Do(func() { close(d.free) }) }

// waitAsked is the next query d got. It fails the test rather than waiting forever: on a busy
// runner a lookup can end before it reaches the server.
func waitAsked(t *testing.T, d *dohServer) []byte {
	t.Helper()
	select {
	case q := <-d.asked:
		return q
	case <-time.After(30 * time.Second):
		t.Fatal("the DoH server was never asked")
		return nil
	}
}

// viaDoH points s's lookups at d. Call it before the first lookup: they read dohClient without
// a lock, and one may still run after its device gave up. SetDNS changes the URL at any time.
func viaDoH(s *Server, d *dohServer) {
	s.dohClient = d.Client()
	s.SetDNS(&dnsUpstream{doh: d.URL + "/abc123"})
}

// lookupUDP sends q to 10.7.0.1 from c and returns the answer, or the read's error after wait.
func lookupUDP(c *client, q []byte, wait time.Duration) ([]byte, error) {
	conn, err := c.net.Dial("udp", tetherDNS)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(wait))
	if _, err := conn.Write(q); err != nil {
		return nil, err
	}
	buf := make([]byte, 65535)
	n, err := conn.Read(buf)
	return buf[:n], err
}

// lookupsTCP sends each query to 10.7.0.1 on one TCP connection, then reads as many answers.
func lookupsTCP(c *client, wait time.Duration, qs ...[]byte) ([][]byte, error) {
	conn, err := c.net.Dial("tcp", tetherDNS)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(wait))
	for _, q := range qs {
		if _, err := conn.Write(append(binary.BigEndian.AppendUint16(nil, uint16(len(q))), q...)); err != nil {
			return nil, err
		}
	}
	var answers [][]byte
	for range qs {
		var size [2]byte
		if _, err := io.ReadFull(conn, size[:]); err != nil {
			return answers, err
		}
		a := make([]byte, binary.BigEndian.Uint16(size[:]))
		if _, err := io.ReadFull(conn, a); err != nil {
			return answers, err
		}
		answers = append(answers, a)
	}
	return answers, nil
}

func noneAsked(t *testing.T, d *dohServer) {
	t.Helper()
	select {
	case q := <-d.asked:
		t.Fatalf("the DoH server was asked %x", q)
	default:
	}
}

func TestALookupGoesOverDoH(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	viaDoH(s, d)
	q := lookupFor(t, 0x1234, "example.com.", 0)
	a, err := lookupUDP(c, q, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	h, n := read(t, a)
	if h.ID != 0x1234 || !h.Response || h.Truncated || n != 1 {
		t.Fatalf("answer %+v with %d records", h, n)
	}
	// RFC 8484 4.1: ID 0 on the way, so a cache between can answer anyone who asks the same.
	sent := waitAsked(t, d)
	if !bytes.Equal(sent[:2], []byte{0, 0}) || !bytes.Equal(sent[2:], q[2:]) {
		t.Fatalf("the DoH server got %x for %x", sent, q)
	}
	// The DNS bytes count as the device's, the way the lookup would have, not the HTTPS around them.
	if st := s.Stats(); st.Up != uint64(len(q)) || st.Down != uint64(len(a)) {
		t.Fatalf("counted up %d down %d, want %d and %d", st.Up, st.Down, len(q), len(a))
	}
}

func TestLookupsOverTCPGoOverDoH(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 2)
	viaDoH(s, d)
	answers, err := lookupsTCP(c, 5*time.Second, lookupFor(t, 1, "one.example.", 0), lookupFor(t, 2, "two.example.", 0))
	if err != nil {
		t.Fatal(err)
	}
	for i, a := range answers {
		if h, n := read(t, a); h.ID != uint16(i+1) || n != 2 {
			t.Fatalf("answer %d: %+v with %d records", i, h, n)
		}
	}
	// The connection is gone once the device closed it, like any other.
	deadline := time.Now().Add(5 * time.Second)
	for s.tracked(deviceAddr) != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("%d flows still open", s.tracked(deviceAddr))
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// An answer bigger than the device offers to take over UDP comes back cut to its question with TC
// set, so the device asks again over TCP and gets it all.
func TestABigAnswerIsCutForUDP(t *testing.T) {
	s, c := setup(t)
	viaDoH(s, newDoH(t, 100)) // about 1.6 KB
	a, err := lookupUDP(c, lookupFor(t, 7, "big.example.", 0), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.ID != 7 || !h.Truncated || n != 0 || len(a) > 512 {
		t.Fatalf("without EDNS: %+v with %d records, %d bytes", h, n, len(a))
	}
	a, err = lookupUDP(c, lookupFor(t, 8, "big.example.", 4096), 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.Truncated || n != 100 {
		t.Fatalf("with EDNS 4096: %+v with %d records", h, n)
	}
	answers, err := lookupsTCP(c, 5*time.Second, lookupFor(t, 9, "big.example.", 0))
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, answers[0]); h.Truncated || n != 100 {
		t.Fatalf("over TCP: %+v with %d records", h, n)
	}
}

func TestAPausedDeviceGetsNoAnswer(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	viaDoH(s, d)
	pause(t, s, true)
	if _, err := lookupUDP(c, lookupFor(t, 1, "example.com.", 0), time.Second); err == nil {
		t.Fatal("a paused device got an answer over UDP")
	}
	if _, err := lookupsTCP(c, time.Second, lookupFor(t, 2, "example.com.", 0)); err == nil {
		t.Fatal("a paused device got an answer over TCP")
	}
	noneAsked(t, d)
}

// Before Swift says where lookups go, 10.7.0.1 stays inside like every tunnel address.
func TestWithoutAnUpstreamTheAddressStaysInside(t *testing.T) {
	_, c := setup(t)
	if _, err := lookupUDP(c, lookupFor(t, 1, "example.com.", 0), time.Second); err == nil {
		t.Fatal("an answer with no upstream")
	}
	if _, err := lookupsTCP(c, time.Second, lookupFor(t, 2, "example.com.", 0)); err == nil {
		t.Fatal("an answer over TCP with no upstream")
	}
}

// With a plain server, 10.7.0.1 is another name for it: the lookup goes out to the server, and the
// reply comes back from 10.7.0.1, or the device's resolver, which sent to 10.7.0.1, throws it away.
func TestTheAddressStandsInForAPlainServer(t *testing.T) {
	s, c := setup(t)
	echo := netip.MustParseAddrPort(udpEcho(t))
	s.SetDNS(&dnsUpstream{udp: []netip.AddrPort{echo}})
	q := lookupFor(t, 3, "example.com.", 0)
	a, err := lookupUDP(c, q, 5*time.Second)
	if err != nil || !bytes.Equal(a, q) {
		t.Fatalf("got %x %v, want the echo of %x", a, err, q)
	}
	// The same port asking the server by its own address gets its replies from that address.
	conn, err := c.net.Dial("udp", echo.String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	conn.Write(q)
	buf := make([]byte, 512)
	if n, err := conn.Read(buf); err != nil || !bytes.Equal(buf[:n], q) {
		t.Fatalf("asking the server directly: %x %v", buf[:n], err)
	}
}

func TestTheAddressStandsInForAPlainServerOverTCP(t *testing.T) {
	s, c := setup(t)
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
	q := lookupFor(t, 4, "example.com.", 0)
	answers, err := lookupsTCP(c, 5*time.Second, q)
	if err != nil || !bytes.Equal(answers[0], q) {
		t.Fatalf("got %x %v, want the echo of %x", answers, err, q)
	}
}

// failOnce fails its first request the way a connection that died with a network switch does.
type failOnce struct {
	http.RoundTripper
	failed atomic.Bool
}

func (f *failOnce) RoundTrip(r *http.Request) (*http.Response, error) {
	if !f.failed.Swap(true) {
		return nil, errors.New("connection reset")
	}
	return f.RoundTripper.RoundTrip(r)
}

func TestALookupIsAskedAgainOnAFailedConnection(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	viaDoH(s, d)
	s.dohClient = &http.Client{Transport: &failOnce{RoundTripper: d.Client().Transport}}
	if _, err := lookupUDP(c, lookupFor(t, 1, "example.com.", 0), 5*time.Second); err != nil {
		t.Fatal(err)
	}
}

// A DoH server that answers with an error isn't asked again: it would answer the same.
func TestAnErrorFromTheServerIsNotAskedAgain(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	viaDoH(s, d)
	s.SetDNS(&dnsUpstream{doh: d.URL + "/wrong"})
	lines := make(chan string, 100)
	heard := func(line string) {
		if strings.HasPrefix(line, "DNS") {
			select {
			case lines <- line:
			default:
			}
		}
	}
	s.heard.Store(&heard)
	// The line comes from the lookup's goroutine, which on a busy runner ends after the device
	// gave up waiting, so it's waited for.
	next := func() string {
		select {
		case line := <-lines:
			return line
		case <-time.After(30 * time.Second):
			t.Fatal("nothing logged")
			return ""
		}
	}
	if _, err := lookupUDP(c, lookupFor(t, 1, "example.com.", 0), time.Second); err == nil {
		t.Fatal("an answer from a server that refused")
	}
	// Once, and without the URL: its path is the user's Control D profile.
	if line := next(); line != "DNS over HTTPS: the server answered 400 Bad Request" {
		t.Fatalf("logged %q", line)
	}
	// The next failure of the run isn't logged, and the first answer after them is.
	lookupUDP(c, lookupFor(t, 2, "example.com.", 0), time.Second)
	s.SetDNS(&dnsUpstream{doh: d.URL + "/abc123"})
	if _, err := lookupUDP(c, lookupFor(t, 3, "example.com.", 0), 10*time.Second); err != nil {
		t.Fatal(err)
	}
	if line := next(); line != "DNS over HTTPS answers again" {
		t.Fatalf("then logged %q", line)
	}
	if n := d.requests.Load(); n != 3 {
		t.Fatalf("%d requests for 3 lookups", n)
	}
}

// An answer that comes after its device was removed doesn't reach the device given its address.
func TestAnAnswerDoesntReachTheNextDeviceAtTheAddress(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	d.holding(t)
	viaDoH(s, d)
	conn, err := c.net.Dial("udp", tetherDNS)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write(lookupFor(t, 1, "example.com.", 0))
	waitAsked(t, d)
	_, other := keyPair(t)
	if err := s.SetPeers([]Peer{{PublicKey: other, Address: deviceAddr}}); err != nil {
		t.Fatal(err)
	}
	d.release()
	deadline := time.Now().Add(10 * time.Second)
	for s.lookupsOf(deviceAddr) != 0 {
		if time.Now().After(deadline) {
			t.Fatal("the lookup never ended")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if st := s.Stats(); st.Down != 0 {
		t.Fatalf("%d bytes went to the device now at %s", st.Down, deviceAddr)
	}
}

// lookupsOf is how many DoH lookups of the device's are waiting.
func (s *Server) lookupsOf(addr netip.Addr) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lookups[addr]
}

// A lookup the server sits on ends at the timeout and frees its place under the cap.
func TestASlowServerFreesTheLookup(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	d.holding(t)
	viaDoH(s, d)
	s.dohTimeout = 300 * time.Millisecond
	// The timeout's log line says the lookup started and ran out, whether on the held answer or,
	// on a busy runner, on the TLS handshake before it.
	failed := make(chan string, 10)
	heard := func(line string) {
		if strings.HasPrefix(line, "DNS over HTTPS:") {
			select {
			case failed <- line:
			default:
			}
		}
	}
	s.heard.Store(&heard)
	conn, err := c.net.Dial("udp", tetherDNS)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write(lookupFor(t, 1, "example.com.", 0))
	select {
	case <-failed:
	case <-time.After(30 * time.Second):
		t.Fatal("the lookup never ran out of time")
	}
	deadline := time.Now().Add(10 * time.Second)
	for s.lookupsOf(deviceAddr) != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("%d lookups still waiting", s.lookupsOf(deviceAddr))
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestLookupsStopAtTheCap(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	d.holding(t)
	viaDoH(s, d)
	s.maxLookups = 1
	for i := range 2 {
		conn, err := c.net.Dial("udp", tetherDNS)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		conn.Write(lookupFor(t, uint16(i), "example.com.", 0))
	}
	waitAsked(t, d)
	time.Sleep(300 * time.Millisecond)
	noneAsked(t, d)
	if n := s.lookupsOf(deviceAddr); n != 1 {
		t.Fatalf("%d lookups waiting, want 1", n)
	}
}

func TestCloseDuringALookupReturns(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	d.holding(t)
	viaDoH(s, d)
	conn, err := c.net.Dial("udp", tetherDNS)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write(lookupFor(t, 1, "example.com.", 0))
	tcp, err := c.net.DialContext(context.Background(), "tcp", tetherDNS)
	if err != nil {
		t.Fatal(err)
	}
	defer tcp.Close()
	q := lookupFor(t, 2, "example.com.", 0)
	tcp.Write(append(binary.BigEndian.AppendUint16(nil, uint16(len(q))), q...))
	waitAsked(t, d)
	waitAsked(t, d)
	done := make(chan struct{})
	go func() { s.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Close waited for the DoH server")
	}
}

func TestUDPSizeAndCutting(t *testing.T) {
	for _, c := range []struct {
		size, want int
	}{{0, 512}, {256, 512}, {1232, 1232}, {4096, 4096}} {
		if got := udpSize(lookupFor(t, 1, "example.com.", c.size)); got != c.want {
			t.Errorf("EDNS %d: %d, want %d", c.size, got, c.want)
		}
	}
	if got := udpSize([]byte{1, 2, 3}); got != 512 {
		t.Errorf("not a message: %d", got)
	}
	q := lookupFor(t, 5, "example.com.", 0)
	small := answerTo(t, q, 1)
	if got := fitUDP(q, small); !bytes.Equal(got, small) {
		t.Fatalf("a small answer changed: %x", got)
	}
	cut := fitUDP(q, answerTo(t, q, 100))
	if h, n := read(t, cut); h.ID != 5 || !h.Truncated || !h.Response || n != 0 {
		t.Fatalf("cut: %+v with %d records", h, n)
	}
	if got := fitUDP(q, bytes.Repeat([]byte{0xff}, 600)); got != nil {
		t.Fatalf("a big answer that isn't one: %x", got)
	}
}

func FuzzFitUDP(f *testing.F) {
	q := lookupFor(f, 1, "example.com.", 0)
	f.Add(q, answerTo(f, q, 100))
	f.Add([]byte{}, bytes.Repeat([]byte{0}, 600))
	f.Fuzz(func(t *testing.T, query, answer []byte) {
		got := fitUDP(query, answer)
		if got != nil && len(got) > max(len(answer), 512) {
			t.Fatalf("%d bytes from a %d byte answer", len(got), len(answer))
		}
	})
}

func TestTheDNSInTheDeviceList(t *testing.T) {
	parse := func(dns string) (*dnsUpstream, error) {
		_, u, err := parseConfig(`{"v":1,"peers":[]` + dns + `}`)
		return u, err
	}
	if u, err := parse(""); u != nil || err != nil {
		t.Fatalf("a list from before #100: %+v %v", u, err)
	}
	if u, err := parse(`,"dns":{"doh":"https://dns.controld.com/abc123"}`); err != nil || u.doh != "https://dns.controld.com/abc123" || u.udp != nil {
		t.Fatalf("DoH: %+v %v", u, err)
	}
	u, err := parse(`,"dns":{"udp":["1.1.1.1","1.0.0.1"]}`)
	if err != nil || u.doh != "" || len(u.udp) != 2 || u.udp[0] != netip.MustParseAddrPort("1.1.1.1:53") || u.udp[1] != netip.MustParseAddrPort("1.0.0.1:53") {
		t.Fatalf("plain: %+v %v", u, err)
	}
	for _, bad := range []string{
		`,"dns":{}`,
		`,"dns":{"doh":"http://dns.controld.com/abc123"}`,
		`,"dns":{"doh":"dns.controld.com/abc123"}`,
		`,"dns":{"doh":"https://me@dns.controld.com/abc123"}`,
		`,"dns":{"doh":"https://dns.controld.com/abc123","udp":["1.1.1.1"]}`,
		`,"dns":{"udp":["1.1.1.1","1.0.0.1","8.8.8.8"]}`,
		`,"dns":{"udp":["2606:4700::1111"]}`,
		`,"dns":{"udp":["10.7.0.1"]}`,
		`,"dns":{"udp":["nonsense"]}`,
	} {
		_, err := parse(bad)
		if err == nil {
			t.Errorf("%s was taken", bad)
		} else if strings.Contains(err.Error(), "controld") {
			t.Errorf("the error names the profile: %v", err)
		}
	}
}
