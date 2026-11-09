package main

import (
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"time"

	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/checksum"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

// UDP works like a full-cone NAT: each device port gets one unconnected iPhone socket, whatever it
// talks to, and a reply from any address reaches that port. That's what a call or a game needs to
// connect straight to the other side after STUN, instead of through a relay. A socket per
// destination, which gVisor's UDP forwarder gives, looks like a symmetric NAT to the other side.
//
// Packets from devices arrive through handleUDP, outside gVisor's UDP endpoints. Replies don't go
// through gVisor at all: replyPackets builds the IPv4 packet and it goes straight to wireguard-go.
// IPv4 only: a device's tunnel address, from WireGuardSetup.swift, is IPv4, so it never sends
// IPv6. The client config still routes ::/0 into the tunnel, so nothing IPv6 leaks around it. The
// iPhone's side can be IPv6 all the same, when it reaches an IPv4 address through NAT64.

// cone is one device port's iPhone socket.
type cone struct {
	device netip.AddrPort // where the packets come from: a device's tunnel address, or a client behind a router
	owner  netip.Addr     // whose traffic it is, see Server.owner
	// traffic is the owner's byte counter, see Server.count. Set when the cone is kept, under s.mu.
	traffic *traffic
	// conn is IPv4 only. A socket for IPv4 and IPv6 gets its port from the free IPv6 ports alone,
	// and on macOS and iOS that port can be another app's IPv4 one, which then gets every reply.
	conn *net.UDPConn
	// conn64 reaches IPv4 hosts through the carrier's NAT64 when there's no IPv4 route. Opened by
	// the first packet that needs it, under lock, and nil until then.
	conn64 *net.UDPConn
	// out is never closed, so a late packet from handleUDP can't panic. done ends send instead.
	out  chan outgoing
	done chan struct{}
	// last is when the device last sent through the cone, in UnixNano. Replies don't move it. RFC
	// 4787 (REQ-6) has a NAT refresh a mapping on outbound packets and leaves inbound ones up to
	// it, and with a full cone anyone may send to the port, so a host that kept sending could hold
	// one of the device's cones forever. A call or a game sends both ways, so it stays open.
	last atomic.Int64
	// dnsOnly holds while every packet has gone to port 53. Such a cone idles out after dnsIdle.
	dnsOnly atomic.Bool
	once    sync.Once
	// lock is the server's s.mu. Close takes it, and so does handing a reply to the device, so
	// once Close returns no reply of this cone's can reach a device that gets its address later.
	lock *sync.Mutex
}

type outgoing struct {
	dst     netip.AddrPort
	payload []byte
}

// sentTo notes a packet's destination: anything but a DNS lookup gives the cone the full udpIdle.
func (c *cone) sentTo(dst netip.AddrPort) {
	if dst.Port() != 53 {
		c.dnsOnly.Store(false)
	}
}

func (c *cone) idle() time.Duration {
	if c.dnsOnly.Load() {
		return dnsIdle
	}
	return udpIdle
}

func (c *cone) Close() error {
	c.lock.Lock()
	defer c.lock.Unlock()
	c.once.Do(func() {
		c.conn.Close()
		if c.conn64 != nil {
			c.conn64.Close()
		}
		close(c.done)
	})
	return nil
}

// nat64Conn is the cone's NAT64 socket, nil until a packet needed it.
func (c *cone) nat64Conn() *net.UDPConn {
	c.lock.Lock()
	defer c.lock.Unlock()
	return c.conn64
}

// handleUDP runs on wireguard-go's receive goroutine, since gVisor calls protocol handlers inline.
// So it never blocks: it finds or makes the device port's cone and queues the packet, or drops it.
func (s *Server) handleUDP(id stack.TransportEndpointID, pkt *stack.PacketBuffer) bool {
	device := addrPort(id.RemoteAddress, id.RemotePort)
	dst := addrPort(id.LocalAddress, id.LocalPort)
	if !device.Addr().Is4() {
		return true // handled: dropped
	}
	if dst == dnsAddr && s.upstream.Load().set() {
		s.lookup(device, pkt.Data().AsRange().ToSlice()) // Tether answers it, see dns.go
		return true
	}
	if !forwardable(dst.Addr()) {
		return true
	}
	c := s.cone(device)
	if c == nil {
		return true
	}
	c.sentTo(dst)
	payload := pkt.Data().AsRange().ToSlice()
	select {
	case c.out <- outgoing{dst, payload}:
	default: // the queue is full, which is what a slow link does to UDP anyway
	}
	return true
}

// cone returns the device port's cone, making one when sharing is on. Nil when it can't.
func (s *Server) cone(device netip.AddrPort) *cone {
	s.mu.Lock()
	c := s.cones[device]
	owner := s.ownerLocked(device.Addr())
	full := s.conesOf[owner] >= s.maxCones || s.closed
	s.mu.Unlock()
	if c != nil {
		if c.owner != owner {
			return nil // SetPeers is closing it: the address belongs to someone else now
		}
		return c
	}
	if !owner.IsValid() || full {
		return nil
	}
	conn, err := net.ListenUDP("udp4", nil)
	if err != nil {
		return nil
	}
	c = &cone{device: device, owner: owner, conn: conn, out: make(chan outgoing, 256), done: make(chan struct{}), lock: &s.mu}
	c.last.Store(time.Now().UnixNano())
	c.dnsOnly.Store(true) // until handleUDP's sentTo sees a packet to another port, the first one included
	s.mu.Lock()
	if other := s.cones[device]; other != nil || s.ownerLocked(device.Addr()) != owner || s.conesOf[owner] >= s.maxCones || s.closed {
		// Another packet from the same port made one first, SetPeers changed the devices since
		// the owner was read, the owner's other ports reached the cap meanwhile, or Close
		// began, which closes only the cones it can see. Only
		// handleUDP makes cones, on one goroutine per device, so this is a guard, not a path.
		s.mu.Unlock()
		conn.Close()
		if other != nil && other.owner == owner {
			return other
		}
		return nil // the packet belonged to an owner that's gone, or came too late, so it goes too
	}
	c.traffic = s.trafficOfLocked(owner)
	s.cones[device] = c
	s.conesOf[owner]++
	if device.Addr() != owner {
		s.routed = true // a client's flow through the router
	}
	untrack := s.trackLocked(owner, c)
	s.conesRunning.Add(2) // under s.mu, so it comes before Close's Wait or not at all
	s.mu.Unlock()
	go func() { defer s.conesRunning.Done(); s.send(c) }()
	go func() {
		defer s.conesRunning.Done()
		s.receive(c)
		c.Close()
		untrack()
		s.mu.Lock()
		if s.cones[device] == c {
			delete(s.cones, device)
		}
		release(s.conesOf, owner)
		s.mu.Unlock()
	}()
	return c
}

// send passes a device's packets on and counts them.
func (s *Server) send(c *cone) {
	for {
		var o outgoing
		select {
		case o = <-c.out:
		case <-c.done:
			return
		}
		s.count(c.traffic, true, len(o.payload))
		err := s.sendTo(c.conn, o.payload, s.toNet(o.dst))
		if noRoute(err) {
			if via, ok := s.viaNAT64(s.ctx, o.dst); ok {
				if conn64 := s.openNAT64(c); conn64 != nil {
					err = s.sendTo(conn64, o.payload, s.toNet(via))
				}
			}
		}
		if err == nil {
			c.last.Store(time.Now().UnixNano())
		}
	}
}

// openNAT64 is the cone's NAT64 socket, opened the first time, with a goroutine that hands its
// replies to the device until the cone closes. Both IPv4 and IPv6: the NAT64's addresses are IPv6,
// and tests reach theirs on loopback IPv4. Nil when it can't open, or the cone or server closed.
func (s *Server) openNAT64(c *cone) *net.UDPConn {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c.conn64 != nil {
		return c.conn64
	}
	select {
	case <-c.done:
		return nil
	default:
	}
	if s.closed {
		return nil
	}
	conn, err := net.ListenUDP("udp", nil)
	if err != nil {
		return nil
	}
	c.conn64 = conn
	s.conesRunning.Add(1) // under s.mu, so it comes before Close's Wait or not at all
	go func() {
		defer s.conesRunning.Done()
		buf := make([]byte, 65535)
		for s.reply(c, conn, buf) == nil {
		}
		// A NAT64 socket nobody reads must not stay in use, so the cone goes, as with its own socket.
		c.Close()
	}()
	return conn
}

// receive hands replies from anyone to the device, until the cone's idle time passes without the
// device sending. The cone's NAT64 socket has a loop of its own, which ends when the cone closes.
func (s *Server) receive(c *cone) {
	buf := make([]byte, 65535)
	for {
		c.conn.SetReadDeadline(time.Unix(0, c.last.Load()).Add(c.idle()))
		if err := s.reply(c, c.conn, buf); err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() && time.Since(time.Unix(0, c.last.Load())) < c.idle() {
				continue // quiet this way, but the device is still sending
			}
			return
		}
	}
}

// reply reads one packet from conn and hands it to the cone's device. The read's error, a timeout
// included, or net.ErrClosed once the cone closed.
func (s *Server) reply(c *cone, conn *net.UDPConn, buf []byte) error {
	n, from, err := conn.ReadFromUDPAddrPort(buf)
	if err != nil {
		return err
	}
	src := s.fromNAT64(s.fromNet(netip.AddrPortFrom(from.Addr().Unmap(), from.Port())))
	if !src.Addr().Is4() {
		return nil
	}
	s.count(c.traffic, false, n)
	packets := replyPackets(src, c.device, buf[:n], s.nextID())
	s.mu.Lock()
	defer s.mu.Unlock()
	if c.closed() {
		return net.ErrClosed
	}
	for _, p := range packets {
		s.tun.inject(p)
	}
	return nil
}

func (c *cone) closed() bool {
	select {
	case <-c.done:
		return true
	default:
		return false
	}
}

func (s *Server) nextID() uint16 { return uint16(s.ipID.Add(1)) }

// replyPackets builds the IPv4 packet for a UDP reply, as fragments when it doesn't fit the
// tunnel's MTU. The device's own stack puts the fragments back together.
func replyPackets(src, dst netip.AddrPort, payload []byte, id uint16) [][]byte {
	udpLen := header.UDPMinimumSize + len(payload)
	if udpLen > 0xffff-header.IPv4MinimumSize {
		return nil
	}
	srcAddr, dstAddr := tcpip.AddrFrom4(src.Addr().As4()), tcpip.AddrFrom4(dst.Addr().As4())
	datagram := make([]byte, udpLen)
	u := header.UDP(datagram)
	u.Encode(&header.UDPFields{SrcPort: src.Port(), DstPort: dst.Port(), Length: uint16(udpLen)})
	copy(datagram[header.UDPMinimumSize:], payload)
	xsum := header.PseudoHeaderChecksum(header.UDPProtocolNumber, srcAddr, dstAddr, uint16(udpLen))
	xsum = checksum.Checksum(payload, xsum)
	u.SetChecksum(^u.CalculateChecksum(xsum))

	// Each fragment but the last carries a multiple of 8 bytes.
	most := (MTU - header.IPv4MinimumSize) &^ 7
	var packets [][]byte
	for off := 0; off < udpLen; off += most {
		end := min(off+most, udpLen)
		flags := uint8(0)
		if end < udpLen {
			flags = header.IPv4FlagMoreFragments
		}
		p := make([]byte, header.IPv4MinimumSize+end-off)
		ip := header.IPv4(p)
		ip.Encode(&header.IPv4Fields{
			TotalLength:    uint16(len(p)),
			ID:             id,
			Flags:          flags,
			FragmentOffset: uint16(off),
			TTL:            64,
			Protocol:       uint8(header.UDPProtocolNumber),
			SrcAddr:        srcAddr,
			DstAddr:        dstAddr,
		})
		ip.SetChecksum(^ip.CalculateChecksum())
		copy(p[header.IPv4MinimumSize:], datagram[off:end])
		packets = append(packets, p)
	}
	return packets
}

// inject sends a ready packet to its device, dropped when wireguard-go is behind, like WriteNotify.
func (t *stackTun) inject(p []byte) {
	v := buffer.NewViewWithData(p)
	select {
	case t.incoming <- v:
	case <-t.done:
		v.Release()
	default:
		t.dropped.Add(1)
		v.Release()
	}
}
