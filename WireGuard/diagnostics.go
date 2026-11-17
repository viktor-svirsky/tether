package main

import (
	"errors"
	"net"
	"net/netip"
	"slices"
	"strings"
	"sync/atomic"
)

// The counters on the Diagnostics screen in Settings (#256). Together they say where a device's
// traffic stops, in the order it travels:
//
//   - UDP in on the WireGuard port, and its last sender. None means nothing from the device reaches
//     the iPhone: it isn't on the hotspot, or its tunnel points somewhere else.
//   - Rejected WireGuard messages. The device reaches the iPhone, but wireguard-go turns its
//     messages away: a config that no longer works, see stale.go.
//   - Replies that couldn't be sent, and the last send error. iOS keeps the answers from leaving:
//     Local Network off for Tether, for one.
//   - Packets in, the ones the devices' tunnels hand the server, and the ones dropped for their
//     source address: a device sending from an address its config doesn't give it.
//   - TCP connections tried and failed, UDP sends failed, the NAT64 prefix and the last error: the
//     iPhone's own way out.
//
// They count from the server's start. Atomics, since the packet path adds to them.
type diagnostics struct {
	packetsIn, rejected, disallowed atomic.Uint64
	tcpTried, tcpFailed, udpFailed  atomic.Uint64
	lastError                       atomic.Pointer[string]
}

// rejectedLines are what wireguard-go's verbose log says when it turns a message away. A message too
// short or of the wrong size, and data for a session it doesn't have, it drops without a word, so
// those aren't counted here, only as UDP in.
var rejectedLines = []string{
	"Received message with unknown type",
	"Received packet with invalid mac1",
	"Received invalid initiation message from %s",
	"Received invalid response message from %s",
	"Failed to decode cookie reply",
	"Could not decrypt invalid cookie response",
}

// heard counts a line of wireguard-go's verbose log, see notice.
func (d *diagnostics) heard(format string) {
	switch {
	case slices.Contains(rejectedLines, format):
		d.rejected.Add(1)
	case strings.HasSuffix(format, "packet with disallowed source address from %v"):
		d.disallowed.Add(1)
	}
}

// dialCounted is dialOut, counting a connection the iPhone makes for a device. It counts as tried
// before the dial, so one to a far end that drops SYNs shows while it waits, and a NAT64 retry is
// part of the same try. Lookups Tether answers itself make no connection, so they don't count.
func (s *Server) dialCounted(dst netip.AddrPort, lookups bool) (net.Conn, error) {
	if lookups {
		return s.dialOut(dst, lookups)
	}
	s.diag.tcpTried.Add(1)
	out, err := s.dialOut(dst, lookups)
	if err != nil {
		s.diag.tcpFailed.Add(1)
		s.diag.failed("TCP to " + dst.String() + ": " + err.Error())
	}
	return out, err
}

// sent counts a device's UDP packet the iPhone couldn't send on. One left queued when its cone
// closed isn't: nothing failed.
func (d *diagnostics) sent(dst netip.AddrPort, err error) {
	if err != nil && !errors.Is(err, net.ErrClosed) {
		d.udpFailed.Add(1)
		d.failed("UDP to " + dst.String() + ": " + err.Error())
	}
}

func (d *diagnostics) failed(what string) { d.lastError.Store(&what) }

// countingTun counts the packets wireguard-go hands the stack: what the devices send into the tunnel.
type countingTun struct {
	*stackTun
	in *atomic.Uint64
}

func (t countingTun) Write(bufs [][]byte, offset int) (int, error) {
	t.in.Add(uint64(len(bufs)))
	return t.stackTun.Write(bufs, offset)
}

// bindCounts are the hostBind's: what reaches the WireGuard port, and the replies that can't leave.
type bindCounts struct {
	in, sendFailed atomic.Uint64
	// lastFrom changes only when the sender does, so a packet in costs no allocation.
	lastFrom  atomic.Pointer[netip.AddrPort]
	sendError atomic.Pointer[string]
}

func (c *bindCounts) received(from netip.AddrPort) {
	c.in.Add(1)
	if last := c.lastFrom.Load(); last == nil || *last != from {
		f := from // a copy here, so only a new sender moves it to the heap
		c.lastFrom.Store(&f)
	}
}

func (c *bindCounts) unsent(to netip.AddrPort, err error) {
	c.sendFailed.Add(1)
	s := "to " + to.String() + ": " + err.Error()
	c.sendError.Store(&s)
}

// listening is where the bind listens now, ip:port, IPv4 first.
func (b *hostBind) listening() []string {
	b.mu.Lock()
	defer b.mu.Unlock()
	at := []string{}
	for _, c := range []*net.UDPConn{b.v4, b.v6} {
		if c != nil {
			at = append(at, c.LocalAddr().String())
		}
	}
	return at
}

// diagStats is the "diag" object in statsMessage. Texts are "" for none yet.
type diagStats struct {
	Listening   []string `json:"listening"`
	UDPIn       uint64   `json:"udpIn"`
	UDPFrom     string   `json:"udpFrom"`
	Rejected    uint64   `json:"rejected"`
	ReplyFailed uint64   `json:"replyFailed"`
	ReplyError  string   `json:"replyError"`
	PacketsIn   uint64   `json:"packetsIn"`
	Disallowed  uint64   `json:"disallowed"`
	TCPTried    uint64   `json:"tcpTried"`
	TCPFailed   uint64   `json:"tcpFailed"`
	UDPFailed   uint64   `json:"udpFailed"`
	// NAT64 is the prefix in use, once a connection needed one, see nat64.go.
	NAT64     string `json:"nat64"`
	LastError string `json:"lastError"`
}

func (s *Server) diagStats() diagStats {
	b := &s.bind.counts
	m := diagStats{
		Listening:   s.bind.listening(),
		UDPIn:       b.in.Load(),
		ReplyFailed: b.sendFailed.Load(),
		Rejected:    s.diag.rejected.Load(),
		PacketsIn:   s.diag.packetsIn.Load(),
		Disallowed:  s.diag.disallowed.Load(),
		TCPTried:    s.diag.tcpTried.Load(),
		TCPFailed:   s.diag.tcpFailed.Load(),
		UDPFailed:   s.diag.udpFailed.Load(),
	}
	if p := b.lastFrom.Load(); p != nil {
		m.UDPFrom = p.String()
	}
	if p := b.sendError.Load(); p != nil {
		m.ReplyError = *p
	}
	if p := s.nat64.found.Load(); p != nil {
		m.NAT64 = p.String()
	}
	if p := s.diag.lastError.Load(); p != nil {
		m.LastError = *p
	}
	return m
}
