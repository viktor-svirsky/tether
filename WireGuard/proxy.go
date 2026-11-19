package main

// An HTTP proxy for devices without WireGuard (#78). A device on the hotspot sets 172.20.10.1:8118
// as the proxy in its Wi-Fi settings, and the proxy makes each of its connections again from the
// iPhone, so to the carrier it's iPhone traffic, as a tunnel device's is. It takes CONNECT for
// HTTPS and plain http:// requests, which covers browsers and most apps. UDP, pings and apps that
// ignore the system proxy still go out as hotspot traffic, so WireGuard stays the whole-device way.
//
// There's no password: the proxy fields of Android, Windows and PlayStation have no login, so one
// would lock most devices out. Only the hotspot's clients are served, and the hotspot has its own
// password. It listens on 172.20.10.1, and on the hotspot's IPv6 address too: on a carrier that
// gives the iPhone IPv6 only, a Mac, an iPhone or an iPad on the hotspot takes no IPv4 address.
// That address is the iPhone's global one, so there only clients in the hotspot's own IPv6 network
// are served, see hotspotNet6.
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
	"syscall"
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
	// proxyGoneCheck is how often a tunnel whose client half-closed asks whether the client is still
	// there, see relay. Keepalive takes two minutes to give up anyway.
	proxyGoneCheck = 15 * time.Second
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
	// Read when the proxy turns on, and at and port6 each time it listens. Tests swap them, under s.mu.
	at                netip.AddrPort // where it listens on IPv4. Invalid is the hotspot's address on proxyPort
	port6             uint16         // its port on the hotspot's IPv6 address
	clients           netip.Prefix   // whom it serves on IPv4. On IPv6 it's the hotspot's network, see hotspotNet6
	systemLookup      func(ctx context.Context, host string) ([]netip.Addr, error)
	retry             time.Duration
	goneCheck         time.Duration
	maxConns          int
	handshake         time.Duration
	maxLookups        int // the proxy's name lookups at once, for all its devices, like a device's maxLookups
	maxDials          int // plain requests' dials at once, for all its devices, like a device's maxDials
	maxDialsPerClient int // one device's share of maxDials, like maxPerClient
	maxPerClient      int
	listen            func(ctx context.Context, address string) (net.Listener, error)

	// counts is the proxy's bytes, the same ones the totals count.
	counts traffic

	run       *proxyRun // nil while it's off
	paused    bool
	open      int                // client connections, see maxConns
	openBy    map[netip.Addr]int // each client's, see maxPerClient
	lookups   int                // lookups still running, also ones whose client gave up
	dials     int                // plain requests' dials still running, also ones whose client gave up
	dialsBy   map[netip.Addr]int // each client's, see maxDialsPerClient
	refusedAt time.Time          // when a refusal was last logged, so a busy client can't fill the log

	// served is when the far end last answered each client, see markServed.
	served map[netip.Addr]time.Time
}

func newProxy() *proxy {
	return &proxy{
		port6:   proxyPort,
		clients: hotspotNet,
		systemLookup: func(ctx context.Context, host string) ([]netip.Addr, error) {
			return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		},
		retry:             proxyRetry,
		goneCheck:         proxyGoneCheck,
		maxConns:          maxProxyConns,
		maxPerClient:      maxProxyPerClient,
		maxLookups:        maxLookups,
		maxDials:          maxDials,
		maxDialsPerClient: maxDials / 2,
		handshake:         proxyHandshake,
		openBy:            map[netip.Addr]int{},
		served:            map[netip.Addr]time.Time{},
		dialsBy:           map[netip.Addr]int{},
		listen: func(ctx context.Context, address string) (net.Listener, error) {
			// The keepalive of a tunnel device's side, see Start: a device that leaves the hotspot
			// never closes its connections.
			lc := net.ListenConfig{KeepAliveConfig: net.KeepAliveConfig{Enable: true, Idle: 60 * time.Second, Interval: 15 * time.Second, Count: 4}}
			return lc.Listen(ctx, "tcp", address) // one family, the address's
		},
	}
}

// proxyRun is the proxy from on to off: its listeners, kept listening, and the requests it serves.
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
	goneCheck    time.Duration
	socks        [2]*proxySocket // IPv4's, then IPv6's
	// Under s.mu.
	stopped  bool
	handlers sync.WaitGroup // added to under s.mu while not stopped, see enter
}

// proxySocket is the proxy's listener on one family's hotspot address, which follows the address.
type proxySocket struct {
	r    *proxyRun
	v6   bool
	done chan struct{} // closed when serve returns
	wake chan struct{} // asks serve to listen again now, see wakeProxy
	// Only serve's goroutine, which Serve's Accept runs on, reads them. working says an Accept
	// succeeded since it last listened, and down that a failure was logged since it last worked.
	working, down bool
	// Under s.mu. host is the hotspot address it listens on, or tries to, invalid when there's
	// none. at is where, with the port it got once it listened. clients is whom it serves on IPv6,
	// read each time it listens. moving says wakeProxy closed ln, see there.
	host    netip.Addr
	at      netip.AddrPort
	clients netip.Prefix
	ln      net.Listener // nil while not listening
	moving  bool

	cantListen bool // under s.mu too: its last try to listen on host failed
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

// hotspotHost6 is the hotspot's IPv6 address among the server's hosts: the server listens on one
// only on a carrier that gives the iPhone IPv6 only. Never a link-local one, which a proxy field
// can't take. Loopback is only ever the tests'.
func hotspotHost6(hosts []netip.Addr) (netip.Addr, bool) {
	for _, h := range hosts {
		if h.Is6() && !h.Is4In6() && h.Zone() == "" && (h.IsGlobalUnicast() || h.IsLoopback()) {
			return h, true
		}
	}
	return netip.Addr{}, false
}

// inHotspotNet6 says whether from is in the hotspot's IPv6 network n. Link-local clients aren't.
func inHotspotNet6(n netip.Prefix, from netip.Addr) bool {
	return n.IsValid() && from.Is6() && from.Zone() == "" && !from.IsLinkLocalUnicast() && n.Contains(from)
}

// proxyWant is where the proxy should listen now on IPv4, or with v6 on IPv6: the hotspot's address
// of that family, invalid when it has none.
func (s *Server) proxyWant(v6 bool) netip.AddrPort {
	s.bind.mu.Lock()
	hosts := s.bind.hosts
	s.bind.mu.Unlock()
	s.mu.Lock()
	at, port6 := s.proxy.at, s.proxy.port6
	s.mu.Unlock()
	if v6 {
		if h, ok := hotspotHost6(hosts); ok {
			return netip.AddrPortFrom(h, port6)
		}
		return netip.AddrPort{}
	}
	if at.IsValid() {
		return at
	}
	if h, ok := hotspotHost(hosts); ok {
		return netip.AddrPortFrom(h, proxyPort)
	}
	return netip.AddrPort{}
}

// SetProxy turns the proxy on or off and pauses or resumes it. Swift sends it with every config,
// so only a change does anything. Paused, it ends the open connections, as a paused device's are,
// and answers new requests with 403. Off ends them too, and stops listening.
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
		// It listens once the hotspot has an address, see wakeProxy.
		_, ok4 := hotspotHost(hosts)
		_, ok6 := hotspotHost6(hosts)
		nowhere = !p.at.IsValid() && !ok4 && !ok6
		start = s.newProxyRun()
		p.run = start
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
	if nowhere {
		serverLog.add(time.Now(), "proxy: no hotspot address to listen on yet")
	}
	switch {
	case start != nil:
		for _, k := range start.socks {
			go k.serve()
		}
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
	r.srv.Close() // the listeners, and the connections still reading a request
	for _, k := range r.socks {
		<-k.done
	}
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

// newProxyRun makes a run. Runs with s.mu held.
func (s *Server) newProxyRun() *proxyRun {
	p := s.proxy
	r := &proxyRun{s: s, p: p, systemLookup: p.systemLookup, listen: p.listen, retry: p.retry, goneCheck: p.goneCheck}
	for i := range r.socks {
		r.socks[i] = &proxySocket{r: r, v6: i == 1, done: make(chan struct{}), wake: make(chan struct{}, 1)}
	}
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
			// The transport goes on dialing after the client leaves, for its pool, so the client's
			// slot doesn't hold these: they have their own cap.
			// The transport keeps the request's values, so the client is the one whose request started it.
			from, _ := ctx.Value(proxyClient{}).(netip.Addr)
			if err := s.takeDial(from); err != nil {
				return nil, err
			}
			c, err := r.dial(ctx, host, uint16(n), &p.counts)
			s.releaseDial(from)
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
		// A response came from the far end: the client is served, see markServed, and again while
		// its body comes.
		ModifyResponse: func(resp *http.Response) error {
			if from, ok := resp.Request.Context().Value(proxyClient{}).(netip.Addr); ok {
				r.s.markServed(from)
				if resp.StatusCode == http.StatusSwitchingProtocols {
					return nil // an upgrade's body is the connection, which ReverseProxy writes to
				}
				resp.Body = struct {
					io.Reader
					io.Closer
				}{r.s.servedReader(resp.Body, from), resp.Body}
			}
			return nil
		},
	}
	return r
}

// serve listens and serves until off or Close, and listens again on the same address when iOS
// closes the socket of a suspended app, so the devices' settings keep working. A failure is logged
// once, and the next line is when a client gets in again, so a hotspot that's off doesn't fill the
// log. The wait between tries doubles until a client gets in, since a socket that listens but can't
// accept isn't working either, and the server listening again (ListenOn) cuts it short. It follows
// the hotspot's address of its family, and waits while there's none, see wakeProxy.
func (k *proxySocket) serve() {
	defer close(k.done)
	r, s := k.r, k.r.s
	wait := r.retry
	var announced netip.Addr // the address "listening on" was last logged for
	for {
		want := s.proxyWant(k.v6)
		s.mu.Lock()
		if want.Addr() != k.host {
			k.host, k.at = want.Addr(), want
		}
		host, at := k.host, k.at // on the same address, the port it got before
		k.moving = false
		if !at.IsValid() {
			k.cantListen = false // nowhere to listen is no failure
		}
		list := s.listAddrs
		s.mu.Unlock()
		if !at.IsValid() {
			select {
			case <-r.ctx.Done():
				return
			case <-k.wake:
				wait = r.retry
				continue
			}
		}
		if host != announced {
			k.down = false // a new address's failure is news
		}
		// On IPv6 whom it serves comes first: listening without it would refuse every client until the
		// socket failed, so a failed read waits and tries again, as a failed listen does.
		var clients netip.Prefix
		var ln net.Listener
		var err error
		if k.v6 {
			var addrs []net.Addr
			if addrs, err = list(); err == nil {
				clients, _ = hotspotNet6(addrs, host)
			} else {
				err = fmt.Errorf("can't read its network: %w", err)
			}
		}
		if err == nil {
			ln, err = r.listen(r.ctx, at.String())
		}
		if err == nil {
			s.mu.Lock()
			if r.stopped {
				s.mu.Unlock()
				ln.Close()
				return
			}
			bound := ln.Addr().(*net.TCPAddr).AddrPort()
			k.at = netip.AddrPortFrom(bound.Addr().Unmap(), bound.Port()) // the port too, for listening again
			k.ln, k.clients, k.cantListen = ln, clients, false
			s.mu.Unlock()
			// The address may have moved while it listened, before wakeProxy could see ln.
			if s.proxyWant(k.v6).Addr() != host {
				s.mu.Lock()
				k.ln = nil
				s.mu.Unlock()
				ln.Close()
				continue
			}
			if host != announced {
				announced = host
				serverLog.add(time.Now(), fmt.Sprintf("proxy listening on %v", ln.Addr()))
				if k.v6 && !clients.IsValid() {
					serverLog.add(time.Now(), fmt.Sprintf("proxy: %v isn't on a network of /64 or narrower, so it serves no IPv6 client", host))
				}
			}
			k.working = false
			err = r.srv.Serve(&proxyListener{ln, k})
			s.mu.Lock()
			k.ln = nil
			moved := k.moving
			s.mu.Unlock()
			if r.ctx.Err() != nil {
				return
			}
			if moved {
				wait = r.retry
				continue
			}
			if k.working {
				wait = r.retry
			}
			k.failed(fmt.Sprintf("proxy: its socket failed, listening again: %v", err))
		} else if r.ctx.Err() == nil {
			s.mu.Lock()
			k.cantListen = true
			s.mu.Unlock()
			k.failed(fmt.Sprintf("proxy: can't listen on %v: %v", at, err))
		}
		select {
		case <-r.ctx.Done():
			return
		case <-k.wake:
			wait = r.retry
			continue
		case <-time.After(wait):
		}
		wait = min(2*wait, proxyRetryMax)
	}
}

// failed logs text, unless a failure was logged already and no client got in since.
func (k *proxySocket) failed(text string) {
	if !k.down {
		k.down = true
		serverLog.add(time.Now(), text)
	}
}

// accepted notes a client got in: the socket works, and after a failure the log says so.
func (k *proxySocket) accepted() {
	k.working = true
	if k.down {
		k.down = false
		k.r.s.mu.Lock()
		at := k.at
		k.r.s.mu.Unlock()
		serverLog.add(time.Now(), fmt.Sprintf("proxy listening again on %v", at))
	}
}

// wakeProxy has the proxy follow the hotspot's addresses after the server listens again, see
// ListenOn: a socket whose address is gone or changed stops listening there, and each tries to
// listen now on its family's address, which may be back. A listener iOS closed is listened on again
// too, even on the same address: its Accept waits for good, so serve can't see it, while the
// devices are refused. closed says iOS closed the app's sockets, see reopen. Without it, the
// listener's own error says so, which is there even when the server missed the shutdown.
func (s *Server) wakeProxy(closed bool) {
	s.mu.Lock()
	r := s.proxy.run
	s.mu.Unlock()
	if r == nil {
		return
	}
	for _, k := range r.socks {
		want := s.proxyWant(k.v6)
		var old net.Listener
		var from netip.AddrPort
		s.mu.Lock()
		moved := want.Addr() != k.host
		if k.ln != nil && (moved || closed || socketError(k.ln) != nil) {
			old, from, k.moving = k.ln, k.at, true
		}
		s.mu.Unlock()
		if old != nil {
			if moved {
				serverLog.add(time.Now(), fmt.Sprintf("proxy stopped listening on %v: the hotspot's address changed", from))
			} else {
				serverLog.add(time.Now(), fmt.Sprintf("proxy: its socket was closed, listening again on %v", from))
			}
			old.Close()
		}
		select {
		case k.wake <- struct{}{}:
		default:
		}
	}
}

// proxyListener lets in only what admit does.
type proxyListener struct {
	net.Listener
	k *proxySocket
}

func (l *proxyListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		l.k.accepted()
		if pc, ok := l.k.r.admit(c, l.k); ok {
			return pc, nil
		}
	}
}

// admit keeps a new client connection to k, or closes it: one from off the hotspot, while off, and
// past the cap or the client's share of it. Paused, it keeps the connection, so ServeHTTP can say
// why nothing loads. A refusal from off the hotspot is logged once a minute at most.
func (r *proxyRun) admit(c net.Conn, k *proxySocket) (*proxyConn, bool) {
	s, p := r.s, r.p
	var from netip.Addr
	if a, ok := c.RemoteAddr().(*net.TCPAddr); ok {
		from = a.AddrPort().Addr().Unmap()
	}
	var refusal string
	s.mu.Lock()
	onHotspot := p.clients.Contains(from)
	if k.v6 {
		onHotspot = inHotspotNet6(k.clients, from)
	}
	ok := !r.stopped && !s.closed && onHotspot && p.open < p.maxConns &&
		p.openBy[from] < p.maxPerClient
	if !onHotspot && time.Since(p.refusedAt) > time.Minute {
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
	pc := &proxyConn{keptConn: keptConn{Conn: c}, from: from}
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
	from netip.Addr // the client, see markServed
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
	if r.paused() {
		w.Header().Set("Connection", "close")
		http.Error(w, "Tether paused this proxy. Resume it in Tether on the iPhone.", http.StatusForbidden)
		return
	}
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
		if a, err := netip.ParseAddrPort(req.RemoteAddr); err == nil {
			req = req.WithContext(context.WithValue(ctx, proxyClient{}, a.Addr().Unmap()))
		}
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

// paused is whether the proxy is paused.
func (r *proxyRun) paused() bool {
	r.s.mu.Lock()
	defer r.s.mu.Unlock()
	return r.p.paused
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

// lookupName asks Tether's DNS for host's IPv4 and IPv6 addresses, IPv4 first, so dial can try
// the other family when one doesn't answer. A lookup that fails, or is still out lookupGrace after
// the other found addresses, leaves the other's, and it's an error only when neither has any. dialTCP reaches an IPv4 one through NAT64 when the
// iPhone has no IPv4 route.
func (s *Server) lookupName(ctx context.Context, host string) ([]netip.Addr, error) {
	name, err := dnsmessage.NewName(strings.TrimSuffix(host, ".") + ".")
	if err != nil {
		return nil, err
	}
	var queries [2][]byte
	for i, t := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
		b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: uint16(rand.Uint32()), RecursionDesired: true})
		b.StartQuestions()
		if err := b.Question(dnsmessage.Question{Name: name, Type: t, Class: dnsmessage.ClassINET}); err != nil {
			return nil, err
		}
		if queries[i], err = b.Finish(); err != nil {
			return nil, err
		}
	}
	// Both at once, so the second family costs no extra round trip. Once one has addresses, the
	// other gets lookupGrace and no more: a server that never answers AAAA can't hold every name
	// up for the lookup's whole timeout. Ending ctx gives up the one still out.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	type answer struct {
		i     int
		addrs []netip.Addr
		err   error
	}
	answered := make(chan answer, len(queries))
	for i, q := range queries {
		go func() {
			a, err := s.resolveCtx(ctx, q)
			answered <- answer{i, addressesIn(a), err}
		}()
	}
	var addrs [2][]netip.Addr
	var errs [2]error
	var grace <-chan time.Time // nil, so never, until one family has addresses
wait:
	for range queries {
		select {
		case a := <-answered:
			addrs[a.i], errs[a.i] = a.addrs, a.err
			if len(a.addrs) > 0 && grace == nil {
				grace = time.After(lookupGrace)
			}
		case <-grace:
			break wait
		}
	}
	if all := slices.Concat(addrs[0], addrs[1]); len(all) > 0 {
		return all, nil
	}
	return nil, errors.Join(errs[0], errs[1])
}

// lookupGrace is how long lookupName waits for the other family once one has addresses: Happy
// Eyeballs' resolution delay, RFC 8305.
const lookupGrace = 50 * time.Millisecond

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

// errTooManyDials is a plain request's dial past the proxy's maxDials, which the client gets as 502.
var errTooManyDials = errors.New("too many dials at once")

// proxyClient is the context key of the client a plain request came from, see takeDial.
type proxyClient struct{}

// takeDial counts a plain request's dial from client from against the proxy's maxDials and the
// client's share of it, or refuses it at either cap.
func (s *Server) takeDial(from netip.Addr) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := s.proxy
	if p.dials >= p.maxDials || p.dialsBy[from] >= p.maxDialsPerClient {
		return errTooManyDials
	}
	p.dials++
	p.dialsBy[from]++
	return nil
}

func (s *Server) releaseDial(from netip.Addr) {
	s.mu.Lock()
	s.proxy.dials--
	release(s.proxy.dialsBy, from)
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
// one after what's already on its way to it. A client that half-closed and then left, asleep say,
// would leave only the far end's direction, which waits on the far end, so its socket's error,
// from keepalive giving up or a reset, is asked for now and then.
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
	farEndRead := make(chan struct{}) // closed once the far end's direction has ended
	var wg sync.WaitGroup
	wg.Go(func() {
		if err, writing := s.copy(out, in, counts, true, nil); err != io.EOF {
			fail(!writing)
			return
		}
		out.CloseWrite()
		tick := time.NewTicker(r.goneCheck)
		defer tick.Stop()
		for {
			select {
			case <-farEndRead:
				return
			case <-tick.C:
				if socketError(client.Conn) != nil {
					fail(true)
					return
				}
			}
		}
	})
	wg.Go(func() {
		defer close(farEndRead)
		farEnd := s.servedReader(out, client.from)
		if err, writing := s.copy(client, farEnd, counts, false, nil); err != io.EOF {
			fail(writing)
		} else {
			client.CloseWrite()
		}
	})
	wg.Wait()
	client.Close()
	out.Close()
}

// socketError is the error c's socket holds, from a reset or keepalive giving up, which a read
// would return, or iOS closing it. Nil while there's none, and for what has no socket.
func socketError(c any) error {
	t, ok := c.(syscall.Conn)
	if !ok {
		return nil
	}
	rc, err := t.SyscallConn()
	if err != nil {
		return err
	}
	var sockErr error
	if err := rc.Control(func(fd uintptr) {
		if n, err := syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_ERROR); err != nil {
			sockErr = err
		} else if n != 0 {
			sockErr = syscall.Errno(n)
		}
	}); err != nil {
		return err
	}
	return sockErr
}

// proxyStats is the proxy's part of the stats, see statsMessage. Addresses is where it listens,
// IPv4 first as ip:port, then IPv6 as [ip]:port, and empty while it doesn't: off, or no hotspot
// address yet. CantListen says it listens nowhere though it has an address to, its port taken say.
// Open is its client connections. Served is the clients the far end answered in the last
// servedFor, see markServed. Up and Down are its bytes in this run, the same bytes as the totals.
type proxyStats struct {
	Addresses  []string `json:"addresses"`
	Paused     bool     `json:"paused"`
	Open       int      `json:"open"`
	Served     []string `json:"served"`
	CantListen bool     `json:"cantListen"`
	Up         uint64   `json:"up"`
	Down       uint64   `json:"down"`
}

// proxyStatsLocked runs with s.mu held.
func (s *Server) proxyStatsLocked() proxyStats {
	p := s.proxy
	st := proxyStats{Addresses: []string{}, Paused: p.paused, Open: p.open, Served: []string{}, Up: p.counts.up.Load(), Down: p.counts.down.Load()}
	for a, at := range p.served {
		if s.now().Sub(at) > servedFor {
			delete(p.served, a)
			continue
		}
		st.Served = append(st.Served, a.String())
	}
	slices.Sort(st.Served)
	if p.run != nil {
		var cant bool
		for _, k := range p.run.socks {
			if k.ln != nil {
				st.Addresses = append(st.Addresses, k.at.String())
			}
			cant = cant || k.cantListen
		}
		st.CantListen = cant && len(st.Addresses) == 0 // devices still get in on the other family's
	}
	return st
}

// configProxy is the config message's "proxy". Missing is off and not paused.
type configProxy struct {
	On     bool `json:"on"`
	Paused bool `json:"paused"`
}

// markServed notes that the far end answered client from through the proxy: a response to a plain
// request, or a tunnel's bytes back. Add a device ticks its last step once a client that wasn't
// served lately is (#285): it can't go by the proxy's bytes or connections, which a TV already on
// the proxy moves too. A client drops out once it's had nothing for servedFor, so a device that
// comes back, or a new one on its address, counts as new again. Past maxServed clients, which an
// IPv6 hotspot's changing addresses could reach, the one served longest ago goes.
func (s *Server) markServed(from netip.Addr) {
	if !from.IsValid() {
		return
	}
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	served := s.proxy.served
	served[from] = now
	if len(served) > maxServed {
		var oldest netip.Addr
		for a, at := range served {
			if !oldest.IsValid() || at.Before(served[oldest]) {
				oldest = a
			}
		}
		delete(served, oldest)
	}
}

const (
	servedFor   = 2 * time.Minute
	servedEvery = 10 * time.Second // how often a long download or stream marks its client again
	maxServed   = 32
)

// servedReader is the far end of a client's request, which marks the client served when bytes
// come, at most every servedEvery.
func (s *Server) servedReader(r io.Reader, from netip.Addr) io.Reader {
	return &servedReading{Reader: r, mark: func() { s.markServed(from) }, now: s.now}
}

type servedReading struct {
	io.Reader
	mark func()
	now  func() time.Time
	last time.Time
}

func (r *servedReading) Read(b []byte) (int, error) {
	n, err := r.Reader.Read(b)
	if n > 0 {
		if now := r.now(); r.last.IsZero() || now.Sub(r.last) >= servedEvery {
			r.last = now
			r.mark()
		}
	}
	return n, err
}
