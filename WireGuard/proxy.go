package main

// An HTTP proxy for devices without WireGuard (#78). A device on the hotspot sets 172.20.10.1:8118
// as the proxy in its Wi-Fi settings, and the proxy makes each of its connections again from the
// iPhone, so to the carrier it's iPhone traffic, as a tunnel device's is. It takes CONNECT for
// HTTPS and plain http:// requests, which covers browsers and most apps. UDP, pings and apps that
// ignore the system proxy still go out as hotspot traffic, so WireGuard stays the whole-device way.
//
// There's no password: the proxy fields of Android, Windows and consoles have no login, so one
// would lock most devices out. Only the hotspot's clients are served, and the hotspot has its own
// password. It listens on IPv4 only: the hotspot's IPv6 address is the iPhone's global one, so a
// listener there would face the internet.
//
// The proxy's traffic is one device's, "Proxy" in Stats, with its own pause. Its connections follow
// the rules a tunnel device's do: no iPhone-own address but the config page, Block for the local
// networks, names looked up through Tether's own DNS, and NAT64 on an IPv6-only carrier.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"maps"
	"math/rand/v2"
	"net"
	"net/http"
	"net/http/httputil"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

const (
	// proxyPort is where the proxy listens, next to WireGuard on the hotspot's address.
	proxyPort = 8118
	// maxProxyConns caps the proxy's client connections, for all its devices together, like a
	// tunnel device's maxConns. A CONNECT holds one connection out, and plain requests share the
	// transport's idle pool on top, see maxIdleOut. A browser keeps a few dozen.
	maxProxyConns = 256
	// maxProxyPerClient is one device's share of maxProxyConns, so one device can't lock the others out.
	maxProxyPerClient = maxProxyConns / 2
	// maxIdleOut caps the idle connections plain requests keep to far ends, and idleOut is how long
	// one is kept. A page's next request to the same host takes one, and few wait longer than that.
	maxIdleOut, maxIdleOutPerHost, idleOut = 32, 2, 30 * time.Second
	// proxyHandshake is how long a client has to send its request: a stuck or hostile one can't
	// hold a slot longer.
	proxyHandshake = 10 * time.Second
	// proxyIdle is how long a kept-alive client connection may wait for its next request.
	proxyIdle = 2 * time.Minute
	// proxyRetry is the first wait before listening again after iOS closed the socket, doubling up
	// to proxyRetryMax while it keeps failing, so a hotspot that's gone doesn't spin.
	proxyRetry, proxyRetryMax = time.Second, 30 * time.Second
)

// hotspotNet is the hotspot's network, Wi-Fi, USB and Bluetooth alike. The proxy serves only
// clients there, never the cellular side or a Wi-Fi the iPhone is on.
var hotspotNet = netip.MustParsePrefix("172.20.10.0/28")

// proxyFlows is the key the proxy's connections are kept under in s.flows. No device has the
// invalid address, so SetPeers and readHandshakes never close them, and Close, Block and the proxy's
// own pause and off do.
var proxyFlows = netip.Addr{}

// errRefused is a destination no device may reach, which the client gets as 403.
var errRefused = errors.New("Tether doesn't let devices reach that address")

// errNotHTTP ends a connection whose first byte can't start an HTTP request: a SOCKS greeting or a
// TLS hello is closed at once instead of waiting out proxyHandshake.
var errNotHTTP = errors.New("not HTTP")

// proxy is the server's HTTP proxy. Its state is under s.mu.
type proxy struct {
	// Read when the proxy turns on. Tests swap them, under s.mu.
	at           netip.AddrPort // where it listens. Invalid is the hotspot's address on proxyPort
	clients      netip.Prefix   // whom it serves
	systemLookup func(ctx context.Context, host string) ([]netip.Addr, error)
	retry        time.Duration
	maxConns     int
	handshake    time.Duration
	maxLookups   int // the proxy's name lookups at once, for all its devices, like a device's maxLookups
	maxPerClient int
	listen       func(ctx context.Context, address string) (net.Listener, error)

	// counts is the proxy's bytes, the same ones the totals count.
	counts traffic

	run       *proxyRun // nil while it's off
	paused    bool
	open      int                // client connections, see maxConns
	openBy    map[netip.Addr]int // each client's, see maxPerClient
	lookups   int                // lookups still running, also ones whose client gave up
	refusedAt time.Time          // when a refusal was last logged, so a busy client can't fill the log
}

func newProxy() *proxy {
	return &proxy{
		clients: hotspotNet,
		systemLookup: func(ctx context.Context, host string) ([]netip.Addr, error) {
			return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		},
		retry:        proxyRetry,
		maxConns:     maxProxyConns,
		maxPerClient: maxProxyPerClient,
		maxLookups:   maxLookups,
		handshake:    proxyHandshake,
		openBy:       map[netip.Addr]int{},
		listen: func(ctx context.Context, address string) (net.Listener, error) {
			// The keepalive of a tunnel device's side, see Start: a device that leaves the hotspot
			// never closes its connections.
			lc := net.ListenConfig{KeepAliveConfig: net.KeepAliveConfig{Enable: true, Idle: 60 * time.Second, Interval: 15 * time.Second, Count: 4}}
			return lc.Listen(ctx, "tcp4", address)
		},
	}
}

// proxyRun is the proxy from on to off: its listener, kept listening, and the requests it serves.
type proxyRun struct {
	s            *Server
	p            *proxy
	ctx          context.Context // ends with off or Close, and the dials with it
	cancel       context.CancelFunc
	srv          *http.Server
	forward      *httputil.ReverseProxy // plain http:// requests
	transport    *http.Transport
	systemLookup func(ctx context.Context, host string) ([]netip.Addr, error)
	listen       func(ctx context.Context, address string) (net.Listener, error)
	retry        time.Duration
	done         chan struct{} // closed when serve returns
	wake         chan struct{} // asks serve to listen again now, see wakeProxy
	// Only serve's goroutine, which Serve's Accept runs on, reads them. working says an Accept
	// succeeded since it last listened, and down that a failure was logged since it last worked.
	working, down bool
	// Under s.mu. at is where it listens, with the port it got once it listened.
	at       netip.AddrPort
	ln       net.Listener // nil while not listening
	stopped  bool
	handlers sync.WaitGroup // added to under s.mu while not stopped, see enter
}

// hotspotHost is the hotspot's IPv4 address among the server's hosts.
func hotspotHost(hosts []netip.Addr) (netip.Addr, bool) {
	for _, h := range hosts {
		if h.Is4() && hotspotNet.Contains(h) {
			return h, true
		}
	}
	return netip.Addr{}, false
}

// SetProxy turns the proxy on or off and pauses or resumes it. Swift sends it with every config,
// so only a change does anything. Paused, it refuses new connections and ends the open ones, as a
// paused device's are. Off ends them too, and stops listening.
func (s *Server) SetProxy(on, paused bool) {
	s.bind.mu.Lock()
	hosts := s.bind.hosts
	s.bind.mu.Unlock()
	p := s.proxy
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	wasPaused := p.paused
	p.paused = paused
	var start *proxyRun
	var nowhere bool
	if on && p.run == nil {
		at := p.at
		if !at.IsValid() {
			host, ok := hotspotHost(hosts)
			at, nowhere = netip.AddrPortFrom(host, proxyPort), !ok
		}
		if !nowhere {
			start = s.newProxyRun(at)
			p.run = start
		}
	}
	var closing []io.Closer
	if paused && !wasPaused {
		closing = slices.Collect(maps.Keys(s.flows[proxyFlows]))
	}
	s.mu.Unlock()
	for _, c := range closing {
		c.Close()
	}
	if paused != wasPaused {
		serverLog.add(time.Now(), map[bool]string{true: "proxy paused", false: "proxy resumed"}[paused])
	}
	switch {
	case nowhere:
		serverLog.add(time.Now(), "proxy: no hotspot IPv4 address to listen on")
	case start != nil:
		go start.serve()
	case !on:
		s.stopProxy()
	}
}

// stopProxy turns the proxy off: once it returns, it doesn't listen and none of its connections is
// open. Close calls it too.
func (s *Server) stopProxy() {
	s.mu.Lock()
	r := s.proxy.run
	s.proxy.run = nil
	if r != nil {
		r.stopped = true // nothing new is kept or let in from here, see admit and keep
	}
	s.mu.Unlock()
	if r == nil {
		return
	}
	r.cancel()
	r.srv.Close() // the listener, and the connections still reading a request
	<-r.done
	s.mu.Lock()
	open := slices.Collect(maps.Keys(s.flows[proxyFlows]))
	s.mu.Unlock()
	for _, c := range open {
		c.Close()
	}
	r.handlers.Wait()
	r.transport.CloseIdleConnections()
	serverLog.add(time.Now(), "proxy off")
}

// newProxyRun makes a run that listens at at. Runs with s.mu held.
func (s *Server) newProxyRun(at netip.AddrPort) *proxyRun {
	p := s.proxy
	r := &proxyRun{s: s, p: p, at: at, systemLookup: p.systemLookup, listen: p.listen, retry: p.retry,
		done: make(chan struct{}), wake: make(chan struct{}, 1)}
	r.ctx, r.cancel = context.WithCancel(s.ctx)
	quiet := log.New(io.Discard, "", 0) // a client's broken request isn't the log's business
	r.srv = &http.Server{Handler: r, ReadHeaderTimeout: p.handshake, IdleTimeout: proxyIdle, MaxHeaderBytes: 64 << 10, ErrorLog: quiet}
	r.transport = &http.Transport{
		DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			n, err := strconv.ParseUint(port, 10, 16)
			if err != nil {
				return nil, err
			}
			c, err := r.dial(ctx, host, uint16(n), &p.counts)
			if err != nil {
				return nil, err // not a nil *outConn in a non-nil net.Conn
			}
			return c, nil
		},
		DisableCompression:  true, // the device's Accept-Encoding goes as it is
		MaxIdleConns:        maxIdleOut,
		MaxIdleConnsPerHost: maxIdleOutPerHost,
		IdleConnTimeout:     idleOut,
	}
	r.forward = &httputil.ReverseProxy{
		// The URL is absolute already. Rewrite, unlike Director, adds no X-Forwarded-For, and drops
		// the hop-by-hop headers and Proxy-Authorization. It also drops the parts of a query Go can't
		// parse, which the far end may well read, so the query goes as the device wrote it.
		Rewrite:   func(pr *httputil.ProxyRequest) { pr.Out.URL.RawQuery = pr.In.URL.RawQuery },
		Transport: r.transport,
		ErrorLog:  quiet,
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			w.WriteHeader(statusFor(err))
		},
	}
	return r
}

// serve listens and serves until off or Close, and listens again on the same address when iOS
// closes the socket of a suspended app, so the devices' settings keep working. A failure is logged
// once, and the next line is when a client gets in again, so a hotspot that's off doesn't fill the
// log. The wait between tries doubles until a client gets in, since a socket that listens but can't
// accept isn't working either, and the server listening again (ListenOn) cuts it short.
func (r *proxyRun) serve() {
	defer close(r.done)
	s := r.s
	wait := r.retry
	for first := true; ; first = false {
		s.mu.Lock()
		at := r.at
		s.mu.Unlock()
		ln, err := r.listen(r.ctx, at.String())
		if err == nil {
			s.mu.Lock()
			if r.stopped {
				s.mu.Unlock()
				ln.Close()
				return
			}
			bound := ln.Addr().(*net.TCPAddr).AddrPort()
			r.at = netip.AddrPortFrom(bound.Addr().Unmap(), bound.Port()) // the port too, for listening again
			r.ln = ln
			s.mu.Unlock()
			if first {
				serverLog.add(time.Now(), fmt.Sprintf("proxy listening on %v", ln.Addr()))
			}
			r.working = false
			err = r.srv.Serve(&proxyListener{ln, r})
			s.mu.Lock()
			r.ln = nil
			s.mu.Unlock()
			if r.ctx.Err() != nil {
				return
			}
			if r.working {
				wait = r.retry
			}
			r.failed(fmt.Sprintf("proxy: its socket failed, listening again: %v", err))
		} else if r.ctx.Err() == nil {
			r.failed(fmt.Sprintf("proxy: can't listen on %v: %v", at, err))
		}
		select {
		case <-r.ctx.Done():
			return
		case <-r.wake:
			wait = r.retry
			continue
		case <-time.After(wait):
		}
		wait = min(2*wait, proxyRetryMax)
	}
}

// failed logs text, unless a failure was logged already and no client got in since.
func (r *proxyRun) failed(text string) {
	if !r.down {
		r.down = true
		serverLog.add(time.Now(), text)
	}
}

// accepted notes a client got in: the socket works, and after a failure the log says so.
func (r *proxyRun) accepted() {
	r.working = true
	if r.down {
		r.down = false
		r.s.mu.Lock()
		at := r.at
		r.s.mu.Unlock()
		serverLog.add(time.Now(), fmt.Sprintf("proxy listening again on %v", at))
	}
}

// wakeProxy has the proxy try to listen now, when the hotspot's address may be back: the server
// listens again after a change of the hotspot, see ListenOn.
func (s *Server) wakeProxy() {
	s.mu.Lock()
	r := s.proxy.run
	s.mu.Unlock()
	if r == nil {
		return
	}
	select {
	case r.wake <- struct{}{}:
	default:
	}
}

// proxyListener lets in only what admit does.
type proxyListener struct {
	net.Listener
	r *proxyRun
}

func (l *proxyListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		l.r.accepted()
		if pc, ok := l.r.admit(c); ok {
			return pc, nil
		}
	}
}

// admit keeps a new client connection, or closes it: one from off the hotspot, while paused or off,
// and past the cap or the client's share of it. A refusal from off the hotspot is logged once a minute at most.
func (r *proxyRun) admit(c net.Conn) (*proxyConn, bool) {
	s, p := r.s, r.p
	var from netip.Addr
	if a, ok := c.RemoteAddr().(*net.TCPAddr); ok {
		from = a.AddrPort().Addr().Unmap()
	}
	var refusal string
	s.mu.Lock()
	ok := !r.stopped && !s.closed && !p.paused && p.clients.Contains(from) && p.open < p.maxConns &&
		p.openBy[from] < p.maxPerClient
	if !p.clients.Contains(from) && time.Since(p.refusedAt) > time.Minute {
		p.refusedAt = time.Now()
		refusal = fmt.Sprintf("proxy refused %v: not on the hotspot", from)
	}
	if !ok {
		s.mu.Unlock()
		c.Close()
		if refusal != "" {
			serverLog.add(time.Now(), refusal)
		}
		return nil, false
	}
	p.open++
	p.openBy[from]++
	pc := &proxyConn{keptConn: keptConn{Conn: c}}
	untrack := s.trackLocked(proxyFlows, netip.Addr{}, &closer{pc.reset})
	pc.done = func() {
		untrack()
		s.mu.Lock()
		p.open--
		release(p.openBy, from)
		s.mu.Unlock()
	}
	s.mu.Unlock()
	return pc, true
}

// keptConn is a proxy connection kept in s.flows. Close forgets it, and reset, which pause, off,
// Close and Block call, closes it with a reset.
type keptConn struct {
	net.Conn
	once  sync.Once
	done  func()
	ended atomic.Bool // reset from outside, see relay
}

func (c *keptConn) Close() error {
	c.once.Do(c.done)
	return c.Conn.Close()
}

func (c *keptConn) reset() {
	c.ended.Store(true)
	c.once.Do(c.done)
	resetTCP(c.Conn)
}

func (c *keptConn) CloseWrite() error {
	if t, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return t.CloseWrite()
	}
	return nil
}

// proxyConn is a client's connection. Its first byte must be able to start a request, see
// errNotHTTP.
type proxyConn struct {
	keptConn
	read bool
}

func (c *proxyConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	if !c.read && n > 0 {
		c.read = true
		if b[0] < 'A' || b[0] > 'Z' { // every method starts with a capital
			return 0, errNotHTTP
		}
	}
	return n, err
}

// outConn is the iPhone's side of a proxy connection. counts, when set, counts what it moves: a
// plain request's, which the transport copies.
type outConn struct {
	keptConn
	s      *Server
	counts *traffic
}

func (c *outConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	if c.counts != nil && n > 0 {
		c.s.count(c.counts, false, n)
	}
	return n, err
}

func (c *outConn) Write(b []byte) (int, error) {
	n, err := c.Conn.Write(b)
	if c.counts != nil && n > 0 {
		c.s.count(c.counts, true, n)
	}
	return n, err
}

// ServeHTTP takes CONNECT host:port and absolute http:// requests. Anything else is 400: a request
// in origin form is for a web server, and the proxy isn't one.
func (r *proxyRun) ServeHTTP(w http.ResponseWriter, req *http.Request) {
	if !r.enter() {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	defer r.handlers.Done()
	host, port, ok := proxyTarget(req)
	if !ok {
		http.Error(w, "Tether's proxy takes CONNECT host:port and http:// URLs", http.StatusBadRequest)
		return
	}
	// The request ends with its client, and with off and Close.
	ctx, cancel := context.WithCancel(req.Context())
	defer cancel()
	defer context.AfterFunc(r.ctx, cancel)()
	req = req.WithContext(ctx)
	if req.Method != http.MethodConnect {
		r.forward.ServeHTTP(w, req)
		return
	}
	out, err := r.dial(ctx, host, port, nil)
	if err != nil {
		w.WriteHeader(statusFor(err))
		return
	}
	conn, buf, err := http.NewResponseController(w).Hijack()
	if err != nil {
		out.Close()
		return
	}
	client, ok := conn.(*proxyConn)
	if !ok { // every connection comes from admit
		conn.Close()
		out.Close()
		return
	}
	client.SetDeadline(time.Time{}) // the handshake is over
	if _, err := io.WriteString(client, "HTTP/1.1 200 Connection established\r\n\r\n"); err != nil {
		client.Close()
		out.Close()
		return
	}
	// What the client sent right behind its request, a TLS hello say, was read with it.
	var in io.Reader = client
	if n := buf.Reader.Buffered(); n > 0 {
		in = io.MultiReader(io.LimitReader(buf.Reader, int64(n)), client)
	}
	r.relay(client, in, out)
}

// enter counts a request, so stopProxy waits for it. False once the proxy is off.
func (r *proxyRun) enter() bool {
	r.s.mu.Lock()
	defer r.s.mu.Unlock()
	if r.stopped {
		return false
	}
	r.handlers.Add(1)
	return true
}

// statusFor is the client's answer to a failed connection: 403 for a destination Tether refuses,
// 502 for one that couldn't be looked up or reached.
func statusFor(err error) int {
	if errors.Is(err, errRefused) {
		return http.StatusForbidden
	}
	return http.StatusBadGateway
}

// proxyTarget is where a request asks to go: CONNECT's host:port, or an http:// URL's host and
// port, 80 when it has none. The host has no brackets and no zone. False for anything else.
func proxyTarget(r *http.Request) (host string, port uint16, ok bool) {
	var p string
	if r.Method == http.MethodConnect {
		h, pp, err := net.SplitHostPort(r.URL.Host)
		if err != nil {
			return "", 0, false
		}
		host, p = h, pp
	} else {
		if r.URL.Scheme != "http" || r.URL.Host == "" {
			return "", 0, false
		}
		host, p = r.URL.Hostname(), r.URL.Port()
		if p == "" {
			p = "80"
		}
	}
	n, err := strconv.ParseUint(p, 10, 16)
	// A zone is refused: a zoned address isn't one of the iPhone's own, or in Block's ranges, by
	// netip's comparisons, so it would get past both.
	if err != nil || n == 0 || host == "" || strings.ContainsAny(host, "[]%") {
		return "", 0, false
	}
	return host, uint16(n), true
}

// dial makes the iPhone's side of a proxy connection to host:port. A name is looked up first, and
// each address it has is checked by the rules a tunnel device's connection has, see forwardTCP:
// the config page, or leaves. The first one allowed that answers is the connection. errRefused when
// none is allowed.
func (r *proxyRun) dial(ctx context.Context, host string, port uint16, counts *traffic) (*outConn, error) {
	addrs, err := r.lookup(ctx, host)
	if err != nil {
		return nil, err
	}
	s := r.s
	refused := true
	var last error
	for _, a := range addrs {
		dst := netip.AddrPortFrom(a, port)
		page := slices.Contains(*s.page.Load(), dst)
		if !page && !s.leaves(a) {
			continue
		}
		refused = false
		// Only a connection leaves let through is closed by Block: the page stays open.
		var to netip.Addr
		if !page {
			to = a
		}
		s.mu.Lock() // s.dial is read after this, see failure_test.go
		gone := r.stopped
		s.mu.Unlock()
		if gone {
			return nil, net.ErrClosed
		}
		c, err := s.dialTCP(ctx, dst, func(bool) {})
		if err != nil {
			last = err
			if ctx.Err() != nil {
				break
			}
			continue
		}
		out, ok := r.keep(c, to, counts)
		if !ok {
			c.Close()
			return nil, errRefused
		}
		return out, nil
	}
	if refused {
		return nil, errRefused
	}
	return nil, last
}

// keep tracks a dialed connection, so pause, off, Close and Block can end it. False when one of
// them came first: paused or off, or Block covering to while it was dialed.
func (r *proxyRun) keep(c net.Conn, to netip.Addr, counts *traffic) (*outConn, bool) {
	s := r.s
	s.mu.Lock()
	defer s.mu.Unlock()
	if r.stopped || s.closed || r.p.paused || to.IsValid() && s.blocks(to) {
		return nil, false
	}
	out := &outConn{keptConn: keptConn{Conn: c}, s: s, counts: counts}
	out.done = s.trackLocked(proxyFlows, to, &closer{out.reset})
	return out, true
}

// lookup is host's addresses, IPv4-mapped ones as the IPv4 address they carry. A name goes to
// Tether's own DNS, the upstream set in Settings, and without one to the iPhone's resolver, as the
// iPhone's own apps' names do.
func (r *proxyRun) lookup(ctx context.Context, host string) ([]netip.Addr, error) {
	if a, err := netip.ParseAddr(host); err == nil {
		return []netip.Addr{a.Unmap()}, nil
	}
	var addrs []netip.Addr
	var err error
	if r.s.upstream.Load().set() {
		addrs, err = r.s.lookupName(ctx, host)
	} else if err = r.s.takeLookup(); err == nil {
		// The iPhone's resolver ends with ctx, so the slot is free once it returns.
		addrs, err = r.systemLookup(ctx, host)
		r.s.releaseLookup()
	}
	if err == nil && len(addrs) == 0 {
		err = errors.New("no address")
	}
	if err != nil {
		return nil, fmt.Errorf("looking up %s: %w", host, err)
	}
	for i, a := range addrs {
		addrs[i] = a.Unmap()
	}
	return addrs, nil
}

// lookupName asks Tether's DNS for host's IPv4 addresses, and its IPv6 ones when it has none.
// dialTCP reaches an IPv4 one through NAT64 when the iPhone has no IPv4 route.
func (s *Server) lookupName(ctx context.Context, host string) ([]netip.Addr, error) {
	name, err := dnsmessage.NewName(strings.TrimSuffix(host, ".") + ".")
	if err != nil {
		return nil, err
	}
	for _, t := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
		b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: uint16(rand.Uint32()), RecursionDesired: true})
		b.StartQuestions()
		if err := b.Question(dnsmessage.Question{Name: name, Type: t, Class: dnsmessage.ClassINET}); err != nil {
			return nil, err
		}
		query, err := b.Finish()
		if err != nil {
			return nil, err
		}
		answer, err := s.resolveCtx(ctx, query)
		if err != nil {
			return nil, err
		}
		if addrs := addressesIn(answer); len(addrs) > 0 {
			return addrs, nil
		}
	}
	return nil, nil
}

// errTooManyLookups is a lookup past the proxy's maxLookups, which the client gets as 502.
var errTooManyLookups = errors.New("too many lookups at once")

// takeLookup counts a lookup against the proxy's maxLookups, or refuses it at the cap.
func (s *Server) takeLookup() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.proxy.lookups >= s.proxy.maxLookups {
		return errTooManyLookups
	}
	s.proxy.lookups++
	return nil
}

func (s *Server) releaseLookup() {
	s.mu.Lock()
	s.proxy.lookups--
	s.mu.Unlock()
}

// resolveCtx is resolve over TCP, given up on when ctx ends. The lookup itself runs on until its
// own timeout, holding its slot of maxLookups, so a client that closes and asks again can't pile
// them up. Close waits for it, like a device's.
func (s *Server) resolveCtx(ctx context.Context, query []byte) ([]byte, error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil, net.ErrClosed
	}
	if s.proxy.lookups >= s.proxy.maxLookups {
		s.mu.Unlock()
		return nil, errTooManyLookups
	}
	s.proxy.lookups++
	s.looking.Add(1) // under s.mu, so it comes before Close's Wait or not at all
	s.mu.Unlock()
	answered := make(chan []byte, 1)
	go func() {
		defer s.looking.Done()
		defer s.releaseLookup()
		answered <- s.resolve(query, true)
	}()
	select {
	case a := <-answered:
		if a == nil {
			return nil, errors.New("no DNS answer")
		}
		return a, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// addressesIn is the A and AAAA records of a DNS answer, none for an error or one it can't read.
func addressesIn(m []byte) []netip.Addr {
	var p dnsmessage.Parser
	h, err := p.Start(m)
	if err != nil || h.RCode != dnsmessage.RCodeSuccess || p.SkipAllQuestions() != nil {
		return nil
	}
	answers, err := p.AllAnswers()
	if err != nil {
		return nil
	}
	var addrs []netip.Addr
	for _, a := range answers {
		switch b := a.Body.(type) {
		case *dnsmessage.AResource:
			addrs = append(addrs, netip.AddrFrom4(b.A))
		case *dnsmessage.AAAAResource:
			addrs = append(addrs, netip.AddrFrom16(b.AAAA))
		}
	}
	return addrs
}

// relay moves a CONNECT tunnel's bytes both ways and counts them to the proxy, the way forwardTCP
// does a device's: a clean end passes on as a half close, and a failure ends both sides, the other
// one after what's already on its way to it.
func (r *proxyRun) relay(client *proxyConn, in io.Reader, out *outConn) {
	s, counts := r.s, &r.p.counts
	var failed atomic.Bool
	fail := func(clientFailed bool) {
		if failed.Swap(true) {
			return
		}
		// Pause, off or Close reset both sides, and Block only the iPhone's, which ends the
		// client's too, at once: neither has anything left to wait for.
		if client.ended.Load() || out.ended.Load() {
			client.reset()
			out.reset()
			return
		}
		if clientFailed {
			client.reset()
			s.drain(func() int { return sendQueue(out.Conn) })
			out.reset()
		} else {
			out.reset()
			s.drain(func() int { return sendQueue(client.Conn) })
			client.reset()
		}
	}
	var wg sync.WaitGroup
	wg.Go(func() {
		if err, writing := s.copy(out, in, counts, true, nil); err != io.EOF {
			fail(!writing)
		} else {
			out.CloseWrite()
		}
	})
	wg.Go(func() {
		if err, writing := s.copy(client, out, counts, false, nil); err != io.EOF {
			fail(writing)
		} else {
			client.CloseWrite()
		}
	})
	wg.Wait()
	client.Close()
	out.Close()
}

// proxyStats is the proxy's part of the stats, see statsMessage. Address is where it listens,
// ip:port, and "" while it doesn't: off, or not listening yet. Open is its client connections. Up
// and Down are its bytes in this run, the same bytes as the totals.
type proxyStats struct {
	Address string `json:"address"`
	Paused  bool   `json:"paused"`
	Open    int    `json:"open"`
	Up      uint64 `json:"up"`
	Down    uint64 `json:"down"`
}

// proxyStatsLocked runs with s.mu held.
func (s *Server) proxyStatsLocked() proxyStats {
	p := s.proxy
	st := proxyStats{Paused: p.paused, Open: p.open, Up: p.counts.up.Load(), Down: p.counts.down.Load()}
	if p.run != nil && p.run.ln != nil {
		st.Address = p.run.at.String()
	}
	return st
}

// configProxy is the config message's "proxy". Missing is off and not paused.
type configProxy struct {
	On     bool `json:"on"`
	Paused bool `json:"paused"`
}
