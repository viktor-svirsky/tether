// Package main is Tether's WireGuard server, built as a C archive and linked into the app.
//
// wireguard-go decrypts what the devices send, a gVisor userspace TCP/IP stack ends their TCP
// connections and UDP flows, and each one is made again with the iPhone's own sockets. So to the
// carrier it is all iPhone traffic, and nothing needs root or a
// network extension. exports.go is the C API the Swift side calls.
package main

import (
	"bufio"
	"context"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.zx2c4.com/wireguard/device"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/icmp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

// MTU matches the MTU line in the client config Swift writes. The hotspot's Wi-Fi and USB carry
// 1500 bytes, and WireGuard adds 80 at most (IPv6, UDP, its own header), which leaves 1420.
// Devices set up when this was 1280 keep 1280 in their config. Their TCP still works, since each
// SYN asks for segments that fit the device's own MTU.
const MTU = 1420

// queueLen is how many packets wait between the stack and wireguard-go, both ways. Past it a
// packet is dropped, like on a real network card.
const queueLen = 1024

const (
	dialTimeout = 10 * time.Second
	udpIdle     = 60 * time.Second
	// dnsIdle is for a cone that has only sent DNS lookups. A lookup takes a new port every time,
	// so with a minute each, browsing would keep hundreds of sockets open.
	dnsIdle = 10 * time.Second
	// The caps below are per device, a router and the devices behind it counting as one, so one
	// busy or misbehaving device can't use up what the others need. The budget is SetMemoryLimit's
	// 192 MB, which a few devices at their caps together must stay inside.
	//
	// maxCones caps a device's UDP sockets, about 70 KB each with their buffers, so 18 MB at the
	// cap. A lookup takes a port for dnsIdle, so a busy browser keeps a few dozen. Past it a new
	// port of that device's gets nothing, and the other devices keep theirs, DNS included.
	maxCones = 256
	// maxDials caps a device's TCP connections still being dialed, each up to dialTimeout. A page
	// load asks for a hundred or so at once, and they're done within a round trip. A port scan
	// against hosts that drop SYNs fills it, and its device's next ones are refused.
	maxDials = 256
	// maxConns caps a device's TCP connections, open or being dialed. An idle one measured under
	// 80 KB: copy buffers, three goroutines and gVisor's endpoint. So under 40 MB at the cap. One
	// whose device stopped taking data while the far end keeps sending holds its send buffer on
	// top: about 100 KB when it stalled cold, about 50 MB more at the cap. One that ran fast first
	// keeps the buffer it grew, which can reach the 2 MB send maximum (750 KB measured), since gVisor
	// doesn't shrink it (#149). A browser
	// stays well below it, a torrent client with a thousand peers reaches it and is refused more.
	maxConns = 512
	// maxInFlight caps the TCP connections being dialed for all devices together, like gVisor's
	// own cap it replaces, see handleTCP.
	maxInFlight = 4096
	// timeWaitTimeout is how long the device's side of a connection the far end closed first stays
	// in TIME_WAIT, where gVisor drops a new connection from the same device port. gVisor's 60 s is
	// for the internet. This side is the tunnel, with a round trip of milliseconds, and it ends
	// before the device sends its SYN again after a second.
	timeWaitTimeout = 500 * time.Millisecond
	// drainGrace is the longest a failed connection's other side keeps what's already on its way
	// to it before it's reset too, the way a direct connection would have delivered it. The far
	// end's side ends sooner, once the kernel says its queue is empty, see sendQueue. gVisor
	// doesn't say that for the device's side, which waits all of it. Its buffer is at most 2 MB,
	// about a second at hotspot speeds.
	drainGrace = 2 * time.Second
	// handshakeEvery is how often the devices' last handshakes are read back from wireguard-go.
	// They come every 2 minutes, so more often only wakes the iPhone.
	handshakeEvery = 10 * time.Second
	// onlineWithin is how recent a device's last handshake must be for it to count as online.
	// WireGuard makes a new one every 2 minutes while packets flow, and the client config's
	// PersistentKeepalive keeps them flowing on an idle tunnel.
	onlineWithin = 3 * time.Minute
	// sessionOver is how long without a handshake the server watched before it closes a device's
	// connections: WireGuard's sessions last 3 minutes, plus room for a late rekey (#149).
	sessionOver = onlineWithin + 30*time.Second
	// localEvery is how often the iPhone's own addresses are read again, see refreshLocal. So a VPN
	// that comes up, or a new cellular address, is out of the devices' reach within it.
	localEvery = 5 * time.Second
	// pagePort is the config page's, ConfigPage.port in Swift. It listens where WireGuard does.
	pagePort = 80
)

func init() {
	// iOS ends a background app that grows too big. The GC works harder near this instead.
	debug.SetMemoryLimit(192 << 20)
}

// Stats are the server's counters and the devices with a recent handshake. statsMessage in
// boundary.go is what Swift gets.
type Stats struct {
	Up        uint64
	Down      uint64
	Connected []string // tunnel addresses
}

type Server struct {
	bind  *hostBind
	dev   *device.Device
	stack *stack.Stack
	tun   *stackTun
	// dial makes the iPhone-side TCP connection. toNet and fromNet translate UDP addresses on
	// the way out and back. Tests swap all three to reach listeners on loopback, and sendTo, which
	// sends a cone's packet or a lookup to a plain server, to fail as an iPhone without IPv4 does.
	dial    func(ctx context.Context, network, address string) (net.Conn, error)
	toNet   func(netip.AddrPort) netip.AddrPort
	fromNet func(netip.AddrPort) netip.AddrPort
	sendTo  func(c *net.UDPConn, payload []byte, to netip.AddrPort) error
	// nat64 reaches IPv4 addresses from an iPhone that has no IPv4 route, see nat64.go.
	nat64 nat64
	// pings are the devices' echo requests waiting for their replies, see icmp.go.
	pings pinger
	// ctx ends with Close, and the dials still being made end with it.
	ctx    context.Context
	cancel context.CancelFunc
	// heard sees each line wireguard-go logs. Tests set it to look at the server mid-change.
	heard atomic.Pointer[func(string)]
	ipID  atomic.Uint32 // IPv4 identification for the UDP and ping replies we build
	diag  diagnostics   // for the Diagnostics screen, see diagnostics.go
	// up and down are the byte totals. Atomic, since every read and write of every connection
	// adds to them, and a lock there would make them all take turns.
	up, down atomic.Uint64
	// now is the server's clock, and after runs f once d has passed on it, unless the func it
	// returns stops it first. Both are read without a lock, so start sets them and nothing changes
	// them after. Tests that age a handshake or a cone give start a clock they move.
	now   func() time.Time
	after func(d time.Duration, f func()) func() bool

	// The handshake refresher, and SetPeers, read wireguard-go's status. Nothing on the packet path
	// does, since that would wait on wireguard-go's config lock, which Close and SetPeers hold
	// while they wait for the packet path to stop. reading keeps the two reads in order.
	stop    chan struct{}
	found   chan struct{} // asks the refresher to look at candidate
	shake   chan struct{} // asks the refresher to read the handshakes now, see noticeHandshake
	dead    chan struct{} // asks the refresher to listen again, see reopen
	stopped sync.WaitGroup
	// reopened is when the refresher last tried to listen again, and retryAt when it tries next,
	// see retryIn. Only the refresher reads them.
	reopened, retryAt time.Time
	// closeOnce makes Close safe to call twice: close(stop) would panic.
	closeOnce sync.Once
	reading   sync.Mutex
	// applying keeps changes to wireguard-go's peers in order: SetPeers from Swift, and the
	// refresher making a newly found router.
	applying sync.Mutex

	// mu guards the fields below and sits on the UDP path both ways. That works because every
	// section under it is short. The walk over the peers for each packet is the first place it may
	// cost something, not measured (#156).
	mu     sync.Mutex
	peers  map[[32]byte]netip.Addr // public key -> tunnel address
	keys   map[netip.Addr][32]byte // tunnel address -> public key
	names  map[string]netip.Addr   // wireguard-go's name for a peer -> tunnel address, see peerName
	paused map[[32]byte]bool       // the keys whose traffic is refused, see ownerLocked
	// logNames is names for keep, which reads it without s.mu, so a line wireguard-go logs inside
	// a call made with s.mu held can't wait on it. Each one is a new map, never changed after.
	logNames atomic.Value
	router   netip.Addr // the router's tunnel address, invalid without one
	// routed says a flow from one of the router's clients has started since it got the role. The
	// log line that makes a router doesn't say which address was dropped, so a device can get the
	// role with a packet from an address no client has, like a tunnel address that isn't its own.
	// Until it carries a client's flow it holds no claim, see makeRouter.
	routed bool
	// candidate is the latest device that sent for others, for the refresher to make the router.
	// The latest one is kept, so none is lost while the refresher is busy.
	candidate netip.Addr
	// refused is the last device kept from the router's role because the router was online, and
	// when. It isn't looked at again for handshakeEvery, so its dropped packets cost no status reads.
	refused   netip.Addr
	refusedAt time.Time
	shaken    map[netip.Addr]time.Time // tunnel address -> when its last handshake was
	// readAt is when readHandshakes last ran, and watchingSince when its reads started coming every
	// handshakeEvery again, after a suspension or a clock jump. See sessionOver.
	readAt, watchingSince time.Time
	endpoints             map[netip.Addr]string                 // tunnel address -> where it last connected from, ip:port
	received              map[netip.Addr]uint64                 // tunnel address -> wireguard-go's rx_bytes, keepalives too
	knocks                knocks                                // handshakes from configs that no longer work, see stale.go
	traffic               map[netip.Addr]*traffic               // each device's bytes, see trafficOfLocked
	flows                 map[netip.Addr]map[io.Closer]struct{} // open connections, to close a removed, paused or gone device's
	cones                 map[netip.AddrPort]*cone              // UDP, by device port, see udp.go
	conesOf               map[netip.Addr]int                    // how many cones each device has
	conesRunning          sync.WaitGroup
	// arriving holds the TCP connections between their SYN and the end of their dial, see
	// handleTCP. dials and conns count each device's, see maxDials and maxConns.
	forwarder *tcp.Forwarder
	arriving  map[stack.TransportEndpointID]*arrival
	dials     map[netip.Addr]int
	conns     map[netip.Addr]int
	// syns keeps a SYN's arrival and gVisor's take on it together, apart from a forwardTCP that
	// finds no arrival of its own and hands gVisor's slot back, see forwardTCP.
	syns sync.Mutex
	// The caps, see the constants. Tests lower them.
	maxCones, maxDials, maxConns, maxPings, maxLookups int
	// keepIdle and keepInterval are the keepalive on the devices' side of TCP, see forwardTCP.
	// Tests shorten them.
	keepIdle, keepInterval time.Duration
	// DNS on 10.7.0.1, see dns.go. Tests swap dohClient, dohSpare, lookupTimeout and plainTimeout.
	upstream  atomic.Pointer[dnsUpstream]
	dohClient *http.Client
	// dohSpare asks again next to a slow request, on a new connection each time, see doh.
	dohSpare      *http.Client
	lookupTimeout time.Duration
	plainTimeout  time.Duration
	dnsFailing    atomic.Bool        // see dnsResult
	lookups       map[netip.Addr]int // each device's UDP lookups waiting, see maxLookups
	// looking counts the UDP lookups and DNS-over-TCP connections, for Close to wait for.
	looking sync.WaitGroup
	// local is the iPhone's own addresses, which no device reaches, see refreshLocal. The packet
	// path reads it without a lock. listAddrs lists them, and tests swap it. listing keeps two reads
	// from storing out of order.
	local     atomic.Pointer[map[netip.Addr]struct{}]
	listAddrs func() ([]net.Addr, error)
	// onLink is the networks the iPhone is on, read with local. blockLocal is the Block setting,
	// read on the packet path without a lock and set under mu, see SetBlockLocal. tcpTo is where each
	// open TCP connection Block covers goes, by its sockets, under mu: a destination can become local
	// later, when the iPhone joins its network, so Block and refreshLocal check them all.
	onLink     atomic.Pointer[[]netip.Prefix]
	blockLocal atomic.Bool
	tcpTo      map[io.Closer]netip.Addr
	listing    sync.Mutex
	// page is where Tether's config page listens, see SetPage. A device whose tunnel works opens it
	// through the tunnel, so it's the one own address that stays reachable, over TCP only. The
	// packet path reads it without a lock.
	page atomic.Pointer[[]netip.AddrPort]
	// closed is set by Close. From then on handleTCP, track and cone let nothing new in.
	closed bool
	// forwarding counts the forwardTCP goroutines handleTCP let in, for Close to wait for.
	forwarding sync.WaitGroup
	// proxy is the HTTP proxy for devices without WireGuard, see proxy.go.
	proxy *proxy
}

// arrival is a TCP connection a device asked for, from its SYN until its dial ends.
type arrival struct {
	owner  netip.Addr // whose connection it is, read when the SYN came in
	key    [32]byte   // the owner's key then, see track
	refuse bool       // nobody owns it, or its owner is at a cap. It isn't counted
	taken  bool       // a forwardTCP is making it
}

// Start listens for WireGuard on port at each of hosts, with the server's private key. An address
// that can't be listened on fails it, and so does a failed first read of the iPhone's own
// addresses. Peers come from SetPeers.
func Start(hosts []netip.Addr, port int, privateKey [32]byte) (*Server, error) {
	return start(hosts, port, privateKey, net.InterfaceAddrs, time.Now, afterFunc)
}

// start is Start with the iPhone's own addresses read by listAddrs, and the clock now and after.
// Tests give a listAddrs that fails, and a clock they move.
func start(hosts []netip.Addr, port int, privateKey [32]byte, listAddrs func() ([]net.Addr, error), now func() time.Time, after func(time.Duration, func()) func() bool) (*Server, error) {
	// Go's default keepalive probes every idle connection every 15 s, which keeps the cellular
	// radio awake. Probing is still needed: when the device closes first, forwardTCP half-closes
	// and waits for the remote, so a remote that silently went away would hold it forever.
	dialer := &net.Dialer{Timeout: dialTimeout, KeepAliveConfig: net.KeepAliveConfig{
		Enable: true, Idle: 10 * time.Minute, Interval: 30 * time.Second, Count: 4,
	}}
	s := &Server{
		peers:     map[[32]byte]netip.Addr{},
		keys:      map[netip.Addr][32]byte{},
		names:     map[string]netip.Addr{},
		shaken:    map[netip.Addr]time.Time{},
		endpoints: map[netip.Addr]string{},
		knocks:    newKnocks(),
		traffic:   map[netip.Addr]*traffic{},
		now:       now,
		after:     after,
		flows:     map[netip.Addr]map[io.Closer]struct{}{},
		tcpTo:     map[io.Closer]netip.Addr{},
		cones:     map[netip.AddrPort]*cone{},
		conesOf:   map[netip.Addr]int{},
		arriving:  map[stack.TransportEndpointID]*arrival{},
		dials:     map[netip.Addr]int{},
		conns:     map[netip.Addr]int{},
		maxCones:  maxCones,
		maxDials:  maxDials,
		maxConns:  maxConns,
		maxPings:  maxPings,
		dial:      dialer.DialContext, // see dialer above
		toNet:     func(a netip.AddrPort) netip.AddrPort { return a },
		fromNet:   func(a netip.AddrPort) netip.AddrPort { return a },
		sendTo: func(c *net.UDPConn, payload []byte, to netip.AddrPort) error {
			_, err := c.WriteToUDPAddrPort(payload, to)
			return err
		},
		stop:      make(chan struct{}),
		found:     make(chan struct{}, 1),
		shake:     make(chan struct{}, 1),
		dead:      make(chan struct{}, 1),
		listAddrs: listAddrs,
	}
	s.proxy = newProxy()
	s.page.Store(&[]netip.AddrPort{})
	s.local.Store(&map[netip.Addr]struct{}{})
	s.onLink.Store(&[]netip.Prefix{})
	// Before any device's packet can come in. Without it every own address is open, so a failed
	// read fails the start and Swift tries again on its next round. Nothing is running yet.
	if err := s.refreshLocal(); err != nil {
		return nil, fmt.Errorf("can't read the iPhone's own addresses: %v", err)
	}
	s.ctx, s.cancel = context.WithCancel(context.Background())
	s.lookups, s.maxLookups = map[netip.Addr]int{}, maxLookups
	// A lookup's DoH dial is held like its other sockets, so a pause waits for it too, see holdDial.
	// Through s.dial, which is dialer.DialContext but for tests.
	dohDial := func(ctx context.Context, network, address string) (net.Conn, error) {
		return holdDial(ctx, func(ctx context.Context) (net.Conn, error) { return s.dial(ctx, network, address) })
	}
	s.dohClient, s.dohSpare, s.lookupTimeout = newDoHClient(dohDial), newDoHSpare(dohDial), lookupTimeout
	s.plainTimeout = plainTimeout
	// A device that leaves the hotspot is found in 2 minutes: 60 s idle, then 4 probes 15 s apart.
	s.keepIdle, s.keepInterval = 60*time.Second, 15*time.Second
	s.stack = stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol, icmp.NewProtocol4},
	})
	sack := tcpip.TCPSACKEnabled(true)
	s.stack.SetTransportProtocolOption(tcp.ProtocolNumber, &sack)
	// gVisor's defaults are 1 MB each way per connection. Smaller, auto-tuned buffers keep a page
	// with dozens of connections well inside a background app's memory, and a device at maxConns
	// whose connections stalled early too. A fast flow grows its own toward the max, see maxConns.
	recv := tcpip.TCPReceiveBufferSizeRangeOption{Min: 4 << 10, Default: 64 << 10, Max: 2 << 20}
	send := tcpip.TCPSendBufferSizeRangeOption{Min: 4 << 10, Default: 64 << 10, Max: 2 << 20}
	moderate := tcpip.TCPModerateReceiveBufferOption(true)
	s.stack.SetTransportProtocolOption(tcp.ProtocolNumber, &recv)
	s.stack.SetTransportProtocolOption(tcp.ProtocolNumber, &send)
	s.stack.SetTransportProtocolOption(tcp.ProtocolNumber, &moderate)
	timeWait := tcpip.TCPTimeWaitTimeoutOption(timeWaitTimeout)
	s.stack.SetTransportProtocolOption(tcp.ProtocolNumber, &timeWait)
	s.tun = newStackTun()
	s.tun.timeWait = s.synInTimeWait
	if err := s.stack.CreateNIC(1, s.tun.ep); err != nil {
		s.cancel()
		return nil, fmt.Errorf("create NIC: %v", err)
	}
	// Take packets for any address and answer as that address: a transparent proxy.
	s.stack.SetPromiscuousMode(1, true)
	s.stack.SetSpoofing(1, true)
	s.stack.AddRoute(tcpip.Route{Destination: header.IPv4EmptySubnet, NIC: 1})
	s.stack.AddRoute(tcpip.Route{Destination: header.IPv6EmptySubnet, NIC: 1})
	// gVisor's own cap is above maxInFlight, so it never drops a SYN handleTCP has counted.
	s.forwarder = tcp.NewForwarder(s.stack, 0, 2*maxInFlight, func(r *tcp.ForwarderRequest) { s.forwardTCP(r) })
	s.stack.SetTransportProtocolHandler(tcp.ProtocolNumber, s.handleTCP)
	s.stack.SetTransportProtocolHandler(udp.ProtocolNumber, s.handleUDP)
	s.stack.SetTransportProtocolHandler(icmp.ProtocolNumber4, s.handlePing)

	logger := &device.Logger{Verbosef: s.notice, Errorf: s.noticeError}
	s.bind = &hostBind{hosts: hosts, died: s.socketDied}
	s.dev = device.NewDevice(countingTun{s.tun, &s.diag.packetsIn}, s.bind, logger)
	if err := s.dev.IpcSet(fmt.Sprintf("private_key=%s\nlisten_port=%d\n", hex.EncodeToString(privateKey[:]), port)); err != nil {
		s.dev.Close()
		s.stack.Close()
		s.cancel()
		return nil, err
	}
	if err := s.dev.Up(); err != nil {
		s.dev.Close()
		s.stack.Close()
		s.cancel()
		return nil, err
	}
	s.stopped.Add(1)
	go s.refresh()
	return s, nil
}

// Close stops the server. Once it returns, no connection or UDP socket of a device's is left open
// on the iPhone's side: the open ones are closed here, the ones being made are refused and waited
// for, and their dials end at once. Calling it again does nothing.
func (s *Server) Close() { s.closeOnce.Do(s.close) }

// afterFunc is the real clock's after.
func afterFunc(d time.Duration, f func()) func() bool { return time.AfterFunc(d, f).Stop }

func (s *Server) close() {
	close(s.stop)
	s.stopped.Wait()
	s.mu.Lock()
	s.closed = true
	s.mu.Unlock()
	s.cancel()
	s.stopProxy() // after cancel, which ends its dials and NAT64 lookups, so it doesn't wait them out
	s.dev.Close() // closes the tun too
	s.stack.Close()
	s.closePings()
	// The open connections and cones close, and the connections being made stop waiting for their
	// device. The closed stack doesn't end a handshake that starts after a pass, so the passes go
	// on until every forwardTCP is done.
	done := make(chan struct{})
	go func() { s.forwarding.Wait(); close(done) }()
	for {
		s.mu.Lock()
		var open []io.Closer
		for _, set := range s.flows {
			for c := range set {
				open = append(open, c)
			}
		}
		s.mu.Unlock()
		for _, c := range open {
			c.Close()
		}
		select {
		case <-done:
			s.conesRunning.Wait() // closing the socket ends them at once
			s.looking.Wait()      // the cancelled context ends their requests
			s.dohNow().CloseIdleConnections()
			s.dohSpare.CloseIdleConnections()
			return
		case <-time.After(50 * time.Millisecond):
		}
	}
}

// notice is wireguard-go's verbose logger. A few of the things it says matter here, see
// noticeHandshake, noticeRouter and noticeStale, and the lines that say something go into the
// log Settings shares, see keep. Router detection, the fast handshake refresh and stale-config
// detection all match wireguard-go's wording, so a wireguard-go upgrade that rewords a line breaks
// them without an error: check those strings when upgrading it (#156).
func (s *Server) notice(format string, args ...any) {
	if heard := s.heard.Load(); heard != nil {
		(*heard)(fmt.Sprintf(format, args...))
	}
	s.noticeHandshake(format)
	s.noticeRouter(format, args...)
	s.noticeStale(format, args...)
	s.diag.heard(format)
	s.keep("", format, args)
}

// noticeHandshake has the refresher read the handshakes a second after the server answers one.
// By then the device's first packet has confirmed the session, which is when wireguard-go stamps
// it, so a new device shows as connected (and the QR code changes) without waiting for the next
// tick.
func (s *Server) noticeHandshake(format string) {
	if !strings.Contains(format, "Sending handshake response") {
		return
	}
	s.after(time.Second, func() {
		select {
		case s.shake <- struct{}{}:
		default:
		}
	})
}

// Stats returns the traffic totals, which only grow, and the tunnel addresses of the devices with a
// recent handshake, also before they sent any traffic.
func (s *Server) Stats() Stats {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := Stats{Up: s.up.Load(), Down: s.down.Load(), Connected: []string{}}
	for addr, at := range s.shaken {
		if s.now().Sub(at) < onlineWithin {
			st.Connected = append(st.Connected, addr.String())
		}
	}
	return st
}

// refresh reads the handshakes and the iPhone's own addresses again on their tickers, and makes a
// newly found router, until Close.
func (s *Server) refresh() {
	defer s.stopped.Done()
	t := time.NewTicker(handshakeEvery)
	defer t.Stop()
	local := time.NewTicker(localEvery)
	defer local.Stop()
	s.readHandshakes()
	for {
		select {
		case <-local.C:
			s.refreshLocal()
			continue // not a reason to read the handshakes
		case <-t.C:
		case <-s.shake:
		case <-s.found:
			s.mu.Lock()
			addr := s.candidate
			s.candidate = netip.Addr{}
			s.mu.Unlock()
			s.makeRouter(addr)
		case <-s.dead:
			s.reopen()
		case <-s.stop:
			return
		}
		s.readHandshakes()
	}
}

// readHandshakes reads each peer's last handshake from wireguard-go's status text. The map is
// built from the peers as they are when it's published, so a removed device never comes back from
// an old read.
func (s *Server) readHandshakes() {
	s.reading.Lock()
	defer s.reading.Unlock()
	status, err := s.dev.IpcGet()
	if err != nil {
		return
	}
	handshakes := map[[32]byte]time.Time{}
	endpoints := map[[32]byte]string{}
	received := map[[32]byte]uint64{}
	var key [32]byte
	sc := bufio.NewScanner(strings.NewReader(status))
	for sc.Scan() {
		k, v, _ := strings.Cut(sc.Text(), "=")
		switch k {
		case "public_key":
			b, _ := hex.DecodeString(v)
			copy(key[:], b)
		case "last_handshake_time_sec":
			// 0 until the first handshake. The nanoseconds line after it doesn't matter at minutes.
			if sec, err := strconv.ParseInt(v, 10, 64); err == nil && sec > 0 {
				handshakes[key] = time.Unix(sec, 0)
			}
		case "endpoint":
			endpoints[key] = v
		case "rx_bytes":
			if n, err := strconv.ParseUint(v, 10, 64); err == nil {
				received[key] = n
			}
		}
	}
	s.mu.Lock()
	shaken := map[netip.Addr]time.Time{}
	where := map[netip.Addr]string{}
	rx := map[netip.Addr]uint64{}
	for key, addr := range s.peers {
		if at, ok := handshakes[key]; ok {
			shaken[addr] = at
		}
		if ep, ok := endpoints[key]; ok {
			where[addr] = ep
		}
		if n, ok := received[key]; ok {
			rx[addr] = n
		}
	}
	s.shaken = shaken
	s.endpoints = where
	s.received = rx
	// A device whose session ended can't take or send anything more, so its connections only hold
	// memory. Keepalive finds an idle one, but it waits while data waits for the device's ack, so a
	// device gone mid-download kept its connections and their full send buffers while gVisor resent
	// for minutes (#149). A live device that stopped reading still handshakes, so it keeps them.
	// Only time the server watched counts: after Tether was suspended, or the clock jumped, every
	// handshake looks old until the devices had a chance to make a new one. Handshake times are wall
	// clock only, so the gap is too: a monotonic reading would miss the wall clock jumping ahead, and
	// on Darwin it doesn't count the time the iPhone slept.
	now := s.now().Round(0)
	if now.Sub(s.readAt) > 2*handshakeEvery || now.Before(s.readAt) {
		s.watchingSince = now
	}
	s.readAt = now
	var closing []io.Closer
	var gone []string
	for addr, set := range s.flows {
		at, ok := shaken[addr]
		if at.Before(s.watchingSince) {
			at = s.watchingSince
		}
		if ok && now.Sub(at) > sessionOver && len(set) > 0 {
			gone = append(gone, fmt.Sprintf("%v (%d)", addr, len(set)))
			for c := range set {
				closing = append(closing, c)
			}
		}
	}
	s.mu.Unlock()
	for _, c := range closing {
		c.Close()
	}
	if len(gone) > 0 {
		s.notice("closed the connections of %s: no handshake for %v", strings.Join(gone, ", "), sessionOver)
	}
}

// count adds n bytes to the totals.
// count adds n bytes to the totals and to t, the counter of the device the flow belongs to. Each
// flow takes its device's counter when it starts, so counting takes no lock.
func (s *Server) count(t *traffic, up bool, n int) {
	if up {
		s.up.Add(uint64(n))
	} else {
		s.down.Add(uint64(n))
	}
	if t == nil {
		return
	}
	if up {
		t.up.Add(uint64(n))
	} else {
		t.down.Add(uint64(n))
	}
}

// traffic is one device's bytes, the same ones the totals count. It's kept while the device keeps
// its address, so a device that leaves, or another one given its address, starts from zero.
type traffic struct{ up, down atomic.Uint64 }

// trafficOfLocked is the device's counter, made the first time. A flow of a device that's gone
// gets one of its own that nothing keeps, so a device given that address later doesn't inherit it.
func (s *Server) trafficOfLocked(owner netip.Addr) *traffic {
	if _, ok := s.keys[owner]; !ok {
		return &traffic{}
	}
	t := s.traffic[owner]
	if t == nil {
		t = &traffic{}
		s.traffic[owner] = t
	}
	return t
}

func (s *Server) trafficOf(owner netip.Addr) *traffic {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.trafficOfLocked(owner)
}
