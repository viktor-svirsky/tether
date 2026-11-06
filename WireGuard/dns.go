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
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// DNS on 10.7.0.1 (#100). A device whose config names 10.7.0.1 as its DNS server asks Tether, and
// Tether asks the upstream Swift set in the device list:
//
//   - A DoH server (RFC 8484), like a Control D profile's https://dns.controld.com/<id>. Tether
//     asks over HTTPS and builds the reply itself. The server knows the profile by the URL, so
//     the iPhone's carrier address, shared and changing, doesn't matter, as it does for Control
//     D's plain resolvers, which answer only addresses the user authorized.
//   - One or two plain servers. Then 10.7.0.1 is only another name for one of them: a lookup goes
//     through the device's cone like any UDP, or its connection like any TCP, and the replies
//     come back from 10.7.0.1. That's what a device set up with Control D gets once the user
//     picks another server, so it keeps resolving.
//
// With no upstream, 10.7.0.1 stays inside like every tunnel address.

var dnsAddr = netip.MustParseAddrPort("10.7.0.1:53")

const (
	// dohTimeout is how long a lookup waits for the DoH server, a second try included. A
	// device's resolver asks again after about a second, and gives up after a few.
	dohTimeout = 5 * time.Second
	// maxLookups caps a device's DoH lookups waiting for an answer. A page load asks for dozens
	// of names at once, and a resolver asks again when an answer is slow, so a slow server
	// doubles them. Each is a goroutine and a request, a few KB.
	maxLookups = 128
	// dnsMessageMax is the biggest DNS message: TCP's length prefix is 2 bytes.
	dnsMessageMax = 0xffff
	// dnsHeaderLen is a DNS message's fixed header. Anything shorter isn't a lookup.
	dnsHeaderLen = 12
)

// dnsUpstream is where lookups to 10.7.0.1 go: doh when it's set, otherwise udp.
type dnsUpstream struct {
	doh string
	udp []netip.AddrPort // one or two, port 53
}

// SetDNS sets where lookups to 10.7.0.1 go from now on. Nil keeps them inside.
func (s *Server) SetDNS(u *dnsUpstream) { s.upstream.Store(u) }

// dnsRoute says where a lookup to 10.7.0.1 goes: to a plain server, or to the DoH URL. Both empty
// with no upstream.
func (s *Server) dnsRoute() (plain netip.AddrPort, doh string) {
	u := s.upstream.Load()
	switch {
	case u == nil || u.doh == "" && len(u.udp) == 0:
		return netip.AddrPort{}, ""
	case u.doh != "":
		return netip.AddrPort{}, u.doh
	default:
		// Taking turns, so a lookup the first server dropped is asked again of the second.
		return u.udp[int(s.dnsTurn.Add(1))%len(u.udp)], ""
	}
}

// fromPlainDNS says whether src is one of the plain servers 10.7.0.1 stands in for.
func (s *Server) fromPlainDNS(src netip.AddrPort) bool {
	u := s.upstream.Load()
	if u == nil {
		return false
	}
	for _, a := range u.udp {
		if a == src {
			return true
		}
	}
	return false
}

// askDoH answers a device's UDP lookup from the DoH server, on a goroutine of its own, so
// handleUDP never waits. A paused or removed device, one at maxLookups and a closing server get
// nothing, and the device's resolver asks again.
func (s *Server) askDoH(device netip.AddrPort, doh string, query []byte) {
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
		answer, err := s.doh(doh, query)
		s.dohResult(err)
		if err != nil {
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

// dohResult logs the first failure of a run of them, and the first answer after it. A slow or
// wrong server fails every lookup of a page load, and a device may send anything to 10.7.0.1, so a
// line each would fill the log. Lookups ended by Close aren't failures.
func (s *Server) dohResult(err error) {
	switch {
	case err == nil:
		if s.dohFailing.Swap(false) {
			s.notice("DNS over HTTPS answers again")
		}
	case s.ctx.Err() != nil:
	case !s.dohFailing.Swap(true):
		s.notice("DNS over HTTPS: %v", err)
	}
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

// udpSize is how big a UDP answer the query's sender takes: its EDNS0 size, and 512 bytes without
// one or below it.
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
			return max(512, int(h.Class)) // an OPT record's class is the size
		}
		if p.SkipAdditional() != nil {
			return 512
		}
	}
}

// dohConn is DNS over TCP to 10.7.0.1 with a DoH upstream: forwardTCP copies the device's side to it
// as it would to a connection it dialed, so the caps, the counting and the closing work the same.
// serveDoH reads the queries written to it and writes the answers to be read from it, each after
// its length in 2 bytes (RFC 7766). Nil when the server is closing.
func (s *Server) dohConn(doh string) net.Conn {
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
		s.serveDoH(doh, queriesIn, answersOut)
		queriesIn.Close()  // a write still waiting fails
		answersOut.Close() // the device's side gets a FIN
	}()
	return &dnsConn{answers: answersIn, queries: queriesOut}
}

// serveDoH answers the queries one at a time, in order, until the device closes its side, a query
// can't be read, or the DoH server fails, which closes the connection so the device asks again.
// RFC 7766 would have them answered at once, but a device asks over TCP only after a cut UDP answer.
func (s *Server) serveDoH(doh string, queries io.Reader, answers io.Writer) {
	for {
		var size [2]byte
		if _, err := io.ReadFull(queries, size[:]); err != nil {
			return
		}
		query := make([]byte, binary.BigEndian.Uint16(size[:]))
		if _, err := io.ReadFull(queries, query); err != nil || len(query) < dnsHeaderLen {
			return
		}
		answer, err := s.doh(doh, query)
		s.dohResult(err)
		if err != nil {
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

// dnsConn is the connection forwardTCP holds for dohConn. CloseWrite passes the device's FIN on.
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
