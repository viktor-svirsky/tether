package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// Some IPv6-only carriers give the iPhone no IPv4 route at all, so a device's connection to an
// IPv4 address, which is nearly every one, fails with no route. Others, T-Mobile US among them,
// run a CLAT on the iPhone, and then IPv4 works and none of this happens. The carrier's NAT64
// reaches IPv4 hosts from IPv6: the IPv4 address goes in the last 32 bits of an IPv6 address in
// its prefix (RFC 6052). iOS does that by itself inside getaddrinfo, which a socket dialing an
// address, as the server does, never goes through.
//
// The direct way is always tried first, so a network that lost its IPv4 route for a moment doesn't
// send everything to a NAT64 that isn't there. A failed dial or send costs one system call: the
// kernel refuses it before anything leaves.

// wellKnownNAT64 is the prefix most NAT64s use (RFC 6052), for when the carrier's can't be found.
var wellKnownNAT64 = netip.MustParsePrefix("64:ff9b::/96")

const (
	// nat64Keep is how long a found prefix is used before it's looked up again. A carrier doesn't
	// change it, but the hotspot can move to another carrier with a new SIM.
	nat64Keep = 10 * time.Minute
	// nat64Retry is how long the well-known prefix stands in after a lookup failed.
	nat64Retry = time.Minute
	// nat64LookupTimeout bounds the lookup, which the first connection through the NAT64 waits for.
	nat64LookupTimeout = 2 * time.Second
)

type nat64 struct {
	// mu makes one lookup at a time, so a page load's hundred connections wait for one lookup
	// instead of making a hundred. found is read without it, by every UDP reply.
	mu     sync.Mutex
	found  atomic.Pointer[netip.Prefix]
	expiry time.Time
	// lookup finds the carrier's prefix. Nil is lookupNAT64. Tests set their own.
	lookup func(context.Context) (netip.Prefix, error)
}

// prefix is the carrier's NAT64 prefix, looked up when there's none or it's old.
func (n *nat64) prefix(ctx context.Context) netip.Prefix {
	n.mu.Lock()
	defer n.mu.Unlock()
	if p := n.found.Load(); p != nil && time.Now().Before(n.expiry) {
		return *p
	}
	lookup := n.lookup
	if lookup == nil {
		lookup = lookupNAT64
	}
	ctx, cancel := context.WithTimeout(ctx, nat64LookupTimeout)
	defer cancel()
	p, err := lookup(ctx)
	if err != nil {
		p = wellKnownNAT64
		n.expiry = time.Now().Add(nat64Retry)
	} else {
		n.expiry = time.Now().Add(nat64Keep)
	}
	n.found.Store(&p)
	return p
}

// lookupNAT64 finds the prefix the way RFC 7050 says: the carrier's DNS64 answers the IPv6 lookup
// of ipv4only.arpa with its two well-known IPv4 addresses inside the prefix.
func lookupNAT64(ctx context.Context) (netip.Prefix, error) {
	addrs, err := net.DefaultResolver.LookupNetIP(ctx, "ip6", "ipv4only.arpa")
	if err != nil {
		return netip.Prefix{}, err
	}
	if p, ok := nat64In(addrs); ok {
		return p, nil
	}
	return netip.Prefix{}, errors.New("ipv4only.arpa has no NAT64 prefix in its answer")
}

// nat64In picks the prefix out of the answer for ipv4only.arpa. Only a /96 is used, where the IPv4
// address is the last 32 bits. The shorter ones RFC 6052 allows are rare, and the well-known prefix
// stands in for them. An IPv4-mapped answer is no NAT64 at all: Go's lookup on Darwin asks for those
// too, and gets ::ffff:192.0.0.170 on a network with IPv4.
func nat64In(addrs []netip.Addr) (netip.Prefix, bool) {
	for _, a := range addrs {
		b := a.As16()
		if a.Is6() && !a.Is4In6() && b[12] == 192 && b[13] == 0 && b[14] == 0 && (b[15] == 170 || b[15] == 171) {
			return netip.PrefixFrom(a, 96).Masked(), true
		}
	}
	return netip.Prefix{}, false
}

// noRoute says a dial or send failed because the iPhone has no route there. Darwin says ENETUNREACH
// or EHOSTUNREACH depending on where it found out, and ENETDOWN when the interface is down.
func noRoute(err error) bool {
	return errors.Is(err, syscall.ENETUNREACH) || errors.Is(err, syscall.EHOSTUNREACH) ||
		errors.Is(err, syscall.ENETDOWN)
}

// viaNAT64 is where to reach an IPv4 address that had no route. ok is false for an IPv6 one.
func (s *Server) viaNAT64(ctx context.Context, dst netip.AddrPort) (via netip.AddrPort, ok bool) {
	if !dst.Addr().Is4() {
		return dst, false
	}
	p := s.nat64.prefix(ctx).Addr().As16()
	v4 := dst.Addr().As4()
	copy(p[12:], v4[:])
	return netip.AddrPortFrom(netip.AddrFrom16(p), dst.Port()), true
}

// fromNAT64 is the IPv4 address a reply through the NAT64 came from. Anything else stays as it is.
func (s *Server) fromNAT64(a netip.AddrPort) netip.AddrPort {
	p := s.nat64.found.Load()
	if p == nil || !p.Contains(a.Addr()) {
		return a
	}
	b := a.Addr().As16()
	return netip.AddrPortFrom(netip.AddrFrom4([4]byte(b[12:])), a.Port())
}
