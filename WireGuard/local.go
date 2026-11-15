package main

import (
	"io"
	"net"
	"net/netip"
	"time"
)

// localNets are the networks Block keeps the devices out of, besides the ones the iPhone is on
// (#230): the private ranges a home or office Wi-Fi and most VPNs use, the carrier-grade NAT range
// Tailscale uses, and IPv6 unique local addresses, which a travel router's IPv6 clients can reach over TCP (see routedNets). A public
// network that only a VPN on the iPhone routes can't be told apart by its address, so it stays open.
// So does 198.18.0.0/15: a proxy app like Clash on the iPhone can answer Tether's own DNS with
// fake addresses there, and blocking them would cut the devices off the internet.
var localNets = []netip.Prefix{
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("fc00::/7"),
}

// widestOnLink is the widest network of the iPhone's own that counts as local, per family. A VPN
// that gives its interface an odd mask, like /1, would otherwise block the internet.
const widestOnLink4, widestOnLink6 = 16, 48

// onLinkOf is the networks the iPhone's interfaces are on, as InterfaceAddrs gives them, without
// the ones too wide to be a local network and the ones that stay inside anyway.
func onLinkOf(addrs []net.Addr) []netip.Prefix {
	var nets []netip.Prefix
	for _, a := range addrs {
		n, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		addr, ok := netip.AddrFromSlice(n.IP)
		if !ok || !forwardable(addr.Unmap()) {
			continue
		}
		addr = addr.Unmap()
		ones, _ := n.Mask.Size()
		widest := widestOnLink4
		if addr.Is6() {
			widest = widestOnLink6
		}
		if ones < widest {
			continue
		}
		if p, err := addr.Prefix(ones); err == nil {
			nets = append(nets, p)
		}
	}
	return nets
}

// isLocal says whether dst is on a local network: in localNets or on a network the iPhone is on.
func (s *Server) isLocal(dst netip.Addr) bool {
	dst = dst.Unmap()
	for _, p := range localNets {
		if p.Contains(dst) {
			return true
		}
	}
	for _, p := range *s.onLink.Load() {
		if p.Contains(dst) {
			return true
		}
	}
	return false
}

// blocks says whether Block keeps the devices from dst.
func (s *Server) blocks(dst netip.Addr) bool {
	return s.blockLocal.Load() && s.isLocal(dst)
}

// SetBlockLocal keeps the devices out of the local networks, or lets them in again (#230). Turning
// it on resets the TCP connections already open to a local address. UDP and ping check every packet,
// so they follow by themselves. It's set under s.mu, which track reads it under, so a connection
// dialed while it turns on is either refused there or closed here.
func (s *Server) SetBlockLocal(block bool) {
	s.mu.Lock()
	was := s.blockLocal.Swap(block)
	var closing []io.Closer
	if block {
		for c := range s.localFlows {
			closing = append(closing, c)
		}
	}
	s.mu.Unlock()
	for _, c := range closing {
		c.Close()
	}
	if was != block {
		text := "devices can reach the iPhone's local networks"
		if block {
			text = "devices can't reach the iPhone's local networks"
		}
		serverLog.add(time.Now(), text)
	}
}
