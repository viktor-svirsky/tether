package main

import (
	"context"
	"io"
	"net"
	"net/netip"
	"slices"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/waiter"
)

func addrPort(a tcpip.Address, port uint16) netip.AddrPort {
	ip, _ := netip.AddrFromSlice(a.AsSlice())
	return netip.AddrPortFrom(ip.Unmap(), port)
}

// handleTCP takes the TCP packets no open connection wanted, inline on wireguard-go's receive
// goroutine like handleUDP. A new connection's SYN is counted against its device's caps here,
// before gVisor's forwarder starts a goroutine for it, and its arrival is kept until forwardTCP's
// dial ends. A SYN sent again meanwhile finds it and isn't counted twice. The owner is read here
// too, not on forwardTCP's goroutine, which may start after SetPeers gave the address to another
// key. Here the key that sent the SYN is still the address's, see apply.
func (s *Server) handleTCP(id stack.TransportEndpointID, pkt *stack.PacketBuffer) bool {
	h := header.TCP(pkt.TransportHeader().Slice())
	if len(h) < header.TCPMinimumSize || h.Flags()&(header.TCPFlagSyn|header.TCPFlagAck) != header.TCPFlagSyn {
		return false // not a new connection, so the stack answers with a reset
	}
	s.syns.Lock()
	defer s.syns.Unlock()
	s.mu.Lock()
	a, again := s.arriving[id]
	if !again {
		if s.closed || len(s.arriving) >= maxInFlight {
			s.mu.Unlock()
			return true // dropped, and the device sends it again
		}
		owner := s.ownerLocked(addrPort(id.RemoteAddress, 0).Addr())
		a = &arrival{owner: owner, key: s.keys[owner]}
		a.refuse = !owner.IsValid() || s.dials[owner] >= s.maxDials || s.conns[owner] >= s.maxConns
		if !a.refuse {
			s.dials[owner]++
			s.conns[owner]++
		}
		s.arriving[id] = a
		s.forwarding.Add(1)
	}
	s.mu.Unlock()
	if !s.forwarder.HandlePacket(id, pkt) {
		// A bad checksum, so no goroutine was started for it. A forwardTCP gVisor started for an
		// earlier SYN with the same id may have taken the arrival already, and then ends it.
		if !again {
			s.mu.Lock()
			mine := !a.taken
			if mine {
				s.dialed(id, a, false)
			}
			s.mu.Unlock()
			if mine {
				s.forwarding.Done()
			}
		}
		return false
	}
	return true
}

// synInTimeWait says p is a SYN from a device port whose last connection's server side is still in
// TIME_WAIT. gVisor drops one too, but one still in the endpoint's queue when TIME_WAIT ends gets a
// reset, since gVisor passes it on only to a listening endpoint and the forwarder isn't one (#127).
// Dropped before it's queued, it never gets there. The device sends it again a second later, after
// TIME_WAIT, see timeWaitTimeout.
func (s *Server) synInTimeWait(p []byte) bool {
	var id stack.TransportEndpointID
	var proto tcpip.NetworkProtocolNumber
	var h header.TCP
	switch {
	case len(p) >= header.IPv4MinimumSize && p[0]>>4 == 4:
		ip := header.IPv4(p)
		if !ip.IsValid(len(p)) || ip.TransportProtocol() != header.TCPProtocolNumber || ip.More() || ip.FragmentOffset() != 0 {
			return false
		}
		proto, h, id.LocalAddress, id.RemoteAddress = header.IPv4ProtocolNumber, ip.Payload(), ip.DestinationAddress(), ip.SourceAddress()
	case len(p) >= header.IPv6MinimumSize && p[0]>>4 == 6:
		// One behind extension headers is let through, as before this check.
		ip := header.IPv6(p)
		if !ip.IsValid(len(p)) || ip.TransportProtocol() != header.TCPProtocolNumber {
			return false
		}
		proto, h, id.LocalAddress, id.RemoteAddress = header.IPv6ProtocolNumber, ip.Payload(), ip.DestinationAddress(), ip.SourceAddress()
	default:
		return false
	}
	if len(h) < header.TCPMinimumSize || h.Flags()&(header.TCPFlagSyn|header.TCPFlagAck) != header.TCPFlagSyn {
		return false
	}
	id.LocalPort, id.RemotePort = h.DestinationPort(), h.SourcePort()
	ep, ok := s.stack.FindTransportEndpoint(proto, tcp.ProtocolNumber, id, 1).(*tcp.Endpoint)
	return ok && tcp.EndpointState(ep.State()) == tcp.StateTimeWait
}

// dialed ends an arrival: its dial is over, and its connection is open when open is true, or gone.
// Runs with s.mu held.
func (s *Server) dialed(id stack.TransportEndpointID, a *arrival, open bool) {
	if s.arriving[id] != a {
		return // ended already
	}
	delete(s.arriving, id)
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

// forwardRequest is what forwardTCP uses of gVisor's tcp.ForwarderRequest. Tests pause one.
type forwardRequest interface {
	ID() stack.TransportEndpointID
	Complete(sendReset bool)
	CreateEndpoint(*waiter.Queue) (tcpip.Endpoint, tcpip.Error)
}

// forwardTCP runs on its own goroutine: gVisor's TCP forwarder starts one per SYN handleTCP passes on.
func (s *Server) forwardTCP(r forwardRequest) {
	id := r.ID()
	s.syns.Lock()
	s.mu.Lock()
	a := s.arriving[id]
	mine := a != nil && !a.taken
	if mine {
		a.taken = true
	}
	s.mu.Unlock()
	if !mine {
		// A SYN sent again after the dial for it was refused, before its arrival was gone. Until
		// Complete, gVisor drops any new SYN with this id, so syns holds them all back till then.
		// Otherwise one could make an arrival that no forwardTCP takes, and Close would wait on it.
		r.Complete(true)
		s.syns.Unlock()
		return
	}
	s.syns.Unlock()
	defer s.forwarding.Done()
	// The arrival goes after Complete, so a SYN sent again in between still finds it.
	refuse := func() {
		r.Complete(true) // a reset, which is what the device would see from a refused port
		s.mu.Lock()
		s.dialed(id, a, false)
		s.mu.Unlock()
	}
	src := addrPort(id.RemoteAddress, 0).Addr()
	dst := addrPort(id.LocalAddress, id.LocalPort)
	lookups := dst == dnsAddr && s.upstream.Load().set() // Tether answers them, see dns.go
	page := slices.Contains(*s.page.Load(), dst)
	allowed := lookups || s.leaves(dst.Addr()) || page
	// Only a connection leaves let through is closed by Block: DNS and the page stay open.
	var to netip.Addr
	if !lookups && !page {
		to = dst.Addr()
	}
	if a.refuse || !allowed {
		refuse()
		return
	}
	// Ended by a pause of the device while it dials, and the pause waits for the dial, so no SYN
	// leaves once the pause is done (#277, #336). See holdDial.
	dialing, end := newHeld(s.ctx)
	untrackDial, ok := s.track(src, a.owner, a.key, netip.Addr{}, end)
	if !ok {
		end.done()
		refuse()
		return
	}
	out, err := s.dialCounted(dialing, dst, lookups)
	untrackDial()
	end.done()
	if err != nil {
		refuse()
		return
	}
	resetOut := func() { resetTCP(out) }
	// out is tracked from here, so SetPeers or Close can close it while the device's side is
	// made, and end that too. It waits for the device's ACK, which never comes when the device's
	// key just went or the stack is closed.
	var wq waiter.Queue
	// ended is set when SetPeers or Close resets the connection's sides, so fail has nothing left
	// to wait for.
	var ended atomic.Bool
	counts := s.trafficOf(a.owner)
	untrackOut, ok := s.track(src, a.owner, a.key, to, &closer{func() { ended.Store(true); resetOut() }}, wake{&wq})
	if !ok {
		out.Close() // nothing was exchanged, so a FIN is as honest as a reset
		refuse()
		return
	}
	defer untrackOut()
	ep, terr := r.CreateEndpoint(&wq)
	if terr != nil {
		resetOut()
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
	// A device that leaves the hotspot never closes its connections. Keepalive finds them.
	ep.SocketOptions().SetKeepAlive(true)
	idle, interval := tcpip.KeepaliveIdleOption(s.keepIdle), tcpip.KeepaliveIntervalOption(s.keepInterval)
	ep.SetSockOpt(&idle)
	ep.SetSockOpt(&interval)
	ep.SetSockOptInt(tcpip.KeepaliveCountOption, 4)
	in := gonet.NewTCPConn(&wq, ep)
	resetIn := func() {
		ep.SocketOptions().SetLinger(tcpip.LingerOption{Enabled: true})
		in.Close()
	}
	closeBoth := func() { in.Close(); out.Close() }
	untrackIn, ok := s.track(src, a.owner, a.key, to, &closer{func() { ended.Store(true); resetIn() }})
	if !ok {
		resetIn()
		resetOut()
		return
	}
	defer untrackIn()
	// fail ends both sides once one has failed. The side it's told failed is reset at once. The other gets
	// what's already on its way to it first, see drain, then is reset too. The other direction
	// usually ends because of the first reset, so its end says nothing about what was delivered.
	var failed atomic.Bool
	fail := func(deviceFailed bool) {
		if failed.Swap(true) || ended.Load() {
			return
		}
		if deviceFailed {
			resetIn()
			s.drain(s.ctx, func() int { return sendQueue(out) })
			resetOut()
		} else {
			resetOut()
			s.drain(s.ctx, nil) // gVisor doesn't say what's left in its send queue
			resetIn()
		}
	}
	// A device that half-closed and then left leaves only the far end's direction, which waits on
	// the far end. Keepalive ends the device's endpoint, and gone says so, see the first copy.
	gone := make(chan struct{}, 1)
	hup := waiter.NewFunctionEntry(waiter.EventHUp|waiter.EventErr, func(waiter.EventMask) {
		select {
		case gone <- struct{}{}:
		default:
		}
	})
	wq.EventRegister(&hup)
	defer wq.EventUnregister(&hup)
	var wg sync.WaitGroup
	wg.Add(2)
	// Closed once the far end's direction has ended and said why. delivered is what it has passed
	// on to the device so far.
	farEndRead := make(chan struct{})
	var delivered atomic.Int64
	// A clean end of one direction passes on as a half close. Anything else, a reset or keepalive
	// giving up, ends both, or the other direction could wait forever on a silent peer. A FIN
	// there would tell the other side its transfer was complete.
	go func() {
		defer wg.Done()
		// gVisor gives a reset's error to the first call that asks, and a read after that sees a
		// clean end, so the endpoint's state says whether the device reset.
		if err, writing := s.copy(out, in, counts, true, nil); err != io.EOF {
			if writing {
				// The far end failed. What it sent first can still be unread in out's receive
				// queue, and a reset of out now would throw it away, so the other direction reads
				// out to its end first. The kernel keeps those bytes readable after the reset.
				s.awaitProgress(farEndRead, &delivered)
			}
			fail(!writing)
		} else if tcp.EndpointState(ep.State()) == tcp.StateError {
			fail(true)
		} else if c, ok := out.(interface{ CloseWrite() error }); ok {
			c.CloseWrite()
			// The far end may take long to answer, and the device may leave meanwhile.
			for {
				select {
				case <-farEndRead:
					return
				case <-gone:
					if tcp.EndpointState(ep.State()) == tcp.StateError {
						fail(true)
						return
					}
				}
			}
		}
	}()
	go func() {
		defer wg.Done()
		if err, writing := s.copy(in, out, counts, false, &delivered); err != io.EOF {
			fail(writing)
		} else {
			in.CloseWrite()
		}
		close(farEndRead)
	}()
	wg.Wait()
	closeBoth()
}

// dialOut makes the iPhone's side of a device's connection: a TCP connection to dst, or, for
// lookups to 10.7.0.1, DNS over TCP that Tether answers.
func (s *Server) dialOut(ctx context.Context, dst netip.AddrPort, lookups bool) (net.Conn, error) {
	if lookups {
		if c := s.lookupConn(); c != nil {
			return c, nil
		}
		return nil, net.ErrClosed
	}
	return s.dialTCP(ctx, dst, func(bool) {})
}

// dialTCP dials dst from the iPhone, through the carrier's NAT64 when the iPhone has no IPv4 route.
// nat64Wait is told when the NAT64 prefix may be looked up, and when that's over. The lookup runs on
// s.ctx: cut short, it would leave the well-known prefix in place of the carrier's for a minute.
func (s *Server) dialTCP(ctx context.Context, dst netip.AddrPort, nat64Wait func(bool)) (net.Conn, error) {
	out, err := holdDial(ctx, func(ctx context.Context) (net.Conn, error) { return s.dial(ctx, "tcp", dst.String()) })
	if noRoute(err) {
		nat64Wait(true)
		via, ok := s.viaNAT64(s.ctx, dst)
		nat64Wait(false)
		if ctx.Err() != nil {
			return nil, ctx.Err() // ended while the prefix was looked up: no SYN goes out
		}
		if ok {
			out, err = holdDial(ctx, func(ctx context.Context) (net.Conn, error) { return s.dial(ctx, "tcp", via.String()) })
		}
	}
	return out, err
}

// resetTCP closes c with a reset, which, unlike a FIN, tells the other side the transfer didn't finish.
func resetTCP(c net.Conn) {
	if t, ok := c.(*net.TCPConn); ok {
		t.SetLinger(0)
	}
	c.Close()
}

// wake ends the handshake CreateEndpoint waits on: gVisor waits for the queue's next event, then
// gives up unless the connection is made. On a connection already made it's a spurious wakeup.
type wake struct{ q *waiter.Queue }

func (w wake) Close() error {
	w.q.Notify(waiter.WritableEvents)
	return nil
}

// copyBufs hold one direction of a TCP connection between a read and its write, each for as long as
// the connection is open. 16 KB is a dozen packets at the tunnel's MTU, and gVisor and the kernel
// buffer the rest of each direction, so a bigger one only costs memory. The pool reuses them across
// the many short connections a page makes.
var copyBufs = sync.Pool{New: func() any { return new([16 << 10]byte) }}

// awaitProgress waits for done while moved keeps growing: a slow device still taking the far end's
// last bytes is waited for, one that stopped taking them for drainGrace is not.
func (s *Server) awaitProgress(done <-chan struct{}, moved *atomic.Int64) {
	t := time.NewTimer(drainGrace)
	defer t.Stop()
	for last := moved.Load(); ; {
		select {
		case <-done:
			return
		case <-s.ctx.Done():
			return
		case <-t.C:
			n := moved.Load()
			if n == last {
				return
			}
			last = n
			t.Reset(drainGrace)
		}
	}
}

// copy moves one direction of a TCP connection and counts it, until an error. A clean end
// returns io.EOF. writing says the error was dst's, not src's. moved, when given, adds up what
// was written.
func (s *Server) copy(dst io.Writer, src io.Reader, counts *traffic, up bool, moved *atomic.Int64) (err error, writing bool) {
	b := copyBufs.Get().(*[16 << 10]byte)
	defer copyBufs.Put(b)
	buf := b[:]
	for {
		n, err := src.Read(buf)
		if n > 0 {
			s.count(counts, up, n)
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return werr, true
			}
			if moved != nil {
				moved.Add(int64(n))
			}
		}
		if err != nil {
			return err, false
		}
	}
}

// closer is a func run as an io.Closer, so track can reset a side rather than close it.
type closer struct{ f func() }

func (c *closer) Close() error { c.f(); return nil }

// drain waits for what is queued to a side to reach it: until queued says nothing is left, or
// drainGrace passes, or ctx ends. A nil queued means the side can't say, so it waits out the grace.
func (s *Server) drain(ctx context.Context, queued func() int) {
	grace := time.NewTimer(drainGrace)
	defer grace.Stop()
	var tick <-chan time.Time // nil, so never, when there's nothing to ask
	if queued != nil {
		t := time.NewTicker(10 * time.Millisecond)
		defer t.Stop()
		tick = t.C
	}
	for {
		select {
		case <-grace.C:
			return
		case <-ctx.Done():
			return
		case <-tick:
			if queued() == 0 {
				return
			}
		}
	}
}

// sendQueue is how many bytes the kernel still has to send on c, unacked ones included, or -1
// when it can't say. SO_NWRITE is Darwin's, which is all Tether builds for.
func sendQueue(c net.Conn) int {
	t, ok := c.(*net.TCPConn)
	if !ok {
		return -1
	}
	rc, err := t.SyscallConn()
	if err != nil {
		return -1
	}
	n := -1
	rc.Control(func(fd uintptr) {
		if v, err := syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_NWRITE); err == nil {
			n = v
		}
	})
	return n
}
