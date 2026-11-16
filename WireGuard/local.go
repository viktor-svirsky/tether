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

// fakeIPNet is where proxy apps like Clash put fake addresses, and often their own interface, see localNets.
var fakeIPNet = netip.MustParsePrefix("198.18.0.0/15")

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
		// A proxy app's own interface sits in fakeIPNet: blocking its network would cut the internet.
		if p, err := addr.Prefix(ones); err == nil && !fakeIPNet.Contains(addr) {
			nets = append(nets, p)
		}
	}
	return nets
}

// hotspotNet6 is the on-link network of the hotspot's IPv6 address host, as InterfaceAddrs gives
// it: the hotspot's clients take their addresses there. Only a /64 or narrower one counts: a wider
// one isn't one link's, and the address is the iPhone's global one, so the proxy would face more
// than the hotspot. False when host isn't among addrs.
func hotspotNet6(addrs []net.Addr, host netip.Addr) (netip.Prefix, bool) {
	for _, a := range addrs {
		n, ok := a.(*net.IPNet)
		if !ok {
			continue
		}
		if addr, ok := netip.AddrFromSlice(n.IP); !ok || addr.Unmap() != host {
			continue
		}
		ones, bits := n.Mask.Size()
		if bits != 128 || ones < 64 {
			return netip.Prefix{}, false
		}
		p, err := host.Prefix(ones)
		return p, err == nil
	}
	return netip.Prefix{}, false
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
	s.mu.Unlock()
	s.closeBlocked()
	if was != block {
		text := "devices can reach the iPhone's local networks"
		if block {
			text = "devices can't reach the iPhone's local networks"
		}
		serverLog.add(time.Now(), text)
	}
}

// closeBlocked resets the open TCP connections Block now covers: after it turns on, and after the
// iPhone's networks change. Closed after s.mu is let go, as SetPeers does.
func (s *Server) closeBlocked() {
	if !s.blockLocal.Load() {
		return
	}
	s.mu.Lock()
	var closing []io.Closer
	for c, to := range s.tcpTo {
		if s.isLocal(to) {
			closing = append(closing, c)
		}
	}
	s.mu.Unlock()
	for _, c := range closing {
		c.Close()
	}
}
