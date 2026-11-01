package main

import (
	"net"
	"net/netip"
	"slices"
	"sync"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/checksum"
	"gvisor.dev/gvisor/pkg/tcpip/header"
)

// Ping: a device's echo request goes out from the iPhone as a real one, and the real reply comes
// back, so a ping through the tunnel says what a ping from the iPhone would. stackTun.Write hands
// echo requests here before gVisor, which drops them, and replies are built like UDP's.
//
// iOS lets an app ping without privileges, through a datagram ICMP socket. Darwin keeps the
// identifier the app chose and hands such a socket every echo reply, so one socket serves every
// device: each request goes out with an identifier of its own, the reply is matched by it, and the
// device gets its own identifier back. IPv4 only, like the rest of the tunnel, and not through
// NAT64 (see nat64.go) yet.

const (
	// pingWait is how long a reply is waited for. ping itself gives up on one sooner.
	pingWait = 10 * time.Second
	// maxPings caps a device's requests waiting for a reply. ping sends one a second, so only a
	// flood reaches it, and the device's next ones are dropped until replies come or time runs out.
	maxPings = 64
)

type pinger struct {
	once  sync.Once
	conn  *icmp.PacketConn // nil when it couldn't be opened
	queue chan []byte
	// running counts the two goroutines, for Close to wait for.
	running sync.WaitGroup

	mu      sync.Mutex
	next    uint16
	waiting map[uint16]waitingPing // by the identifier the request went out with
	of      map[netip.Addr]int     // requests waiting, by owner
}

type waitingPing struct {
	device netip.Addr // where the request came from: a device's tunnel address or a router's client
	owner  netip.Addr // whose it is, see Server.owner
	dst    netip.Addr
	id     uint16 // the device's own identifier
	at     time.Time
}

// isEchoRequest says p is a whole IPv4 echo request. A fragment of one isn't: ping never sends one
// that big through a tunnel with this MTU.
func isEchoRequest(p []byte) bool {
	if len(p) < header.IPv4MinimumSize || p[0]>>4 != 4 {
		return false
	}
	ip := header.IPv4(p)
	if !ip.IsValid(len(p)) || ip.Protocol() != uint8(header.ICMPv4ProtocolNumber) || ip.More() || ip.FragmentOffset() != 0 {
		return false
	}
	m := header.ICMPv4(ip.Payload())
	return len(m) >= header.ICMPv4MinimumSize && m.Type() == header.ICMPv4Echo && m.Code() == 0
}

// queuePing runs on wireguard-go's receive goroutine, so it never blocks: the request waits for
// sendPings, or is dropped when too many do.
func (s *Server) queuePing(p []byte) {
	s.pings.once.Do(s.startPinging)
	if s.pings.conn == nil {
		return
	}
	select {
	case s.pings.queue <- slices.Clone(p):
	default:
	}
}

func (s *Server) startPinging() {
	s.mu.Lock()
	closed := s.closed
	s.mu.Unlock()
	if closed {
		return
	}
	conn, err := icmp.ListenPacket("udp4", "0.0.0.0")
	if err != nil {
		s.notice("ping: %v", err)
		return
	}
	s.pings.conn = conn
	s.pings.queue = make(chan []byte, 256)
	s.pings.waiting = map[uint16]waitingPing{}
	s.pings.of = map[netip.Addr]int{}
	s.pings.running.Add(2)
	go func() { defer s.pings.running.Done(); s.sendPings() }()
	go func() { defer s.pings.running.Done(); s.receivePings() }()
}

// closePings ends the goroutines. It's for Close, after the tunnel stopped writing.
func (s *Server) closePings() {
	s.pings.once.Do(func() {}) // none starts after this
	if s.pings.conn != nil {
		s.pings.conn.Close()
	}
	s.pings.running.Wait()
}

func (s *Server) sendPings() {
	for {
		select {
		case p := <-s.pings.queue:
			s.sendPing(p)
		case <-s.ctx.Done():
			return
		}
	}
}

func (s *Server) sendPing(p []byte) {
	ip := header.IPv4(p)
	src, dst := netip.AddrFrom4(ip.SourceAddress().As4()), netip.AddrFrom4(ip.DestinationAddress().As4())
	m := header.ICMPv4(ip.Payload())
	if !forwardable(dst) {
		return
	}
	owner := s.owner(src)
	if !owner.IsValid() {
		return
	}
	s.mu.Lock()
	limit := s.maxPings
	s.mu.Unlock()
	id, ok := s.pings.add(waitingPing{device: src, owner: owner, dst: dst, id: m.Ident(), at: time.Now()}, limit)
	if !ok {
		return
	}
	b, err := (&icmp.Message{Type: ipv4.ICMPTypeEcho, Body: &icmp.Echo{ID: int(id), Seq: int(m.Sequence()), Data: m.Payload()}}).Marshal(nil)
	if err != nil {
		s.pings.take(id, dst)
		return
	}
	to := s.toNet(netip.AddrPortFrom(dst, 0)).Addr()
	if _, err := s.pings.conn.WriteTo(b, &net.UDPAddr{IP: to.AsSlice()}); err != nil {
		s.pings.take(id, dst)
		return
	}
	s.count(true, len(m.Payload())) // the data, as UDP and TCP count theirs
}

// receivePings hands each reply to the device whose request it answers, until the socket closes.
func (s *Server) receivePings() {
	buf := make([]byte, 65535)
	for {
		n, from, err := s.pings.conn.ReadFrom(buf)
		if err != nil {
			return
		}
		m, err := icmp.ParseMessage(1, buf[:n])
		if err != nil || m.Type != ipv4.ICMPTypeEchoReply {
			continue
		}
		echo, ok := m.Body.(*icmp.Echo)
		u, isUDP := from.(*net.UDPAddr)
		if !ok || !isUDP {
			continue
		}
		addr, _ := netip.AddrFromSlice(u.IP)
		src := s.fromNet(netip.AddrPortFrom(addr.Unmap(), 0)).Addr()
		w, ok := s.pings.take(uint16(echo.ID), src)
		if !ok {
			continue // another app's, or one that waited too long
		}
		s.count(false, len(echo.Data))
		reply := echoReply(w.dst, w.device, w.id, uint16(echo.Seq), echo.Data, s.nextID())
		s.mu.Lock()
		// A reply whose owner went since, a removed device or a router that lost the role, is dropped.
		// A device that got the same tunnel address meanwhile drops it itself: it sent no such ping.
		if !s.closed && s.ownerLocked(w.device) == w.owner {
			s.tun.inject(reply)
		}
		s.mu.Unlock()
	}
}

// add makes a request wait for its reply, under an identifier no other waiting one has. False
// when its owner already has limit waiting.
func (p *pinger) add(w waitingPing, limit int) (uint16, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for id, old := range p.waiting {
		if w.at.Sub(old.at) > pingWait {
			p.removeLocked(id, old)
		}
	}
	if p.of[w.owner] >= limit {
		return 0, false
	}
	for range 1 << 16 {
		p.next++
		if _, used := p.waiting[p.next]; !used {
			p.waiting[p.next] = w
			p.of[w.owner]++
			return p.next, true
		}
	}
	return 0, false
}

// take ends the wait of the request that went out as id to from.
func (p *pinger) take(id uint16, from netip.Addr) (waitingPing, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	w, ok := p.waiting[id]
	if !ok || w.dst != from {
		return waitingPing{}, false
	}
	p.removeLocked(id, w)
	return w, time.Since(w.at) <= pingWait
}

func (p *pinger) removeLocked(id uint16, w waitingPing) {
	delete(p.waiting, id)
	if p.of[w.owner]--; p.of[w.owner] <= 0 {
		delete(p.of, w.owner)
	}
}

// echoReply builds the IPv4 packet of an echo reply from src to the device at dst.
func echoReply(src, dst netip.Addr, id, seq uint16, data []byte, ipID uint16) []byte {
	p := make([]byte, header.IPv4MinimumSize+header.ICMPv4MinimumSize+len(data))
	ip := header.IPv4(p)
	ip.Encode(&header.IPv4Fields{
		TotalLength: uint16(len(p)),
		ID:          ipID,
		TTL:         64,
		Protocol:    uint8(header.ICMPv4ProtocolNumber),
		SrcAddr:     tcpip.AddrFrom4(src.As4()),
		DstAddr:     tcpip.AddrFrom4(dst.As4()),
	})
	ip.SetChecksum(^ip.CalculateChecksum())
	m := header.ICMPv4(p[header.IPv4MinimumSize:])
	m.SetType(header.ICMPv4EchoReply)
	m.SetIdent(id)
	m.SetSequence(seq)
	copy(m.Payload(), data)
	m.SetChecksum(header.ICMPv4Checksum(m[:header.ICMPv4MinimumSize], checksum.Checksum(data, 0)))
	return p
}
