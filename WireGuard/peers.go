package main

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"maps"
	"net/netip"
	"strings"
)

// Peer is one device: its public key, its address inside the tunnel, and whether it is paused.
type Peer struct {
	PublicKey [32]byte
	Address   netip.Addr
	// Paused keeps it on the server, handshake and all, and refuses its traffic, see ownerLocked.
	Paused bool
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

// SetPeers makes the allowed devices exactly these. Only the ones that changed are touched, so a
// device added or removed doesn't drop everyone else's session. A removed device's open
// connections are closed, so a device that gets its tunnel address later can't receive them.
// A paused device stays in wireguard-go, so its session and handshake go on, but its traffic is
// refused (see ownerLocked) and its open connections are closed, the way a removed device's are.
// A paused router gives up the role, so another router can take over meanwhile.
func (s *Server) SetPeers(peers []Peer) error {
	want := map[[32]byte]netip.Addr{}
	paused := map[[32]byte]bool{}
	for _, p := range peers {
		want[p.PublicKey] = p.Address
		if p.Paused {
			paused[p.PublicKey] = true
		}
	}
	s.applying.Lock()
	defer s.applying.Unlock()
	// The router stays the router while its key keeps its address and isn't paused. A paused router
	// still handshakes, so it would look online to makeRouter and keep every other router out. Once
	// resumed, its next packet for a client asks for the role back like any device's, see makeRouter.
	s.mu.Lock()
	router := s.router
	for key, addr := range s.peers {
		if addr == router && (want[key] != router || paused[key]) {
			router = netip.Addr{}
		}
	}
	// Paused before wireguard-go has the change, so a device added paused gets no traffic through
	// meanwhile. track refuses a connection being made from now on, since it reads ownerLocked.
	wasPaused := s.paused
	s.paused = paused
	var closing []io.Closer
	if !maps.Equal(paused, wasPaused) {
		closing = append(closing, s.swapDoHLocked())
	}
	for key, addr := range s.peers {
		if paused[key] && !wasPaused[key] {
			for c := range s.flows[addr] {
				closing = append(closing, c)
			}
		}
	}
	s.mu.Unlock()
	for _, c := range closing {
		c.Close()
	}
	if err := s.apply(want, router); err != nil {
		s.mu.Lock()
		s.paused = wasPaused
		s.mu.Unlock()
		return err
	}
	return nil
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
		// A device paused since it was picked isn't made the router, see noticeRouter.
		known = known || (a == addr && !s.paused[key])
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
	// A paused device's traffic is refused, so it can't carry a client's flow, and mustn't take the role.
	if !addr.IsValid() || addr == s.router || s.paused[s.keys[addr]] || (addr == s.refused && s.now().Sub(s.refusedAt) < handshakeEvery) {
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
	s.keys = make(map[netip.Addr][32]byte, len(peers))
	s.names = make(map[string]netip.Addr, len(peers))
	for key, addr := range peers {
		s.keys[addr] = key
		s.names[peerName(key)] = addr
	}
	s.logNames.Store(s.names)
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
	// The flows of the devices that change close before wireguard-go routes differently.
	// Otherwise a reply on such a flow could go to whichever device takes over its address, the
	// router's ranges included. Until wireguard-go has the change, only the devices that keep
	// their address are known: wireguard-go still lets a removed key's packets in until IpcSet
	// removes it, which waits for the ones it has queued. So an address changing hands has no
	// owner meanwhile, or the old key's packets would start flows as the new key's.
	kept := map[[32]byte]netip.Addr{}
	for key, addr := range want {
		if old, ok := have[key]; ok && old == addr {
			kept[key] = addr
		}
	}
	s.mu.Lock()
	s.setPeersLocked(kept)
	if router != wasRouter {
		s.router, s.routed = netip.Addr{}, false
		// A router made where there was none owns its clients' packets from now on, since
		// wireguard-go lets them in before IpcSet returns, and a SYN refused meanwhile ends its
		// client's connection with a reset (#117). No other device had the ranges to send from.
		if _, ok := s.keys[router]; ok && !wasRouter.IsValid() {
			s.router = router
		}
		// A device kept out for the old router may have the role on its next packet.
		s.refused = netip.Addr{}
	}
	var closing []io.Closer
	for key, addr := range have {
		// A router that stops being one, or that another device takes over from, loses its
		// clients' connections too, or their UDP flows would still count as its own.
		if want[key] != addr || (addr == wasRouter && addr != router) {
			delete(s.shaken, addr)
			if want[key] != addr {
				delete(s.traffic, addr) // what it used isn't the next one's
			}
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
	s.mu.Lock()
	s.setPeersLocked(want)
	s.router = router
	s.mu.Unlock()
	s.readHandshakes()
	return nil
}

var tunnelNet = netip.MustParsePrefix("10.7.0.0/24")

// owner is the tunnel address whose traffic a packet from src is: its own for a device, the
// router's for a device behind it. wireguard-go only takes routedNets sources from the router, so
// no other device can send as one of its clients. Invalid when nobody may send from src: a device
// just removed, or a tunnel address no device has, which the router's ranges cover too. A flow from
// one would go to the device that gets that address later. Invalid too for a paused device and a
// paused router's clients, so every way in (TCP, UDP, ping and their replies) refuses them here.
func (s *Server) owner(src netip.Addr) netip.Addr {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.ownerLocked(src)
}

func (s *Server) ownerLocked(src netip.Addr) netip.Addr {
	owner := s.unpausedOwnerLocked(src)
	if owner.IsValid() && s.paused[s.keys[owner]] {
		return netip.Addr{}
	}
	return owner
}

func (s *Server) unpausedOwnerLocked(src netip.Addr) netip.Addr {
	// One lookup: cone() asks for every outgoing UDP packet, with s.mu held (#155).
	if _, ok := s.keys[src]; ok {
		return src
	}
	if s.router.IsValid() && !tunnelNet.Contains(src) {
		for _, n := range routedNets {
			if n.Contains(src) {
				return s.router
			}
		}
	}
	return netip.Addr{}
}

// track keeps a connection's sockets so SetPeers, Close and readHandshakes can close them. The returned func
// forgets them. ok is false when the server is closing, or src no longer belongs to device under
// the key that asked for the connection: SetPeers changed the devices while it was being made,
// after it closed the ones it knew about. The key matters when an address changes hands, since the
// address alone would let the old key's connection open as the new key's.
// to is the connection's destination when Block covers it, invalid when it doesn't (DNS, the page, UDP).
func (s *Server) track(src, device netip.Addr, key [32]byte, to netip.Addr, conns ...io.Closer) (untrack func(), ok bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	// Block read under mu, so it can't turn on between this and the connection being kept.
	if s.closed || s.keys[device] != key || s.ownerLocked(src) != device || to.IsValid() && s.blocks(to) {
		return nil, false
	}
	if src != device {
		s.routed = true // a client's connection through the router
	}
	return s.trackLocked(device, to, conns...), true
}

// trackLocked keeps conns as device's, and a valid to in tcpTo, for Block to check, see track.
func (s *Server) trackLocked(device, to netip.Addr, conns ...io.Closer) (untrack func()) {
	set := s.flows[device]
	if set == nil {
		set = map[io.Closer]struct{}{}
		s.flows[device] = set
	}
	for _, c := range conns {
		set[c] = struct{}{}
		if to.IsValid() {
			s.tcpTo[c] = to
		}
	}
	return func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		for _, c := range conns {
			delete(s.flows[device], c)
			delete(s.tcpTo, c)
		}
	}
}
