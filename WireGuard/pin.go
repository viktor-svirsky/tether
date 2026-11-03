package main

import (
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

// The iPhone's own sockets are pinned to the interface iOS uses for the internet (#61). Left to
// themselves they take whatever route iOS picks, and on some carriers that was another cellular
// data interface (pdp_ip2 instead of pdp_ip0), billed as hotspot data. The interface is the one the
// default route uses, found the way a UDP "connect" finds it, which sends nothing.
//
// Only sockets to addresses on the internet are pinned. A private, CGNAT or link-local address may be
// on a network the iPhone is on, or behind a VPN on the iPhone with routes of its own, and a pinned
// socket would send it out the default interface instead (seen on a Mac: pinned to Wi-Fi, a
// Tailscale address goes to the Wi-Fi router). A VPN that carries the default route isn't pinned
// around either, so a VPN on the iPhone keeps working for the devices too.
//
// TCP pins its socket before it connects. A UDP cone's socket sends to any address, so its packets
// are pinned one by one. Without an IPv4 default route nothing IPv4 is pinned, so a send still fails
// with no route and goes through the NAT64, see nat64.go.

// pinKeep is how long a found interface is used before it's looked up again. iOS moves the default
// route when Wi-Fi or a VPN comes and goes, and a lookup costs a few system calls. For up to this
// long after an interface loses its address, sockets pinned to it fail or lose their packets.
const pinKeep = 5 * time.Second

// cgnat is RFC 6598's shared address space. Carriers and Tailscale both use it.
var cgnat = netip.MustParsePrefix("100.64.0.0/10")

// ipv6PktInfo is Darwin's IPV6_PKTINFO, which package syscall leaves out.
const ipv6PktInfo = 0x2e

// route is the interface a default route uses. An empty name means there's no default route.
type route struct {
	name  string
	index int
}

// vpn says the route goes into a VPN on the iPhone: utun for an app's VPN, ipsec for iOS's own IKEv2.
func (r route) vpn() bool {
	return strings.HasPrefix(r.name, "utun") || strings.HasPrefix(r.name, "ipsec")
}

// pinned is the interface found for an IP version, and when.
type pinned struct {
	route route
	at    time.Time
}

type pinner struct {
	// mu makes one lookup at a time. found is read without it, by every UDP packet, and holds the
	// IPv4 answer at 0 and the IPv6 one at 1.
	mu    sync.Mutex
	found [2]atomic.Pointer[pinned]
	// find is the default route of an IP version. Nil is defaultRoute. Tests set their own.
	find func(ipv6 bool) route
	now  func() time.Time // nil is time.Now. Tests move it
	// logf says when the interface changes, so a test on the iPhone can read which one traffic leaves
	// on. Nil logs nothing.
	logf func(format string, args ...any)
}

// pinnable says whether a socket to dst is pinned: only one to an address on the internet is.
func pinnable(dst netip.Addr) bool {
	dst = dst.Unmap()
	return dst.IsGlobalUnicast() && !dst.IsPrivate() && !cgnat.Contains(dst)
}

// index is the interface a socket to dst is pinned to, or 0 for none.
func (p *pinner) index(dst netip.Addr) int {
	if !pinnable(dst) {
		return 0
	}
	v := 0
	if dst.Unmap().Is6() {
		v = 1
	}
	now := time.Now
	if p.now != nil {
		now = p.now
	}
	if f := p.found[v].Load(); f != nil && now().Sub(f.at) < pinKeep {
		return f.route.pin()
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	old := p.found[v].Load()
	if old != nil && now().Sub(old.at) < pinKeep {
		return old.route.pin() // another socket looked it up meanwhile
	}
	find := p.find
	if find == nil {
		find = defaultRoute
	}
	r := find(v == 1)
	p.found[v].Store(&pinned{r, now()})
	if (old == nil || old.route != r) && p.logf != nil {
		p.logf("%s", r.describe(v == 1))
	}
	return r.pin()
}

// pin is the index to pin to: none without a default route or with a VPN's.
func (r route) pin() int {
	if r.name == "" || r.vpn() {
		return 0
	}
	return r.index
}

// describe is the log line for r.
func (r route) describe(ipv6 bool) string {
	version := "IPv4"
	if ipv6 {
		version = "IPv6"
	}
	switch {
	case r.name == "":
		return version + " traffic isn't pinned: there's no default route"
	case r.vpn():
		return version + " traffic isn't pinned: the default route is " + r.name + ", a VPN"
	}
	return version + " traffic leaves on " + r.name
}

// defaultRoute finds the interface iOS uses for the internet: a UDP "connect" picks the route and
// a local address without sending anything, and the interface that has that address is the one.
func defaultRoute(ipv6 bool) route {
	probe := "1.1.1.1:53"
	if ipv6 {
		probe = "[2606:4700:4700::1111]:53"
	}
	c, err := net.Dial("udp", probe)
	if err != nil {
		return route{} // no route
	}
	local := c.LocalAddr().(*net.UDPAddr).AddrPort().Addr().Unmap()
	c.Close()
	ifs, err := net.Interfaces()
	if err != nil {
		return route{}
	}
	for _, i := range ifs {
		addrs, err := i.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok {
				if ip, ok := netip.AddrFromSlice(n.IP); ok && ip.Unmap() == local {
					return route{i.Name, i.Index}
				}
			}
		}
	}
	return route{}
}

// control pins a TCP socket before it connects, for net.Dialer. A pin that can't be set leaves
// the socket on iOS's own route, as before pinning.
func (p *pinner) control(network, address string, c syscall.RawConn) error {
	dst, err := netip.ParseAddrPort(address)
	if err != nil {
		return nil
	}
	if index := p.index(dst.Addr()); index != 0 {
		c.Control(func(fd uintptr) { pinSocket(int(fd), strings.HasSuffix(network, "6"), index) })
	}
	return nil
}

// pinSocket pins the socket fd to the interface index, for all it sends from now on.
func pinSocket(fd int, ipv6 bool, index int) error {
	if ipv6 {
		return syscall.SetsockoptInt(fd, syscall.IPPROTO_IPV6, syscall.IPV6_BOUND_IF, index)
	}
	return syscall.SetsockoptInt(fd, syscall.IPPROTO_IP, syscall.IP_BOUND_IF, index)
}

// sendTo sends a UDP packet from c, pinned when to is on the internet.
func (p *pinner) sendTo(c *net.UDPConn, payload []byte, to netip.AddrPort) error {
	_, _, err := c.WriteMsgUDPAddrPort(payload, via(to.Addr(), p.index(to.Addr())), to)
	return err
}

// via is the control message that sends one packet to dst out of the interface index, or nil for
// iOS's own route when index is 0. An IPv4 one is for an IPv4 socket, like a cone's own, and an
// IPv6 one for an IPv6 socket, like a cone's NAT64 one.
func via(dst netip.Addr, index int) []byte {
	if index == 0 {
		return nil
	}
	if dst.Unmap().Is4() {
		b := make([]byte, syscall.CmsgSpace(syscall.SizeofInet4Pktinfo))
		h := (*syscall.Cmsghdr)(unsafe.Pointer(&b[0]))
		h.Level, h.Type = syscall.IPPROTO_IP, syscall.IP_PKTINFO
		h.SetLen(syscall.CmsgLen(syscall.SizeofInet4Pktinfo))
		(*syscall.Inet4Pktinfo)(unsafe.Pointer(&b[syscall.CmsgLen(0)])).Ifindex = uint32(index)
		return b
	}
	b := make([]byte, syscall.CmsgSpace(syscall.SizeofInet6Pktinfo))
	h := (*syscall.Cmsghdr)(unsafe.Pointer(&b[0]))
	h.Level, h.Type = syscall.IPPROTO_IPV6, ipv6PktInfo
	h.SetLen(syscall.CmsgLen(syscall.SizeofInet6Pktinfo))
	(*syscall.Inet6Pktinfo)(unsafe.Pointer(&b[syscall.CmsgLen(0)])).Ifindex = uint32(index)
	return b
}
