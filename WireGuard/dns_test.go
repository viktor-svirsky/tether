package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// DNS on 10.7.0.1 (#100, #121): a device whose config names 10.7.0.1 asks Tether, and Tether asks a
// DoH server or plain servers and answers the device itself.

const tetherDNS = "10.7.0.1:53"

// answerWait is how long a test waits for an answer it expects, long enough for a slow CI runner
// under -race. A test that expects none waits a second.
const answerWait = 30 * time.Second

// scaled is a timeout or delay a test shortened, longer under -race, which slows a CI runner
// several times over. Tests set the server's DNS timeouts and the fake servers' delays with it, so
// their order holds however slow the runner is.
func scaled(d time.Duration) time.Duration {
	if raceEnabled {
		return 5 * d
	}
	return d
}

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
	// delay holds each answer back this long, for a slow but working server.
	delay atomic.Int64
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
		if delay := time.Duration(d.delay.Load()); delay > 0 {
			select {
			case <-time.After(delay):
			case <-r.Context().Done():
				return
			}
		}
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
	// Its own transport, so its own connection, like the server's.
	s.dohSpare = &http.Client{Transport: d.Client().Transport.(*http.Transport).Clone()}
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

// plainServer is a plain DNS server on loopback, over UDP and TCP on one port, which the server
// reaches at remote (see viaLoopback). It answers each lookup with records A records.
type plainServer struct {
	addr     netip.AddrPort // remote and the port: where Tether is told to ask
	asked    chan string    // "udp" or "tcp" for each query, as it arrived
	records  int
	silent   atomic.Bool // takes the queries and never answers
	truncate atomic.Bool // answers over UDP with TC set and no records, so the device asks over TCP
	wrongID  atomic.Bool // answers over UDP with another ID
	wrongQ   atomic.Bool // answers over UDP with the query's ID and another question
	upper    atomic.Bool // answers with the question's name in capitals, over UDP and TCP
	delay    atomic.Int64
	tcp      net.Listener
}

func newPlain(t *testing.T, records int) *plainServer {
	p := &plainServer{asked: make(chan string, 100), records: records}
	var udp net.PacketConn
	var tcp net.Listener
	// The same port for both. Something else can hold it for TCP, so a few ports are tried.
	for range 20 {
		u, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		if l, err := net.Listen("tcp4", u.LocalAddr().String()); err == nil {
			udp, tcp = u, l
			break
		}
		u.Close()
	}
	if udp == nil {
		t.Fatal("no port free for both UDP and TCP")
	}
	p.tcp = tcp
	t.Cleanup(func() { udp.Close(); tcp.Close() })
	p.addr = netip.MustParseAddrPort(viaRemote(udp.LocalAddr().String()))
	go func() {
		buf := make([]byte, 65535)
		for {
			n, from, err := udp.ReadFrom(buf)
			if err != nil {
				return
			}
			p.note("udp")
			if p.silent.Load() {
				continue
			}
			a := answerTo(t, buf[:n], p.records)
			if p.truncate.Load() {
				a = answerTo(t, buf[:n], 0)
				a[2] |= 0x02 // TC
			}
			if p.wrongID.Load() {
				a[0]++
			}
			if p.upper.Load() {
				upperName(a)
			}
			if p.wrongQ.Load() {
				a = answerTo(t, lookupFor(t, binary.BigEndian.Uint16(buf), "other.example.", 0), p.records)
			}
			time.AfterFunc(time.Duration(p.delay.Load()), func() { udp.WriteTo(a, from) })
		}
	}()
	go func() {
		for {
			conn, err := tcp.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				for {
					var size [2]byte
					if _, err := io.ReadFull(conn, size[:]); err != nil {
						return
					}
					q := make([]byte, binary.BigEndian.Uint16(size[:]))
					if _, err := io.ReadFull(conn, q); err != nil {
						return
					}
					p.note("tcp")
					if p.silent.Load() {
						continue
					}
					a := answerTo(t, q, p.records)
					if p.upper.Load() {
						upperName(a)
					}
					conn.Write(append(binary.BigEndian.AppendUint16(nil, uint16(len(a))), a...))
				}
			}()
		}
	}()
	return p
}

// upperName puts the first question's name in m in capitals, as a server that changes its case does.
// A label's length byte is under 64, so only the letters change.
func upperName(m []byte) {
	for i := dnsHeaderLen; i < len(m) && m[i] != 0; i++ {
		if 'a' <= m[i] && m[i] <= 'z' {
			m[i] -= 'a' - 'A'
		}
	}
}

func (p *plainServer) note(proto string) {
	select {
	case p.asked <- proto:
	default:
	}
}

// waitAsked is how the next query reached p: "udp" or "tcp". It fails the test after a while.
func (p *plainServer) waitAsked(t *testing.T) string {
	t.Helper()
	select {
	case proto := <-p.asked:
		return proto
	case <-time.After(30 * time.Second):
		t.Fatalf("%v was never asked", p.addr)
		return ""
	}
}

// askedOver checks the next queries reached p over these, in order.
func (p *plainServer) askedOver(t *testing.T, protos ...string) {
	t.Helper()
	for _, want := range protos {
		if got := p.waitAsked(t); got != want {
			t.Fatalf("%v was asked over %s, want %s", p.addr, got, want)
		}
	}
}

func (p *plainServer) noneAsked(t *testing.T) {
	t.Helper()
	select {
	case proto := <-p.asked:
		t.Fatalf("%v was asked over %s", p.addr, proto)
	default:
	}
}

// viaPlain points s's lookups at the plain servers, the first one first.
func viaPlain(s *Server, servers ...*plainServer) {
	var u dnsUpstream
	for _, p := range servers {
		u.udp = append(u.udp, p.addr)
	}
	s.SetDNS(&u)
}

// serverFailure checks a is SERVFAIL for q: q's ID and question, QR set and RCODE 2.
func serverFailure(t *testing.T, q, a []byte) {
	t.Helper()
	var p dnsmessage.Parser
	h, err := p.Start(a)
	if err != nil {
		t.Fatal(err)
	}
	if h.ID != binary.BigEndian.Uint16(q) || !h.Response || h.RCode != dnsmessage.RCodeServerFailure {
		t.Fatalf("got %+v, want SERVFAIL for ID %x", h, q[:2])
	}
	got, err := p.AllQuestions()
	var pq dnsmessage.Parser
	pq.Start(q)
	want, _ := pq.AllQuestions()
	if err != nil || len(want) == 0 || !slices.Equal(got, want) {
		t.Fatalf("questions %v %v, want %v", got, err, want)
	}
}

func TestALookupGoesOverDoH(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	viaDoH(s, d)
	q := lookupFor(t, 0x1234, "example.com.", 0)
	a, err := lookupUDP(c, q, answerWait)
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
	answers, err := lookupsTCP(c, answerWait, lookupFor(t, 1, "one.example.", 0), lookupFor(t, 2, "two.example.", 0))
	if err != nil {
		t.Fatal(err)
	}
	for i, a := range answers {
		if h, n := read(t, a); h.ID != uint16(i+1) || n != 2 {
			t.Fatalf("answer %d: %+v with %d records", i, h, n)
		}
	}
	// The connection is gone once the device closed it, like any other.
	deadline := time.Now().Add(answerWait)
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
	a, err := lookupUDP(c, lookupFor(t, 7, "big.example.", 0), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.ID != 7 || !h.Truncated || n != 0 || len(a) > 512 {
		t.Fatalf("without EDNS: %+v with %d records, %d bytes", h, n, len(a))
	}
	a, err = lookupUDP(c, lookupFor(t, 8, "big.example.", 4096), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.Truncated || n != 100 {
		t.Fatalf("with EDNS 4096: %+v with %d records", h, n)
	}
	answers, err := lookupsTCP(c, answerWait, lookupFor(t, 9, "big.example.", 0))
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, answers[0]); h.Truncated || n != 100 {
		t.Fatalf("over TCP: %+v with %d records", h, n)
	}
}

// A paused device gets nothing, not even SERVFAIL, and no server is asked for it.
func TestAPausedDeviceGetsNoAnswer(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	p := newPlain(t, 1)
	viaDoH(s, d)
	pause(t, s, true)
	for _, upstream := range []*dnsUpstream{{doh: d.URL + "/abc123"}, {udp: []netip.AddrPort{p.addr}}} {
		s.SetDNS(upstream)
		if _, err := lookupUDP(c, lookupFor(t, 1, "example.com.", 0), time.Second); err == nil {
			t.Fatalf("a paused device got an answer over UDP from %+v", upstream)
		}
		if _, err := lookupsTCP(c, time.Second, lookupFor(t, 2, "example.com.", 0)); err == nil {
			t.Fatalf("a paused device got an answer over TCP from %+v", upstream)
		}
	}
	noneAsked(t, d)
	p.noneAsked(t)
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

// Tether asks the first server, and the second only when the first doesn't answer. With Other set to
// a Pi-hole and a public server, the public one must not get half the lookups (#123).
func TestTheSecondServerIsABackup(t *testing.T) {
	s, c := setup(t)
	first, second := newPlain(t, 1), newPlain(t, 2)
	viaPlain(s, first, second)
	for i := range 3 {
		id := uint16(10 + i)
		a, err := lookupUDP(c, lookupFor(t, id, "example.com.", 0), answerWait)
		if err != nil {
			t.Fatal(err)
		}
		if h, n := read(t, a); h.ID != id || !h.Response || n != 1 {
			t.Fatalf("lookup %d: %+v with %d records, want the first server's 1", i, h, n)
		}
	}
	answers, err := lookupsTCP(c, answerWait, lookupFor(t, 13, "example.com.", 0))
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, answers[0]); h.ID != 13 || n != 1 {
		t.Fatalf("over TCP: %+v with %d records", h, n)
	}
	first.askedOver(t, "udp", "udp", "udp", "tcp")
	second.noneAsked(t)
}

// A first server that doesn't answer leaves the lookup to the second after plainTimeout, over UDP
// and TCP. An answer from the second at all says it came inside the budget: after it, the device
// gets SERVFAIL.
func TestASilentFirstServerLeavesItToTheSecond(t *testing.T) {
	s, c := setup(t)
	s.plainTimeout, s.lookupTimeout = scaled(500*time.Millisecond), time.Minute
	first, second := newPlain(t, 1), newPlain(t, 2)
	first.silent.Store(true)
	viaPlain(s, first, second)
	start := time.Now()
	a, err := lookupUDP(c, lookupFor(t, 21, "example.com.", 0), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if took := time.Since(start); took < s.plainTimeout {
		t.Fatalf("answered after %v: the second server was asked before the first's %v ran out", took, s.plainTimeout)
	}
	if h, n := read(t, a); h.ID != 21 || n != 2 {
		t.Fatalf("%+v with %d records, want the second server's 2", h, n)
	}
	answers, err := lookupsTCP(c, answerWait, lookupFor(t, 22, "example.com.", 0))
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, answers[0]); h.ID != 22 || n != 2 {
		t.Fatalf("over TCP: %+v with %d records, want the second server's 2", h, n)
	}
	first.askedOver(t, "udp", "tcp")
	second.askedOver(t, "udp", "tcp")
}

// An answer the first server gives after the second was asked is still taken.
func TestALateAnswerFromTheFirstServerCounts(t *testing.T) {
	s, c := setup(t)
	s.plainTimeout, s.lookupTimeout = scaled(500*time.Millisecond), time.Minute
	first, second := newPlain(t, 1), newPlain(t, 2)
	first.delay.Store(int64(2 * s.plainTimeout)) // the second is asked halfway
	second.silent.Store(true)
	viaPlain(s, first, second)
	a, err := lookupUDP(c, lookupFor(t, 61, "example.com.", 0), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.ID != 61 || n != 1 {
		t.Fatalf("%+v with %d records, want the first server's 1", h, n)
	}
	first.askedOver(t, "udp")
	second.askedOver(t, "udp")
}

// An answer with another ID isn't taken: the server counts as silent, and the second is asked.
func TestAnAnswerWithAnotherIDIsIgnored(t *testing.T) {
	s, c := setup(t)
	s.plainTimeout, s.lookupTimeout = scaled(300*time.Millisecond), time.Minute
	first, second := newPlain(t, 1), newPlain(t, 2)
	first.wrongID.Store(true)
	viaPlain(s, first, second)
	a, err := lookupUDP(c, lookupFor(t, 62, "example.com.", 0), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.ID != 62 || n != 2 {
		t.Fatalf("%+v with %d records, want the second server's 2", h, n)
	}
}

// A first server that refuses the connection is a failure at once: the second is asked without
// waiting plainTimeout.
func TestARefusedFirstServerAsksTheSecondAtOnce(t *testing.T) {
	s, c := setup(t)
	s.plainTimeout, s.lookupTimeout = time.Hour, time.Hour
	first, second := newPlain(t, 1), newPlain(t, 2)
	first.tcp.Close()
	viaPlain(s, first, second)
	// lookupsTCP gives up long before plainTimeout.
	answers, err := lookupsTCP(c, answerWait, lookupFor(t, 63, "example.com.", 0))
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, answers[0]); h.ID != 63 || n != 2 {
		t.Fatalf("%+v with %d records, want the second server's 2", h, n)
	}
	second.askedOver(t, "tcp")
}

// A plain server's answer bigger than the device takes over UDP is cut for it, TC set.
func TestABigAnswerFromAPlainServerIsCut(t *testing.T) {
	s, c := setup(t)
	viaPlain(s, newPlain(t, 50)) // about 800 bytes
	a, err := lookupUDP(c, lookupFor(t, 64, "big.example.", 0), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.ID != 64 || !h.Truncated || n != 0 || len(a) > 512 {
		t.Fatalf("%+v with %d records, %d bytes", h, n, len(a))
	}
}

// An answer with the query's ID and another question isn't taken either.
func TestAnAnswerToAnotherQuestionIsIgnored(t *testing.T) {
	s, c := setup(t)
	s.plainTimeout, s.lookupTimeout = scaled(300*time.Millisecond), time.Minute
	first, second := newPlain(t, 1), newPlain(t, 2)
	first.wrongQ.Store(true)
	viaPlain(s, first, second)
	a, err := lookupUDP(c, lookupFor(t, 65, "example.com.", 0), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.ID != 65 || n != 2 {
		t.Fatalf("%+v with %d records, want the second server's 2", h, n)
	}
}

// A name's case doesn't matter (RFC 4343): an answer whose question is example.com. in capitals, as
// from a server that changes the case, is taken, over UDP and TCP.
func TestAnAnswerInOtherCaseCounts(t *testing.T) {
	s, c := setup(t)
	s.plainTimeout, s.lookupTimeout = time.Hour, time.Hour // the backup would be asked only after an hour
	first, second := newPlain(t, 1), newPlain(t, 2)
	first.upper.Store(true)
	viaPlain(s, first, second)
	a, err := lookupUDP(c, lookupFor(t, 69, "example.com.", 0), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.ID != 69 || n != 1 {
		t.Fatalf("over UDP: %+v with %d records, want the first server's 1", h, n)
	}
	answers, err := lookupsTCP(c, answerWait, lookupFor(t, 70, "Example.com.", 0))
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, answers[0]); h.ID != 70 || n != 1 {
		t.Fatalf("over TCP: %+v with %d records, want the first server's 1", h, n)
	}
	second.noneAsked(t)
}

func TestQuestionsMatchWhateverTheCase(t *testing.T) {
	q := lookupFor(t, 1, "example.com.", 0)
	a := answerTo(t, q, 1)
	upperName(a)
	if !answers(q, a) {
		t.Fatal("an answer in capitals wasn't taken")
	}
	aaaa := bytes.Clone(answerTo(t, q, 0))
	// The question's type is the 2 bytes after its name: 12 + 13 bytes of example.com.
	aaaa[dnsHeaderLen+13+1] = byte(dnsmessage.TypeAAAA)
	if answers(q, aaaa) {
		t.Fatal("an answer for another type was taken")
	}
}

// A travel router whose clients only look names up through 10.7.0.1 carries their flows, so it keeps
// its role while it's online, as one carrying their connections does.
func TestARouterCarryingOnlyLookupsKeepsItsRole(t *testing.T) {
	sPriv, sPub := keyPair(t)
	aPriv, aPub := keyPair(t)
	bPriv, bPub := keyPair(t)
	s, err := Start([]netip.Addr{loopback}, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	viaPlain(s, newPlain(t, 1))
	a, b := netip.MustParseAddr("10.7.0.2"), netip.MustParseAddr("10.7.0.3")
	if err := s.SetPeers([]Peer{{PublicKey: aPub, Address: a}, {PublicKey: bPub, Address: b}}); err != nil {
		t.Fatal(err)
	}
	ca := newClient(t, s, sPub, aPriv, netip.MustParseAddr("192.168.4.20"))
	cb := newClient(t, s, sPub, bPriv, netip.MustParseAddr("192.168.8.30"))
	// The first lookup shows a sends for others and is dropped. A client's resolver asks again once
	// a has the role.
	lookupUDP(ca, lookupFor(t, 1, "example.com.", 0), 100*time.Millisecond)
	deadline := time.Now().Add(answerWait)
	for s.routerOf() != a {
		if time.Now().After(deadline) {
			t.Fatalf("router %v, want %v", s.routerOf(), a)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, err := lookupUDP(ca, lookupFor(t, 2, "example.com.", 0), answerWait); err != nil {
		t.Fatal(err)
	}
	s.readHandshakes()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := cb.net.DialContext(ctx, "tcp", tcpServer(t, 10)); err == nil {
		t.Fatal("another device sent for others while the router was online")
	}
	if s.routerOf() != a {
		t.Fatalf("router %v, want it to stay %v", s.routerOf(), a)
	}
}

// One server alone has the whole lookupTimeout, not only plainTimeout: a cold cache can take
// seconds, and the device's own resolver would have waited for it.
func TestASlowOnlyServerStillAnswers(t *testing.T) {
	s, c := setup(t)
	s.plainTimeout, s.lookupTimeout = scaled(200*time.Millisecond), scaled(2*time.Second)
	p := newPlain(t, 1)
	p.delay.Store(int64(3 * s.plainTimeout))
	viaPlain(s, p)
	a, err := lookupUDP(c, lookupFor(t, 66, "example.com.", 0), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.ID != 66 || h.RCode != dnsmessage.RCodeSuccess || n != 1 {
		t.Fatalf("%+v with %d records, want the server's 1", h, n)
	}
}

// Looking up the carrier's NAT64 prefix isn't the server's time: a slow one doesn't send the
// lookup to the backup (#123), over UDP or TCP.
func TestASlowNAT64PrefixDoesntAskTheBackup(t *testing.T) {
	s, c := setup(t)
	withoutIPv4(s)
	s.plainTimeout, s.lookupTimeout = scaled(300*time.Millisecond), scaled(600*time.Millisecond)
	// Longer than the whole lookup. It ignores its context, which ends at nat64LookupTimeout, and
	// prefix takes what it returns.
	hold := 3 * s.plainTimeout
	s.nat64.lookup = func(context.Context) (netip.Prefix, error) {
		time.Sleep(hold)
		return carrierNAT64, nil
	}
	first, second := newPlain(t, 1), newPlain(t, 2)
	viaPlain(s, first, second)
	a, err := lookupUDP(c, lookupFor(t, 67, "example.com.", 0), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.ID != 67 || n != 1 {
		t.Fatalf("over UDP: %+v with %d records, want the first server's 1", h, n)
	}
	s.nat64.mu.Lock()
	s.nat64.expiry = time.Time{} // looked up again by the next lookup
	s.nat64.mu.Unlock()
	answers, err := lookupsTCP(c, answerWait, lookupFor(t, 68, "example.com.", 0))
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, answers[0]); h.ID != 68 || n != 1 {
		t.Fatalf("over TCP: %+v with %d records, want the first server's 1", h, n)
	}
	first.askedOver(t, "udp", "tcp")
	time.Sleep(2 * s.plainTimeout)
	second.noneAsked(t)
}

// A query whose questions can't be read gets FORMERR at once: no server is asked, and its place
// under the cap is free again.
func TestAQueryThatCantBeReadIsAFormatError(t *testing.T) {
	s, c := setup(t)
	s.maxLookups = 1
	p := newPlain(t, 1)
	p.silent.Store(true)
	viaPlain(s, p)
	bad := lookupFor(t, 0x7070, "example.com.", 0)[:dnsHeaderLen] // QDCOUNT 1 and no question
	a, err := lookupUDP(c, bad, answerWait)
	if err != nil {
		t.Fatal(err)
	}
	var parser dnsmessage.Parser
	if h, err := parser.Start(a); err != nil || h.ID != 0x7070 || !h.Response || h.RCode != dnsmessage.RCodeFormatError {
		t.Fatalf("got %+v %v, want FORMERR", h, err)
	}
	answers, err := lookupsTCP(c, answerWait, bad)
	if err != nil {
		t.Fatal(err)
	}
	if h, _ := parser.Start(answers[0]); h.RCode != dnsmessage.RCodeFormatError {
		t.Fatalf("over TCP: %+v", h)
	}
	p.noneAsked(t)
	// Freed right after the answer, long before the 5 s a lookup may wait.
	deadline := time.Now().Add(scaled(time.Second))
	for s.lookupsOf(deviceAddr) != 0 {
		if time.Now().After(deadline) {
			t.Fatalf("%d lookups still waiting", s.lookupsOf(deviceAddr))
		}
		time.Sleep(10 * time.Millisecond)
	}
	// Under 12 bytes isn't a DNS message: nothing to answer.
	if _, err := lookupUDP(c, []byte{1, 2, 3}, 500*time.Millisecond); err == nil {
		t.Fatal("an answer to 3 bytes")
	}
}

// Queries written one after another on one connection are answered in order.
func TestLookupsOneAfterAnotherOverTCPToAPlainServer(t *testing.T) {
	s, c := setup(t)
	p := newPlain(t, 1)
	viaPlain(s, p)
	answers, err := lookupsTCP(c, answerWait, lookupFor(t, 71, "a.example.", 0), lookupFor(t, 72, "b.example.", 0), lookupFor(t, 73, "c.example.", 0))
	if err != nil {
		t.Fatal(err)
	}
	for i, a := range answers {
		if h, n := read(t, a); h.ID != uint16(71+i) || n != 1 {
			t.Fatalf("answer %d: %+v with %d records", i, h, n)
		}
	}
	p.askedOver(t, "tcp", "tcp", "tcp")
}

// An empty frame on a TCP connection isn't a query: the connection closes and no server is asked.
func TestAnEmptyTCPFrameClosesTheConnection(t *testing.T) {
	s, c := setup(t)
	p := newPlain(t, 1)
	viaPlain(s, p)
	conn, err := c.net.Dial("tcp", tetherDNS)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(answerWait))
	conn.Write([]byte{0, 0})
	if n, err := conn.Read(make([]byte, 10)); err != io.EOF {
		t.Fatalf("read %d bytes, %v, want the connection closed", n, err)
	}
	p.noneAsked(t)
}

// When no server answers, the device hears SERVFAIL for its query instead of waiting out its own
// timeouts.
func TestNoAnswerIsAServerFailure(t *testing.T) {
	s, c := setup(t)
	// Both servers are asked inside the budget with time to spare, so each sees the query.
	s.plainTimeout, s.lookupTimeout = scaled(200*time.Millisecond), scaled(time.Second)
	first, second := newPlain(t, 1), newPlain(t, 2)
	first.silent.Store(true)
	second.silent.Store(true)
	viaPlain(s, first, second)
	q := lookupFor(t, 0x4242, "example.com.", 0)
	a, err := lookupUDP(c, q, answerWait)
	if err != nil {
		t.Fatal(err)
	}
	serverFailure(t, q, a)
	answers, err := lookupsTCP(c, answerWait, q)
	if err != nil {
		t.Fatal(err)
	}
	serverFailure(t, q, answers[0])
	first.askedOver(t, "udp", "tcp")
	second.askedOver(t, "udp", "tcp")
}

// A DoH server that can't be reached gives SERVFAIL too, once its second try failed.
func TestAnUnreachableDoHServerIsAServerFailure(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	viaDoH(s, d)
	d.Close()
	q := lookupFor(t, 0x5151, "example.com.", 0)
	a, err := lookupUDP(c, q, answerWait)
	if err != nil {
		t.Fatal(err)
	}
	serverFailure(t, q, a)
	answers, err := lookupsTCP(c, answerWait, q)
	if err != nil {
		t.Fatal(err)
	}
	serverFailure(t, q, answers[0])
}

// Each lookup on a TCP connection goes where lookups go at that moment, not where they went when
// the connection opened.
func TestEachLookupOverTCPTakesTheCurrentSetting(t *testing.T) {
	s, c := setup(t)
	one, two := newPlain(t, 1), newPlain(t, 2)
	d := newDoH(t, 3)
	s.dohClient = d.Client()
	viaPlain(s, one)
	conn, err := c.net.Dial("tcp", tetherDNS)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(30 * time.Second))
	for i, set := range []func(){
		func() {},
		func() { viaPlain(s, two) },
		func() { s.SetDNS(&dnsUpstream{doh: d.URL + "/abc123"}) },
	} {
		set()
		id := uint16(30 + i)
		q := lookupFor(t, id, "example.com.", 0)
		if _, err := conn.Write(append(binary.BigEndian.AppendUint16(nil, uint16(len(q))), q...)); err != nil {
			t.Fatal(err)
		}
		var size [2]byte
		if _, err := io.ReadFull(conn, size[:]); err != nil {
			t.Fatalf("lookup %d: %v", i, err)
		}
		a := make([]byte, binary.BigEndian.Uint16(size[:]))
		if _, err := io.ReadFull(conn, a); err != nil {
			t.Fatalf("lookup %d: %v", i, err)
		}
		if h, n := read(t, a); h.ID != id || n != i+1 {
			t.Fatalf("lookup %d: %+v with %d records, want %d", i, h, n, i+1)
		}
	}
	one.askedOver(t, "tcp")
	two.askedOver(t, "tcp")
	waitAsked(t, d)
}

// A plain server's answer cut for UDP reaches the device as it is, TC set, so the device asks again
// over TCP, and Tether asks the server over TCP.
func TestACutAnswerFromAPlainServerSendsTheDeviceToTCP(t *testing.T) {
	s, c := setup(t)
	p := newPlain(t, 50)
	p.truncate.Store(true)
	viaPlain(s, p)
	a, err := lookupUDP(c, lookupFor(t, 41, "big.example.", 0), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.ID != 41 || !h.Truncated || n != 0 {
		t.Fatalf("over UDP: %+v with %d records", h, n)
	}
	answers, err := lookupsTCP(c, answerWait, lookupFor(t, 42, "big.example.", 0))
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, answers[0]); h.ID != 42 || h.Truncated || n != 50 {
		t.Fatalf("over TCP: %+v with %d records", h, n)
	}
	p.askedOver(t, "udp", "tcp")
}

// On an iPhone without an IPv4 route, Tether reaches a plain server through the carrier's NAT64,
// the way a device's own traffic does, over UDP and TCP.
func TestAPlainServerIsReachedThroughTheCarriersNAT64(t *testing.T) {
	s, c := setup(t)
	dialed := withoutIPv4(s)
	p := newPlain(t, 1)
	viaPlain(s, p)
	a, err := lookupUDP(c, lookupFor(t, 51, "example.com.", 0), answerWait)
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, a); h.ID != 51 || n != 1 {
		t.Fatalf("over UDP: %+v with %d records", h, n)
	}
	answers, err := lookupsTCP(c, answerWait, lookupFor(t, 52, "example.com.", 0))
	if err != nil {
		t.Fatal(err)
	}
	if h, n := read(t, answers[0]); h.ID != 52 || n != 1 {
		t.Fatalf("over TCP: %+v with %d records", h, n)
	}
	p.askedOver(t, "udp", "tcp")
	if d := dialed(); len(d) != 2 || netip.MustParseAddrPort(d[1]).Addr() != remoteVia {
		t.Fatalf("dialed %v, want the server and then its NAT64 address", d)
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
	if _, err := lookupUDP(c, lookupFor(t, 1, "example.com.", 0), answerWait); err != nil {
		t.Fatal(err)
	}
}

// silentConn is a connection whose writes vanish once it's dead, the way one does when the path
// under it goes away without a reset: nothing fails, the request only hangs.
type silentConn struct {
	net.Conn
	dead, closed atomic.Bool
}

func (c *silentConn) Close() error {
	c.closed.Store(true)
	return c.Conn.Close()
}

func (c *silentConn) Write(b []byte) (int, error) {
	if c.dead.Load() {
		return len(b), nil
	}
	return c.Conn.Write(b)
}

// A connection that goes quiet doesn't take the whole lookup: the first try gives up early, and the
// lookup is answered on a new connection (#148).
func TestALookupOnADeadConnectionIsAnsweredOnANewOne(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	viaDoH(s, d)
	tr := d.Client().Transport.(*http.Transport).Clone()
	tr.ForceAttemptHTTP2 = true
	var mu sync.Mutex
	var conns []*silentConn
	tr.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		conn, err := (&net.Dialer{}).DialContext(ctx, network, address)
		if err != nil {
			return nil, err
		}
		sc := &silentConn{Conn: conn}
		mu.Lock()
		conns = append(conns, sc)
		mu.Unlock()
		return sc, nil
	}
	s.dohClient, s.dohSpare = &http.Client{Transport: tr}, &http.Client{Transport: tr.Clone()}
	s.lookupTimeout = scaled(2 * time.Second)
	if _, err := lookupUDP(c, lookupFor(t, 1, "example.com.", 0), answerWait); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	conns[0].dead.Store(true)
	mu.Unlock()
	answer, err := lookupUDP(c, lookupFor(t, 2, "example.org.", 0), answerWait)
	if err != nil {
		t.Fatal("the lookup after the connection died got no answer:", err)
	}
	if rcode := answer[3] & 0x0f; rcode != 0 {
		t.Fatalf("the lookup after the connection died got rcode %d", rcode)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(conns) != 2 {
		t.Fatalf("%d connections, want a second one for the dead first", len(conns))
	}
}

// A slow but working server answers every lookup: a slow request isn't cut off, and the
// connection it shares with other lookups stays open (#148).
func TestASlowServerAnswersEveryLookup(t *testing.T) {
	s, c := setup(t)
	d := newDoH(t, 1)
	viaDoH(s, d)
	s.lookupTimeout = scaled(2 * time.Second)
	// Past the 2/5 a first try had before it was cut off, so cutting it off would fail them.
	d.delay.Store(int64(s.lookupTimeout * 7 / 10))
	var wg sync.WaitGroup
	failed := make(chan string, 6)
	for i := range 6 {
		wg.Go(func() {
			time.Sleep(time.Duration(i) * scaled(100*time.Millisecond)) // staggered, like a page's lookups
			answer, err := lookupUDP(c, lookupFor(t, uint16(i+1), fmt.Sprintf("host%d.example.com.", i), 0), answerWait)
			if err != nil {
				failed <- err.Error()
			} else if rcode := answer[3] & 0x0f; rcode != 0 {
				failed <- fmt.Sprintf("lookup %d got rcode %d", i, rcode)
			}
		})
	}
	wg.Wait()
	close(failed)
	for f := range failed {
		t.Error(f)
	}
}

// A connection that goes quiet is pinged, and closed when the ping goes unanswered, so later
// lookups don't wait for their hedge on it (#148).
func TestADoHConnectionThatFailsItsPingIsClosed(t *testing.T) {
	d := newDoH(t, 1)
	after, wait := dohPingAfter, dohPingWait
	dohPingAfter, dohPingWait = scaled(200*time.Millisecond), scaled(200*time.Millisecond)
	t.Cleanup(func() { dohPingAfter, dohPingWait = after, wait })
	var conn atomic.Pointer[silentConn]
	client := newDoHClient(func(ctx context.Context, network, address string) (net.Conn, error) {
		c, err := (&net.Dialer{}).DialContext(ctx, network, address)
		if err != nil {
			return nil, err
		}
		sc := &silentConn{Conn: c}
		conn.Store(sc)
		return sc, nil
	})
	client.Transport.(*http.Transport).TLSClientConfig = d.Client().Transport.(*http.Transport).TLSClientConfig
	s := &Server{dohClient: client, dohSpare: client, lookupTimeout: answerWait}
	s.ctx, s.cancel = context.WithCancel(context.Background())
	t.Cleanup(s.cancel)
	if _, err := s.doh(d.URL+"/abc123", lookupFor(t, 1, "example.com.", 0)); err != nil {
		t.Fatal(err)
	}
	conn.Load().dead.Store(true)
	deadline := time.Now().Add(answerWait)
	for !conn.Load().closed.Load() {
		if time.Now().After(deadline) {
			t.Fatal("the quiet connection was never closed")
		}
		time.Sleep(10 * time.Millisecond)
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
	// The device hears SERVFAIL at once.
	q := lookupFor(t, 1, "example.com.", 0)
	a, err := lookupUDP(c, q, answerWait)
	if err != nil {
		t.Fatal(err)
	}
	serverFailure(t, q, a)
	// Once, and without the URL: its path is the user's Control D profile.
	if line := next(); line != "DNS over HTTPS: the server answered 400 Bad Request" {
		t.Fatalf("logged %q", line)
	}
	// The next failure of the run isn't logged, and the first answer after them is.
	lookupUDP(c, lookupFor(t, 2, "example.com.", 0), time.Second)
	s.SetDNS(&dnsUpstream{doh: d.URL + "/abc123"})
	if _, err := lookupUDP(c, lookupFor(t, 3, "example.com.", 0), answerWait); err != nil {
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
	s.lookupTimeout = scaled(300 * time.Millisecond)
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
	for _, plain := range []bool{false, true} {
		t.Run(map[bool]string{false: "DoH", true: "plain"}[plain], func(t *testing.T) {
			s, c := setup(t)
			var asked func()
			if plain {
				p := newPlain(t, 1)
				p.silent.Store(true)
				s.plainTimeout = time.Minute
				viaPlain(s, p)
				asked = func() { p.waitAsked(t); p.waitAsked(t) }
			} else {
				d := newDoH(t, 1)
				d.holding(t)
				viaDoH(s, d)
				asked = func() { waitAsked(t, d); waitAsked(t, d) }
			}
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
			asked()
			done := make(chan struct{})
			go func() { s.Close(); close(done) }()
			select {
			case <-done:
			case <-time.After(5 * time.Second):
				t.Fatal("Close waited for the upstream")
			}
		})
	}
}

func TestAServerFailureAnswersTheQuery(t *testing.T) {
	q := lookupFor(t, 9, "example.com.", 1232)
	serverFailure(t, q, servfail(q))
	for _, bad := range [][]byte{nil, {1, 2, 3}, answerTo(t, q, 1)} {
		if got := servfail(bad); got != nil {
			t.Errorf("SERVFAIL %x for %x", got, bad)
		}
	}
}

func TestUDPSizeAndCutting(t *testing.T) {
	for _, c := range []struct {
		size, want int
	}{{0, 512}, {256, 512}, {1232, 1232}, {4096, 4096}, {65535, udpMax}} {
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
