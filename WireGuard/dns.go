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
	"net/netip"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// DNS on 10.7.0.1 (#100, #121). Every device's config names 10.7.0.1 as its DNS server, and Tether
// answers there as a forwarding resolver. Each lookup, over UDP or TCP, is asked of the upstream Swift
// set at that moment, so a change of the setting reaches a device's next lookup, on a TCP connection
// already open too. The upstream is:
//
//   - A DoH server (RFC 8484), like a Control D profile's https://dns.controld.com/<id>. Tether
//     asks over HTTPS. The server knows the profile by the URL, so the iPhone's carrier address,
//     shared and changing, doesn't matter, as it does for Control D's plain resolvers, which answer
//     only addresses the user authorized.
//   - One or two plain servers, asked from the iPhone the way a device's own UDP and TCP leave it,
//     through the carrier's NAT64 when the iPhone has no IPv4 route (see nat64.go). The first is
//     asked first, and the second only when the first stays silent for plainTimeout, so a second
//     server is a backup and sees nothing while the first answers (#123). A lookup over TCP is
//     asked over TCP, so an answer a server cut for UDP reaches the device whole.
//
// Any answer ends a lookup, an error like REFUSED too: the server answered, and the next one isn't
// asked. When the upstream doesn't answer, the device gets SERVFAIL, so it doesn't wait out its own
// timeouts. With no upstream, 10.7.0.1 stays inside like every tunnel address.

var dnsAddr = netip.MustParseAddrPort("10.7.0.1:53")

const (
	// dohTimeout is how long a lookup waits for the DoH server, a second try included. A
	// device's resolver asks again after about a second, and gives up after a few.
	dohTimeout = 5 * time.Second
	// plainTimeout is how long a plain server has to answer before the next one is asked too. A
	// resolver answers from its cache in milliseconds, and most names it must look up in well under
	// a second, so one silent for 2 s is most likely down. Two servers take 4 s at most before the
	// device gets SERVFAIL, inside dohTimeout and the 5 s glibc's resolver waits for each try. The
	// first server's late answer is still taken while the second is asked.
	plainTimeout = 2 * time.Second
	// maxLookups caps a device's UDP lookups waiting for an answer. A page load asks for dozens of
	// names at once, and a resolver asks again when an answer is slow, so a slow server doubles
	// them. Each is a few goroutines and a request, or a socket a server and a buffer of up to
	// udpMax, a few KB.
	maxLookups = 128
	// dnsMessageMax is the biggest DNS message: TCP's length prefix is 2 bytes.
	dnsMessageMax = 0xffff
	// dnsHeaderLen is a DNS message's fixed header. Anything shorter isn't a lookup.
	dnsHeaderLen = 12
	// udpMax is the biggest UDP answer a device gets, whatever size its query offers. Bigger ones
	// are cut, and the device asks over TCP. Resolvers offer 1232 or 4096, and a lookup holds a
	// buffer of this size while it waits.
	udpMax = 4096
)

// dnsUpstream is where lookups to 10.7.0.1 go: doh when it's set, otherwise udp.
type dnsUpstream struct {
	doh string
	udp []netip.AddrPort // one or two, port 53, the first one first
}

// set says whether lookups go anywhere. Without an upstream, 10.7.0.1 stays inside.
func (u *dnsUpstream) set() bool { return u != nil && (u.doh != "" || len(u.udp) > 0) }

// SetDNS sets where lookups to 10.7.0.1 go from now on. Nil keeps them inside.
func (s *Server) SetDNS(u *dnsUpstream) { s.upstream.Store(u) }

// resolve answers one query a device sent to 10.7.0.1, over UDP or TCP, from the upstream set now:
// the upstream's answer, or SERVFAIL when it gave none. Nil when there's nothing to answer: no
// upstream, a message that isn't a query, or a closing server.
func (s *Server) resolve(query []byte, overTCP bool) []byte {
	if len(query) < dnsHeaderLen || query[2]&0x80 != 0 { // QR: an answer, not a query
		return nil
	}
	u := s.upstream.Load()
	if !u.set() {
		return nil
	}
	var answer []byte
	var err error
	if u.doh != "" {
		answer, err = s.doh(u.doh, query)
		s.dnsResult("DNS over HTTPS", err)
	} else {
		answer, err = s.askPlain(u.udp, query, overTCP)
		s.dnsResult("DNS", err)
	}
	switch {
	case err == nil:
		return answer
	case s.ctx.Err() != nil:
		return nil
	default:
		return servfail(query)
	}
}

// lookup answers a device's UDP lookup to 10.7.0.1, on a goroutine of its own, so handleUDP never
// waits. A paused or removed device, one at maxLookups and a closing server get nothing, and the
// device's resolver asks again.
func (s *Server) lookup(device netip.AddrPort, query []byte) {
	if len(query) < dnsHeaderLen {
		return
	}
	s.mu.Lock()
	owner := s.ownerLocked(device.Addr())
	if !owner.IsValid() || s.closed || s.lookups[owner] >= s.maxLookups {
		s.mu.Unlock()
		return
	}
	s.lookups[owner]++
	key := s.keys[owner]
	counts := s.trafficOfLocked(owner)
	s.looking.Add(1) // under s.mu, so it comes before Close's Wait or not at all
	s.mu.Unlock()
	go func() {
		defer s.looking.Done()
		defer func() {
			s.mu.Lock()
			release(s.lookups, owner)
			s.mu.Unlock()
		}()
		s.count(counts, true, len(query))
		answer := s.resolve(query, false)
		if answer == nil {
			return
		}
		answer = fitUDP(query, answer)
		if answer == nil {
			return
		}
		packets := replyPackets(dnsAddr, device, answer, s.nextID())
		s.mu.Lock()
		defer s.mu.Unlock()
		// The device may have been paused or removed while the server answered, and its address
		// may be another device's now, which the key tells apart.
		if s.closed || s.ownerLocked(device.Addr()) != owner || s.keys[owner] != key {
			return
		}
		s.count(counts, false, len(answer))
		for _, p := range packets {
			s.tun.inject(p)
		}
	}()
}

// dnsResult logs the first failure of a run of them, and the first answer after it. A slow or
// wrong server fails every lookup of a page load, and a device may send anything to 10.7.0.1, so a
// line each would fill the log. Lookups ended by Close aren't failures. via says which kind of
// upstream it was.
func (s *Server) dnsResult(via string, err error) {
	switch {
	case err == nil:
		if s.dnsFailing.Swap(false) {
			s.notice("%s answers again", via)
		}
	case s.ctx.Err() != nil:
	case !s.dnsFailing.Swap(true):
		s.notice("%s: %v", via, err)
	}
}

// askPlain asks the plain servers, the first one first. The next one is asked only once those before
// it failed or stayed silent for plainTimeout, and a late answer from one asked before still counts.
// The first answer with the query's ID is the answer, whatever its RCODE: the server answered.
func (s *Server) askPlain(servers []netip.AddrPort, query []byte, overTCP bool) ([]byte, error) {
	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(len(servers))*s.plainTimeout)
	var wg sync.WaitGroup
	defer wg.Wait() // runs after cancel, which ends every ask at once
	defer cancel()
	ask := s.askUDP
	if overTCP {
		ask = s.askTCP
	}
	type result struct {
		answer []byte
		err    error
	}
	results := make(chan result, len(servers))
	asked, failed := 0, 0
	askNext := func() {
		server := servers[asked]
		asked++
		wg.Go(func() {
			answer, err := ask(ctx, server, query)
			results <- result{answer, err}
		})
	}
	askNext()
	next := time.NewTimer(s.plainTimeout)
	defer next.Stop()
	for {
		select {
		case r := <-results:
			if r.err == nil {
				return r.answer, nil
			}
			if failed++; failed < asked {
				continue // one asked before may still answer
			}
			if asked == len(servers) {
				return nil, noAnswer(servers)
			}
		case <-next.C:
			if asked == len(servers) {
				continue // the last one has until ctx ends
			}
		case <-ctx.Done():
			return nil, noAnswer(servers)
		}
		askNext()
		next.Reset(s.plainTimeout)
	}
}

func noAnswer(servers []netip.AddrPort) error {
	var names []string
	for _, a := range servers {
		names = append(names, a.Addr().String())
	}
	return fmt.Errorf("no answer from %s", strings.Join(names, " or "))
}

// askUDP sends the query to server from a socket of its own, a new port each time, the way a cone
// sends a device's packets: through the carrier's NAT64 when the iPhone has no IPv4 route. It returns
// the first answer from server to the query, and waits until ctx ends for one. An answer bigger
// than the device takes comes back too, and fitUDP cuts it.
func (s *Server) askUDP(ctx context.Context, server netip.AddrPort, query []byte) ([]byte, error) {
	// IPv4 only, as a cone's socket, see cone.conn.
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return nil, err
	}
	err = s.sendTo(conn, query, s.toNet(server))
	if noRoute(err) {
		if via, ok := s.viaNAT64(ctx, server); ok {
			conn.Close()
			// Both IPv4 and IPv6, as a cone's NAT64 socket, see openNAT64.
			if conn, err = net.ListenUDP("udp", nil); err != nil {
				return nil, err
			}
			err = s.sendTo(conn, query, s.toNet(via))
		}
	}
	defer conn.Close()
	if err != nil {
		return nil, err
	}
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	// One byte more than the device takes: an answer cut there is too big, and fitUDP needs only
	// its header and questions, at the front, to cut it for the device.
	buf := make([]byte, udpSize(query)+1)
	for {
		n, from, err := conn.ReadFromUDPAddrPort(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, err
		}
		src := s.fromNAT64(s.fromNet(netip.AddrPortFrom(from.Addr().Unmap(), from.Port())))
		if src == server && answers(query, buf[:n]) {
			return bytes.Clone(buf[:n]), nil
		}
	}
}

// askTCP asks server over a TCP connection of its own, dialed the way a device's connections are.
func (s *Server) askTCP(ctx context.Context, server netip.AddrPort, query []byte) ([]byte, error) {
	conn, err := s.dialTCP(ctx, server)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	// One write, so the length and the query leave in one segment.
	if _, err := conn.Write(append(binary.BigEndian.AppendUint16(nil, uint16(len(query))), query...)); err != nil {
		return nil, err
	}
	var size [2]byte
	if _, err := io.ReadFull(conn, size[:]); err != nil {
		return nil, err
	}
	answer := make([]byte, binary.BigEndian.Uint16(size[:]))
	if _, err := io.ReadFull(conn, answer); err != nil {
		return nil, err
	}
	if !answers(query, answer) {
		return nil, errors.New("an answer to another query")
	}
	return answer, nil
}

// answers says whether m is an answer to query: QR set, the query's ID and its questions (RFC 5452
// 9.1), so a stray or forged packet to the port isn't taken.
func answers(query, m []byte) bool {
	if len(m) < dnsHeaderLen || m[2]&0x80 == 0 || m[0] != query[0] || m[1] != query[1] {
		return false
	}
	asked, err := questionsOf(query)
	if err != nil {
		return false
	}
	got, err := questionsOf(m)
	return err == nil && slices.Equal(got, asked)
}

func questionsOf(m []byte) ([]dnsmessage.Question, error) {
	var p dnsmessage.Parser
	if _, err := p.Start(m); err != nil {
		return nil, err
	}
	return p.AllQuestions()
}

// servfail is SERVFAIL for the query (RFC 1035 4.1.1): its ID, opcode and questions, QR set and RCODE
// 2, so the device's resolver stops waiting. Nil for a message that isn't a query.
func servfail(query []byte) []byte {
	var p dnsmessage.Parser
	h, err := p.Start(query)
	if err != nil || h.Response {
		return nil
	}
	questions, err := p.AllQuestions()
	if err != nil {
		return nil
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{
		ID: h.ID, Response: true, OpCode: h.OpCode, RecursionDesired: h.RecursionDesired,
		RecursionAvailable: true, RCode: dnsmessage.RCodeServerFailure,
	})
	b.StartQuestions()
	for _, q := range questions {
		if b.Question(q) != nil {
			return nil
		}
	}
	m, err := b.Finish()
	if err != nil {
		return nil
	}
	return m
}

// doh asks the DoH server and returns its answer with the query's ID. A request that fails before
// the server answers is made once more on a new connection: a kept-alive connection dies without a
// word when the iPhone moves between Wi-Fi and cellular, and only the first request on it finds
// out. An error never carries the URL, since its path is the user's profile.
func (s *Server) doh(doh string, query []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(s.ctx, s.dohTimeout)
	defer cancel()
	q := bytes.Clone(query)
	q[0], q[1] = 0, 0 // RFC 8484 4.1: ID 0, so a cache on the way answers anyone who asks the same
	var err error
	for range 2 {
		var answer []byte
		if answer, err = s.dohOnce(ctx, doh, q); err == nil {
			answer[0], answer[1] = query[0], query[1]
			return answer, nil
		}
		var ue *url.Error
		if !errors.As(err, &ue) {
			return nil, err // the server answered, and would answer the same again
		}
		err = ue.Err
		if ctx.Err() != nil {
			break
		}
		s.dohClient.CloseIdleConnections()
	}
	return nil, err
}

func (s *Server) dohOnce(ctx context.Context, doh string, query []byte) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, doh, bytes.NewReader(query))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/dns-message")
	req.Header.Set("Accept", "application/dns-message")
	resp, err := s.dohClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("the server answered %s", resp.Status)
	}
	answer, err := io.ReadAll(io.LimitReader(resp.Body, dnsMessageMax+1))
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return nil, fmt.Errorf("reading the answer: %w", err)
	}
	if len(answer) < dnsHeaderLen || len(answer) > dnsMessageMax {
		return nil, fmt.Errorf("an answer of %d bytes", len(answer))
	}
	return answer, nil
}

// fitUDP is the answer as a device that asked over UDP takes it: whole when it fits the size the
// query offers, otherwise only its header and questions with TC set, so the device asks again over
// TCP (RFC 1035 4.2.1, RFC 6891 6.2.5). Nil for an answer too big that can't be read.
func fitUDP(query, answer []byte) []byte {
	if len(answer) <= udpSize(query) {
		return answer
	}
	var p dnsmessage.Parser
	h, err := p.Start(answer)
	if err != nil {
		return nil
	}
	questions, err := p.AllQuestions()
	if err != nil {
		return nil
	}
	h.Truncated = true
	b := dnsmessage.NewBuilder(nil, h)
	b.StartQuestions()
	for _, q := range questions {
		if b.Question(q) != nil {
			return nil
		}
	}
	cut, err := b.Finish()
	if err != nil || len(cut) > 512 {
		return nil
	}
	return cut
}

// udpSize is how big a UDP answer the query's sender takes: its EDNS0 size, 512 bytes without one or
// below it, and udpMax at most.
func udpSize(query []byte) int {
	var p dnsmessage.Parser
	if _, err := p.Start(query); err != nil {
		return 512
	}
	if p.SkipAllQuestions() != nil || p.SkipAllAnswers() != nil || p.SkipAllAuthorities() != nil {
		return 512
	}
	for {
		h, err := p.AdditionalHeader()
		if err != nil {
			return 512
		}
		if h.Type == dnsmessage.TypeOPT {
			return min(max(512, int(h.Class)), udpMax) // an OPT record's class is the size
		}
		if p.SkipAdditional() != nil {
			return 512
		}
	}
}

// lookupConn is DNS over TCP to 10.7.0.1: forwardTCP copies the device's side to it as it would to
// a connection it dialed, so the caps, the counting and the closing work the same. serveTCP reads
// the queries written to it and writes the answers to be read from it, each after its length in 2
// bytes (RFC 7766). Nil when the server is closing.
func (s *Server) lookupConn() net.Conn {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.looking.Add(1)
	s.mu.Unlock()
	queriesIn, queriesOut := io.Pipe()
	answersIn, answersOut := io.Pipe()
	go func() {
		defer s.looking.Done()
		s.serveTCP(queriesIn, answersOut)
		queriesIn.Close()  // a write still waiting fails
		answersOut.Close() // the device's side gets a FIN
	}()
	return &dnsConn{answers: answersIn, queries: queriesOut}
}

// serveTCP answers the queries one at a time, in order, each from the upstream set when it's read,
// until the device closes its side, a query can't be read, or there's nothing to answer, see
// resolve. RFC 7766 would have them answered at once, but a device asks over TCP only after a cut
// UDP answer.
func (s *Server) serveTCP(queries io.Reader, answers io.Writer) {
	for {
		var size [2]byte
		if _, err := io.ReadFull(queries, size[:]); err != nil {
			return
		}
		query := make([]byte, binary.BigEndian.Uint16(size[:]))
		if _, err := io.ReadFull(queries, query); err != nil {
			return
		}
		answer := s.resolve(query, true)
		if answer == nil {
			return
		}
		if _, err := answers.Write(binary.BigEndian.AppendUint16(nil, uint16(len(answer)))); err != nil {
			return
		}
		if _, err := answers.Write(answer); err != nil {
			return
		}
	}
}

// dnsConn is the connection forwardTCP holds for lookupConn. CloseWrite passes the device's FIN on.
type dnsConn struct {
	answers *io.PipeReader
	queries *io.PipeWriter
}

func (c *dnsConn) Read(b []byte) (int, error)  { return c.answers.Read(b) }
func (c *dnsConn) Write(b []byte) (int, error) { return c.queries.Write(b) }
func (c *dnsConn) CloseWrite() error           { return c.queries.Close() }

func (c *dnsConn) Close() error {
	c.queries.Close()
	return c.answers.Close()
}

func (c *dnsConn) LocalAddr() net.Addr  { return net.TCPAddrFromAddrPort(netip.AddrPort{}) }
func (c *dnsConn) RemoteAddr() net.Addr { return net.TCPAddrFromAddrPort(dnsAddr) }

// No deadlines: forwardTCP sets none on the connections it dials either.
func (c *dnsConn) SetDeadline(time.Time) error      { return nil }
func (c *dnsConn) SetReadDeadline(time.Time) error  { return nil }
func (c *dnsConn) SetWriteDeadline(time.Time) error { return nil }

// newDoHClient is the HTTP client for DoH. Its connections keep TCP keepalive as rare as the
// server's dials do, see Start, and one idle for a minute is closed rather than probed. No proxy:
// lookups go out like the devices' traffic.
func newDoHClient(dial func(ctx context.Context, network, address string) (net.Conn, error)) *http.Client {
	return &http.Client{Transport: &http.Transport{
		DialContext:         dial,
		ForceAttemptHTTP2:   true, // a custom dial turns HTTP/2 off otherwise
		TLSHandshakeTimeout: dohTimeout,
		IdleConnTimeout:     time.Minute,
		MaxIdleConnsPerHost: 2,
	}}
}

// configDNS is the device list's "dns": a DoH URL, or one or two plain IPv4 servers.
type configDNS struct {
	DoH string   `json:"doh"`
	UDP []string `json:"udp"`
}

// parseDNS reads the device list's "dns". Missing is nil, and lookups to 10.7.0.1 stay inside. An
// error never quotes the URL, since its path is the user's profile.
func parseDNS(d *configDNS) (*dnsUpstream, error) {
	switch {
	case d == nil:
		return nil, nil
	case d.DoH != "" && len(d.UDP) == 0:
		u, err := url.Parse(d.DoH)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
			return nil, errors.New("DNS: the DoH server isn't an https URL")
		}
		return &dnsUpstream{doh: d.DoH}, nil
	case d.DoH == "" && len(d.UDP) >= 1 && len(d.UDP) <= 2:
		var servers []netip.AddrPort
		for _, text := range d.UDP {
			a, err := netip.ParseAddr(text)
			// IPv4 only, as a device's tunnel is, and somewhere the lookup can go.
			if err != nil || !a.Is4() || !forwardable(a) {
				return nil, fmt.Errorf("DNS: %q isn't a server's IPv4 address", text)
			}
			servers = append(servers, netip.AddrPortFrom(a, 53))
		}
		return &dnsUpstream{udp: servers}, nil
	default:
		return nil, errors.New("DNS: a DoH server, or one or two plain servers")
	}
}
