// Package main is Tether's WireGuard server, built as a C archive and linked into the app.
//
// wireguard-go decrypts what the devices send, a gVisor userspace TCP/IP stack ends their TCP
// connections and UDP flows, and each one is made again with the iPhone's own sockets. So to the
// carrier it is all iPhone traffic, and nothing needs root or a
// network extension. exports.go is the C API the Swift side calls.
package main

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
	"gvisor.dev/gvisor/pkg/waiter"
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
	// 80 KB: copy buffers, three goroutines and gVisor's endpoint. So under 40 MB at the cap. A
	// browser stays well below it, a torrent client with a thousand peers reaches it and is
	// refused more.
	maxConns = 512
	// maxInFlight caps the TCP connections being dialed for all devices together, like gVisor's
	// own cap it replaces, see handleTCP.
	maxInFlight = 4096
	// handshakeEvery is how often the devices' last handshakes are read back from wireguard-go.
	// They come every 2 minutes, so more often only wakes the iPhone.
	handshakeEvery = 10 * time.Second
	// onlineWithin is how recent a device's last handshake must be for it to count as online.
	// WireGuard makes a new one every 2 minutes while packets flow, and the client config's
	// PersistentKeepalive keeps them flowing on an idle tunnel.
	onlineWithin = 3 * time.Minute
)

func init() {
	// iOS ends a background app that grows too big. The GC works harder near this instead.
	debug.SetMemoryLimit(192 << 20)
}

// Peer is one device: its public key and its address inside the tunnel.
type Peer struct {
	PublicKey [32]byte
	Address   netip.Addr
}

// routedNets are the addresses a router may send from besides its own: the private ranges a travel
// router gives its clients, for one that doesn't rewrite them to its tunnel address. Nothing says
// which device is a router. The first time wireguard-go drops a device's packet for its source
// address, that device gets these ranges, see noticeRouter. wireguard-go gives each range to one
// peer only, so there is one router at a time: the newest one that sent for others. Its traffic is
// the router's, since Tether can't tell the devices behind it apart. The tunnel's own addresses
// are left out, or a reply to a removed device's address would go to the router.
var routedNets = append(without(netip.MustParsePrefix("10.0.0.0/8"), tunnelNet),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("fd00::/8"), // IPv6 private addresses. TCP only, like all IPv6, see udp.go
)

// without splits p into the prefixes that cover it all but hole, since wireguard-go's allowed IPs
// can't leave a hole. Both are IPv4, and hole is inside p.
func without(p, hole netip.Prefix) []netip.Prefix {
	if p == hole {
		return nil
	}
	// Each half of p: the one without hole is kept whole, the other is split again.
	bits := p.Bits() + 1
	lo := netip.PrefixFrom(p.Addr(), bits)
	hiAddr := p.Addr().AsSlice()
	hiAddr[p.Bits()/8] |= 0x80 >> (p.Bits() % 8)
	hi := netip.PrefixFrom(netip.AddrFrom4([4]byte(hiAddr)), bits)
	if lo.Contains(hole.Addr()) {
		return append(without(lo, hole), hi)
	}
	return append([]netip.Prefix{lo}, without(hi, hole)...)
}

type Stats struct {
	Up   uint64 `json:"up"`
	Down uint64 `json:"down"`
	// Connected holds the tunnel addresses with a recent handshake, so the app can say which
	// WireGuard device is set up and working, also before it sent any traffic.
	Connected []string `json:"connected"`
}

type Server struct {
	dev   *device.Device
	stack *stack.Stack
	tun   *stackTun
	// dial makes the iPhone-side TCP connection. toNet and fromNet translate UDP addresses on
	// the way out and back. Tests swap all three to reach listeners on loopback.
	dial    func(network, address string) (net.Conn, error)
	toNet   func(netip.AddrPort) netip.AddrPort
	fromNet func(netip.AddrPort) netip.AddrPort
	ipID    atomic.Uint32 // IPv4 identification for the UDP replies udp.go builds
	// up and down are the byte totals. Atomic, since every read and write of every connection
	// adds to them, and a lock there would make them all take turns.
	up, down atomic.Uint64
	now      func() time.Time // tests move the clock to age a handshake

	// The handshake refresher, and SetPeers, read wireguard-go's status. Nothing on the packet path
	// does, since that would wait on wireguard-go's config lock, which Close and SetPeers hold
	// while they wait for the packet path to stop. reading keeps the two reads in order.
	stop    chan struct{}
	found   chan struct{} // asks the refresher to look at candidate
	shake   chan struct{} // asks the refresher to read the handshakes now, see noticeHandshake
	stopped sync.WaitGroup
	reading sync.Mutex
	// applying keeps changes to wireguard-go's peers in order: SetPeers from Swift, and the
	// refresher making a newly found router.
	applying sync.Mutex

	mu     sync.Mutex
	peers  map[[32]byte]netip.Addr // public key -> tunnel address
	names  map[string]netip.Addr   // wireguard-go's name for a peer -> tunnel address, see peerName
	router netip.Addr              // the router's tunnel address, invalid without one
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
	refused      netip.Addr
	refusedAt    time.Time
	shaken       map[netip.Addr]time.Time              // tunnel address -> when its last handshake was
	flows        map[netip.Addr]map[io.Closer]struct{} // open connections, to close a removed device's
	cones        map[netip.AddrPort]*cone              // UDP, by device port, see udp.go
	conesOf      map[netip.Addr]int                    // how many cones each device has
	conesRunning sync.WaitGroup
	// arriving holds the TCP connections between their SYN and the end of their dial, see
	// handleTCP. dials and conns count each device's, see maxDials and maxConns.
	forwarder *tcp.Forwarder
	arriving  map[stack.TransportEndpointID]*arrival
	dials     map[netip.Addr]int
	conns     map[netip.Addr]int
	// The caps, see the constants. Tests lower them.
	maxCones, maxDials, maxConns int
}

// arrival is a TCP connection a device asked for, from its SYN until its dial ends.
type arrival struct {
	owner  netip.Addr // whose connection it is, read when the SYN came in
	refuse bool       // nobody owns it, or its owner is at a cap. It isn't counted
	taken  bool       // a forwardTCP is making it
}

// Start listens for WireGuard on host:port with the server's private key. Peers come from SetPeers.
func Start(host netip.Addr, port int, privateKey [32]byte) (*Server, error) {
	s := &Server{
		peers:    map[[32]byte]netip.Addr{},
		names:    map[string]netip.Addr{},
		shaken:   map[netip.Addr]time.Time{},
		now:      time.Now,
		flows:    map[netip.Addr]map[io.Closer]struct{}{},
		cones:    map[netip.AddrPort]*cone{},
		conesOf:  map[netip.Addr]int{},
		arriving: map[stack.TransportEndpointID]*arrival{},
		dials:    map[netip.Addr]int{},
		conns:    map[netip.Addr]int{},
		maxCones: maxCones,
		maxDials: maxDials,
		maxConns: maxConns,
		// Go's default keepalive probes every idle connection every 15 s, which keeps the cellular
		// radio awake. Probing is still needed: when the device closes first, forwardTCP half-closes
		// and waits for the remote, so a remote that silently went away would hold it forever.
		dial: (&net.Dialer{Timeout: dialTimeout, KeepAliveConfig: net.KeepAliveConfig{
			Enable: true, Idle: 10 * time.Minute, Interval: 30 * time.Second, Count: 4,
		}}).Dial,
		toNet:   func(a netip.AddrPort) netip.AddrPort { return a },
		fromNet: func(a netip.AddrPort) netip.AddrPort { return a },
		stop:    make(chan struct{}),
		found:   make(chan struct{}, 1),
		shake:   make(chan struct{}, 1),
	}
	s.stack = stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	sack := tcpip.TCPSACKEnabled(true)
	s.stack.SetTransportProtocolOption(tcp.ProtocolNumber, &sack)
	// gVisor's defaults are 1 MB each way per connection. Smaller, auto-tuned buffers keep a page
	// with dozens of connections well inside a background app's memory.
	recv := tcpip.TCPReceiveBufferSizeRangeOption{Min: 4 << 10, Default: 256 << 10, Max: 2 << 20}
	send := tcpip.TCPSendBufferSizeRangeOption{Min: 4 << 10, Default: 256 << 10, Max: 2 << 20}
	moderate := tcpip.TCPModerateReceiveBufferOption(true)
	s.stack.SetTransportProtocolOption(tcp.ProtocolNumber, &recv)
	s.stack.SetTransportProtocolOption(tcp.ProtocolNumber, &send)
	s.stack.SetTransportProtocolOption(tcp.ProtocolNumber, &moderate)
	s.tun = newStackTun()
	if err := s.stack.CreateNIC(1, s.tun.ep); err != nil {
		return nil, fmt.Errorf("create NIC: %v", err)
	}
	// Take packets for any address and answer as that address: a transparent proxy.
	s.stack.SetPromiscuousMode(1, true)
	s.stack.SetSpoofing(1, true)
	s.stack.AddRoute(tcpip.Route{Destination: header.IPv4EmptySubnet, NIC: 1})
	s.stack.AddRoute(tcpip.Route{Destination: header.IPv6EmptySubnet, NIC: 1})
	// gVisor's own cap is above maxInFlight, so it never drops a SYN handleTCP has counted.
	s.forwarder = tcp.NewForwarder(s.stack, 0, 2*maxInFlight, s.forwardTCP)
	s.stack.SetTransportProtocolHandler(tcp.ProtocolNumber, s.handleTCP)
	s.stack.SetTransportProtocolHandler(udp.ProtocolNumber, s.handleUDP)

	logger := &device.Logger{Verbosef: s.notice, Errorf: device.NewLogger(device.LogLevelError, "wireguard: ").Errorf}
	s.dev = device.NewDevice(s.tun, &hostBind{host: host}, logger)
	if err := s.dev.IpcSet(fmt.Sprintf("private_key=%s\nlisten_port=%d\n", hex.EncodeToString(privateKey[:]), port)); err != nil {
		s.dev.Close()
		s.stack.Close()
		return nil, err
	}
	if err := s.dev.Up(); err != nil {
		s.dev.Close()
		s.stack.Close()
		return nil, err
	}
	s.stopped.Add(1)
	go s.refreshHandshakes()
	return s, nil
}

// Close stops the server. TCP connections end as the stack closes under them, UDP sockets are
// closed here, since they live outside the stack.
func (s *Server) Close() {
	close(s.stop)
	s.stopped.Wait()
	s.dev.Close() // closes the tun too
	s.stack.Close()
	s.mu.Lock()
	var cones []*cone
	for _, c := range s.cones {
		cones = append(cones, c)
	}
	s.mu.Unlock()
	for _, c := range cones {
		c.Close()
	}
	s.conesRunning.Wait() // closing the socket ends them at once
}

// SetPeers makes the allowed devices exactly these. Only the ones that changed are touched, so a
// device added or removed doesn't drop everyone else's session. A removed device's open
// connections are closed, so a device that gets its tunnel address later can't receive them.
func (s *Server) SetPeers(peers []Peer) error {
	want := map[[32]byte]netip.Addr{}
	for _, p := range peers {
		want[p.PublicKey] = p.Address
	}
	s.applying.Lock()
	defer s.applying.Unlock()
	// The router stays the router while its key keeps its address.
	s.mu.Lock()
	router := s.router
	for key, addr := range s.peers {
		if addr == router && want[key] != router {
			router = netip.Addr{}
		}
	}
	s.mu.Unlock()
	return s.apply(want, router)
}

// makeRouter gives the private ranges to the device at addr. It takes them from the router before
// only once that one is offline or has carried nothing for a client, so a device that sends for
// others by mistake can't cut off the devices behind a router in use.
func (s *Server) makeRouter(addr netip.Addr) {
	if !addr.IsValid() {
		return
	}
	s.readHandshakes() // the router's last handshake, fresh
	s.applying.Lock()
	defer s.applying.Unlock()
	s.mu.Lock()
	want := map[[32]byte]netip.Addr{}
	known := false
	for key, a := range s.peers {
		want[key] = a
		known = known || a == addr
	}
	at, shook := s.shaken[s.router]
	taken := s.router.IsValid() && s.router != addr && s.routed && shook && s.now().Sub(at) < onlineWithin
	already := s.router == addr
	s.mu.Unlock()
	if taken {
		s.mu.Lock()
		s.refused, s.refusedAt = addr, s.now()
		s.mu.Unlock()
		return
	}
	if known && !already {
		s.apply(want, addr)
	}
}

// notice is wireguard-go's verbose logger. Two of the things it says matter here, see
// noticeHandshake and noticeRouter. The rest is dropped.
func (s *Server) notice(format string, args ...any) {
	s.noticeHandshake(format)
	s.noticeRouter(format, args...)
}

// noticeHandshake has the refresher read the handshakes a second after the server answers one.
// By then the device's first packet has confirmed the session, which is when wireguard-go stamps
// it, so a new device shows as connected (and the QR code changes) without waiting for the next
// tick.
func (s *Server) noticeHandshake(format string) {
	if !strings.Contains(format, "Sending handshake response") {
		return
	}
	time.AfterFunc(time.Second, func() {
		select {
		case s.shake <- struct{}{}:
		default:
		}
	})
}

// noticeRouter looks for a dropped IPv4 packet: a device sent from an address that isn't its own,
// which only a router does for the devices behind it. wireguard-go names the device but not the
// address, so the log line's IP version is all there is to go on. IPv6 doesn't count: a Linux
// laptop routes IPv6 into the tunnel from its Wi-Fi address, since the client config sends ::/0
// there but gives it no IPv6 address. A router is found by its IPv4 clients, and the IPv6 ones in
// routedNets come with the role.
func (s *Server) noticeRouter(format string, args ...any) {
	if !strings.HasPrefix(format, "IPv4 packet with disallowed source address") || len(args) != 1 {
		return
	}
	name := fmt.Sprint(args[0])
	s.mu.Lock()
	addr := s.names[name]
	if !addr.IsValid() || addr == s.router || (addr == s.refused && s.now().Sub(s.refusedAt) < handshakeEvery) {
		s.mu.Unlock()
		return
	}
	s.candidate = addr
	s.mu.Unlock()
	// The packet path can't change wireguard-go's peers itself, so the refresher does it.
	select {
	case s.found <- struct{}{}:
	default:
	}
}

// setPeersLocked sets the peers and their names in wireguard-go's log together. Runs with s.mu held.
func (s *Server) setPeersLocked(peers map[[32]byte]netip.Addr) {
	s.peers = peers
	s.names = make(map[string]netip.Addr, len(peers))
	for key, addr := range peers {
		s.names[peerName(key)] = addr
	}
}

// peerName is how wireguard-go names a peer in its log: the start and end of its public key.
func peerName(key [32]byte) string {
	b := base64.StdEncoding.EncodeToString(key[:])
	return "peer(" + b[0:4] + "\u2026" + b[39:43] + ")"
}

// apply makes wireguard-go's peers want, with the private ranges going to router. Runs with
// s.applying held.
func (s *Server) apply(want map[[32]byte]netip.Addr, router netip.Addr) error {
	s.mu.Lock()
	have, wasRouter, wasRouted := s.peers, s.router, s.routed
	s.mu.Unlock()
	var b strings.Builder
	for key := range have {
		if _, ok := want[key]; !ok {
			fmt.Fprintf(&b, "public_key=%s\nremove=true\n", hex.EncodeToString(key[:]))
		}
	}
	for key, addr := range want {
		isRouter := addr == router
		if old, ok := have[key]; !ok || old != addr || (old == wasRouter) != isRouter {
			fmt.Fprintf(&b, "public_key=%s\nreplace_allowed_ips=true\nallowed_ip=%s\n", hex.EncodeToString(key[:]), netip.PrefixFrom(addr, addr.BitLen()))
			if isRouter {
				for _, n := range routedNets {
					fmt.Fprintf(&b, "allowed_ip=%s\n", n)
				}
			}
		}
	}
	// The new devices go in, and the flows of the ones that changed close, before wireguard-go
	// routes differently. Otherwise a reply on such a flow could go to whichever device takes over
	// its address, the router's ranges included. Packets from a device that is going no longer
	// get through from here, since owner no longer knows it.
	s.mu.Lock()
	s.setPeersLocked(want)
	s.router = router
	if router != wasRouter {
		s.routed = false
	}
	var closing []io.Closer
	for key, addr := range have {
		// A router that stops being one, or that another device takes over from, loses its
		// clients' connections too, or their UDP flows would still count as its own.
		if want[key] != addr || (addr == wasRouter && addr != router) {
			delete(s.shaken, addr)
			for c := range s.flows[addr] {
				closing = append(closing, c)
			}
		}
	}
	s.mu.Unlock()
	for _, c := range closing {
		c.Close()
	}
	if b.Len() > 0 {
		if err := s.dev.IpcSet(b.String()); err != nil {
			s.mu.Lock()
			s.setPeersLocked(have)
			s.router, s.routed = wasRouter, wasRouted
			s.mu.Unlock()
			return err
		}
	}
	s.readHandshakes()
	return nil
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

func (s *Server) refreshHandshakes() {
	defer s.stopped.Done()
	t := time.NewTicker(handshakeEvery)
	defer t.Stop()
	for {
		s.readHandshakes()
		select {
		case <-t.C:
		case <-s.shake:
		case <-s.found:
			s.mu.Lock()
			addr := s.candidate
			s.candidate = netip.Addr{}
			s.mu.Unlock()
			s.makeRouter(addr)
		case <-s.stop:
			return
		}
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
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	shaken := map[netip.Addr]time.Time{}
	for key, addr := range s.peers {
		if at, ok := handshakes[key]; ok {
			shaken[addr] = at
		}
	}
	s.shaken = shaken
}

// forwardable says whether a device may reach dst through the iPhone. The iPhone's own loopback,
// the tunnel's addresses, multicast and broadcast stay inside: an mDNS query from the iPad would
// otherwise become a flow spraying multicast from the iPhone.
func forwardable(dst netip.Addr) bool {
	return dst.IsValid() && !dst.IsLoopback() && !dst.IsMulticast() && !dst.IsUnspecified() &&
		!dst.IsLinkLocalUnicast() && dst != netip.AddrFrom4([4]byte{255, 255, 255, 255}) &&
		!tunnelNet.Contains(dst)
}

var tunnelNet = netip.MustParsePrefix("10.7.0.0/24")

// owner is the tunnel address whose traffic a packet from src is: its own for a device, the
// router's for a device behind it. wireguard-go only takes routedNets sources from the router, so
// no other device can send as one of its clients. Invalid when nobody may send from src: a device
// just removed, or a tunnel address no device has, which the router's ranges cover too. A flow from
// one would go to the device that gets that address later. Finding one of the router's clients
// marks the router as in use, see routed.
func (s *Server) owner(src netip.Addr) netip.Addr {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.ownerLocked(src)
}

func (s *Server) ownerLocked(src netip.Addr) netip.Addr {
	for _, addr := range s.peers {
		if addr == src {
			return src
		}
	}
	if s.router.IsValid() && !tunnelNet.Contains(src) {
		for _, n := range routedNets {
			if n.Contains(src) {
				s.routed = true
				return s.router
			}
		}
	}
	return netip.Addr{}
}

// track keeps a connection's sockets so SetPeers can close them. The returned func forgets them.
// ok is false when src no longer belongs to device: SetPeers changed the devices while the
// connection was being made, after it closed the ones it knew about.
func (s *Server) track(src, device netip.Addr, conns ...io.Closer) (untrack func(), ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ownerLocked(src) != device {
		return nil, false
	}
	return s.trackLocked(device, conns...), true
}

func (s *Server) trackLocked(device netip.Addr, conns ...io.Closer) (untrack func()) {
	set := s.flows[device]
	if set == nil {
		set = map[io.Closer]struct{}{}
		s.flows[device] = set
	}
	for _, c := range conns {
		set[c] = struct{}{}
	}
	return func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		for _, c := range conns {
			delete(s.flows[device], c)
		}
	}
}

// count adds n bytes to the totals.
func (s *Server) count(up bool, n int) {
	if up {
		s.up.Add(uint64(n))
	} else {
		s.down.Add(uint64(n))
	}
}

func addrPort(a tcpip.Address, port uint16) netip.AddrPort {
	ip, _ := netip.AddrFromSlice(a.AsSlice())
	return netip.AddrPortFrom(ip.Unmap(), port)
}

// handleTCP takes the TCP packets no open connection wanted, inline on wireguard-go's receive
// goroutine like handleUDP. A new connection's SYN is counted against its device's caps here,
// before gVisor's forwarder starts a goroutine for it, and its arrival is kept until forwardTCP's
// dial ends. A SYN sent again meanwhile finds it and isn't counted twice.
func (s *Server) handleTCP(id stack.TransportEndpointID, pkt *stack.PacketBuffer) bool {
	h := header.TCP(pkt.TransportHeader().Slice())
	if len(h) < header.TCPMinimumSize || h.Flags()&(header.TCPFlagSyn|header.TCPFlagAck) != header.TCPFlagSyn {
		return false // not a new connection, so the stack answers with a reset
	}
	s.mu.Lock()
	a, again := s.arriving[id]
	if !again {
		if len(s.arriving) >= maxInFlight {
			s.mu.Unlock()
			return true // dropped, and the device sends it again
		}
		owner := s.ownerLocked(addrPort(id.RemoteAddress, 0).Addr())
		a = &arrival{owner: owner}
		a.refuse = !owner.IsValid() || s.dials[owner] >= s.maxDials || s.conns[owner] >= s.maxConns
		if !a.refuse {
			s.dials[owner]++
			s.conns[owner]++
		}
		s.arriving[id] = a
	}
	s.mu.Unlock()
	if !s.forwarder.HandlePacket(id, pkt) {
		// A bad checksum. No goroutine was started for it.
		if !again {
			s.mu.Lock()
			s.dialed(id, a, false)
			s.mu.Unlock()
		}
		return false
	}
	return true
}

// dialed ends an arrival: its dial is over, and its connection is open when open is true, or gone.
// Runs with s.mu held.
func (s *Server) dialed(id stack.TransportEndpointID, a *arrival, open bool) {
	if s.arriving[id] == a {
		delete(s.arriving, id)
	}
	if a.refuse {
		return
	}
	release(s.dials, a.owner)
	if !open {
		release(s.conns, a.owner)
	}
}

// release takes one off a device's count, and forgets the device at none.
func release(counts map[netip.Addr]int, device netip.Addr) {
	counts[device]--
	if counts[device] <= 0 {
		delete(counts, device)
	}
}

// forwardTCP runs on its own goroutine: gVisor's TCP forwarder starts one per SYN handleTCP passes on.
func (s *Server) forwardTCP(r *tcp.ForwarderRequest) {
	id := r.ID()
	s.mu.Lock()
	a := s.arriving[id]
	mine := a != nil && !a.taken
	if mine {
		a.taken = true
	}
	s.mu.Unlock()
	if !mine {
		// A SYN sent again after the dial for it was refused, before its arrival was gone.
		r.Complete(true)
		return
	}
	// The arrival goes after Complete, so a SYN sent again in between still finds it.
	refuse := func() {
		r.Complete(true) // a reset, which is what the device would see from a refused port
		s.mu.Lock()
		s.dialed(id, a, false)
		s.mu.Unlock()
	}
	src := addrPort(id.RemoteAddress, 0).Addr()
	dst := addrPort(id.LocalAddress, id.LocalPort)
	if a.refuse || !forwardable(dst.Addr()) {
		refuse()
		return
	}
	out, err := s.dial("tcp", dst.String())
	if err != nil {
		refuse()
		return
	}
	var wq waiter.Queue
	ep, terr := r.CreateEndpoint(&wq)
	if terr != nil {
		out.Close()
		refuse()
		return
	}
	r.Complete(false)
	s.mu.Lock()
	s.dialed(id, a, true)
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		release(s.conns, a.owner)
		s.mu.Unlock()
	}()
	device := a.owner
	// A device that leaves the hotspot never closes its connections. Keepalive finds them.
	ep.SocketOptions().SetKeepAlive(true)
	idle, interval := tcpip.KeepaliveIdleOption(60*time.Second), tcpip.KeepaliveIntervalOption(15*time.Second)
	ep.SetSockOpt(&idle)
	ep.SetSockOpt(&interval)
	ep.SetSockOptInt(tcpip.KeepaliveCountOption, 4)
	in := gonet.NewTCPConn(&wq, ep)
	closeBoth := func() { in.Close(); out.Close() }
	untrack, ok := s.track(src, device, in, out)
	if !ok {
		closeBoth()
		return
	}
	defer untrack()
	var wg sync.WaitGroup
	wg.Add(2)
	// A clean end of one direction passes on as a half close. Anything else, a reset or keepalive
	// giving up, ends both, or the other direction could wait forever on a silent peer.
	go func() {
		defer wg.Done()
		if err := s.copy(out, in, true); err != io.EOF {
			closeBoth()
		} else if c, ok := out.(interface{ CloseWrite() error }); ok {
			c.CloseWrite()
		}
	}()
	go func() {
		defer wg.Done()
		if err := s.copy(in, out, false); err != io.EOF {
			closeBoth()
		} else {
			in.CloseWrite()
		}
	}()
	wg.Wait()
	closeBoth()
}

// copyBufs hold one direction of a TCP connection between a read and its write, each for as long as
// the connection is open. 16 KB is a dozen packets at the tunnel's MTU, and gVisor and the kernel
// buffer the rest of each direction, so a bigger one only costs memory. The pool reuses them across
// the many short connections a page makes.
var copyBufs = sync.Pool{New: func() any { return new([16 << 10]byte) }}

// copy moves one direction of a TCP connection and counts it, until an error. A clean end
// returns io.EOF.
func (s *Server) copy(dst io.Writer, src io.Reader, up bool) error {
	b := copyBufs.Get().(*[16 << 10]byte)
	defer copyBufs.Put(b)
	buf := b[:]
	for {
		n, err := src.Read(buf)
		if n > 0 {
			s.count(up, n)
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return werr
			}
		}
		if err != nil {
			return err
		}
	}
}

// stackTun is a tun.Device whose other end is the gVisor stack instead of the kernel.
type stackTun struct {
	ep       *channel.Endpoint
	events   chan tun.Event
	incoming chan *buffer.View
	done     chan struct{}
	once     sync.Once
}

func newStackTun() *stackTun {
	t := &stackTun{
		ep:       channel.New(queueLen, MTU, ""),
		events:   make(chan tun.Event, 1),
		incoming: make(chan *buffer.View, queueLen),
		done:     make(chan struct{}),
	}
	t.ep.AddNotify(t)
	t.events <- tun.EventUp
	return t
}

func (t *stackTun) File() *os.File           { return nil }
func (t *stackTun) Name() (string, error)    { return "tether", nil }
func (t *stackTun) MTU() (int, error)        { return MTU, nil }
func (t *stackTun) Events() <-chan tun.Event { return t.events }
func (t *stackTun) BatchSize() int           { return 1 }

// Close also closes events, which ends wireguard-go's goroutine that reads them.
func (t *stackTun) Close() error {
	t.once.Do(func() { close(t.done); close(t.events); t.ep.Close() })
	return nil
}

// Read hands wireguard-go the next packet the stack sends to a device.
func (t *stackTun) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	for {
		select {
		case v := <-t.incoming:
			n, _ := v.Read(bufs[0][offset:])
			v.Release()
			if n == 0 {
				continue // any error but ErrClosed would make wireguard-go shut the device down
			}
			sizes[0] = n
			return 1, nil
		case <-t.done:
			return 0, os.ErrClosed
		}
	}
}

// Write gives the stack the packets wireguard-go decrypted.
func (t *stackTun) Write(bufs [][]byte, offset int) (int, error) {
	for _, b := range bufs {
		p := b[offset:]
		if len(p) == 0 {
			continue
		}
		pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(p)})
		if p[0]>>4 == 6 {
			t.ep.InjectInbound(header.IPv6ProtocolNumber, pkt)
		} else {
			t.ep.InjectInbound(header.IPv4ProtocolNumber, pkt)
		}
		pkt.DecRef()
	}
	return len(bufs), nil
}

// WriteNotify runs when the stack has a packet for a device. When wireguard-go falls behind, the
// packet is dropped like on a real network card, so one busy connection can't stall the others.
func (t *stackTun) WriteNotify() {
	pkt := t.ep.Read()
	if pkt == nil {
		return
	}
	v := pkt.ToView()
	pkt.DecRef()
	select {
	case t.incoming <- v:
	default:
		v.Release()
	}
}
