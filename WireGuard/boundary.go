package main

// The messages between WireGuardServer.swift and the server, as JSON, and the plain Go functions
// behind the C exports in exports.go, which only convert strings. Tests call these, since a test
// file can't import "C".
//
// Each message carries "v", the version of its shape. Adding a key doesn't change it: both sides
// skip keys they don't know. Removing a key or changing what one means does, and each side refuses
// a version it doesn't know rather than reading it wrong.

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"sort"
)

const messageVersion = 1

// configMessage is the devices Swift lets in, see TetherWGConfigure.
type configMessage struct {
	V     int          `json:"v"`
	Peers []configPeer `json:"peers"`
	// DNS is added later, see parseDNS. A message without it keeps lookups to 10.7.0.1 inside.
	DNS *configDNS `json:"dns"`
}

type configPeer struct {
	Key     []byte `json:"key"` // 32 bytes, base64 in the JSON
	Address string `json:"address"`
	// Paused is added later, so a message without it lets the device in as before.
	Paused bool `json:"paused"`
}

// statsMessage is what TetherWGStats returns. testdata/stats.json is an example, and
// WireGuardServerTests reads it, so a change here shows up on the Swift side.
type statsMessage struct {
	V    int    `json:"v"`
	Up   uint64 `json:"up"`
	Down uint64 `json:"down"`
	// Peers holds every device the server lets in, in address order.
	Peers []peerStats `json:"peers"`
	// Stale is the last config that knocked but no longer works, see stale.go.
	Stale staleStats `json:"stale"`
	// Recent is each address's stale config from the last minute, oldest first, so the config page
	// can tell each device its own (#63).
	Recent []staleStats `json:"recent"`
}

// staleStats is a config that no longer works. Kind is staleDevice or staleServer, and "" with At 0
// for none yet. At is when it last knocked, Unix seconds. From is where that knock came from,
// ip:port, for the config page to tell that device (#63), and "" for staleServer: wireguard-go
// doesn't say where a bad mac1 came from.
type staleStats struct {
	Kind string `json:"kind"`
	At   int64  `json:"at"`
	From string `json:"from"`
}

type peerStats struct {
	Address string `json:"address"`
	// Connected: a recent handshake, so the device is set up and working, also before it sent anything.
	Connected bool `json:"connected"`
	// Up and Down are its bytes since it got its address in this run, the same bytes as the totals.
	Up   uint64 `json:"up"`
	Down uint64 `json:"down"`
	// Handshake is its last one in Unix seconds, 0 for never. Endpoint is where that came from,
	// ip:port, empty for never.
	Handshake int64  `json:"handshake"`
	Endpoint  string `json:"endpoint"`
}

// parseConfig reads a configMessage. A key that isn't 32 bytes, an address that isn't one, or a
// key or address used twice is an error, so a device can't be shown as set up while the server
// leaves it out.
func parseConfig(js string) ([]Peer, *dnsUpstream, error) {
	var m configMessage
	if err := json.Unmarshal([]byte(js), &m); err != nil {
		return nil, nil, fmt.Errorf("device list: %w", err)
	}
	if m.V != messageVersion {
		return nil, nil, fmt.Errorf("device list version %d, this server reads %d", m.V, messageVersion)
	}
	if m.Peers == nil { // missing or null, while no devices is []
		return nil, nil, fmt.Errorf("device list: no peers")
	}
	peers := make([]Peer, 0, len(m.Peers))
	seenKeys := map[[32]byte]bool{}
	seenAddrs := map[netip.Addr]bool{}
	for i, p := range m.Peers {
		if len(p.Key) != 32 {
			return nil, nil, fmt.Errorf("device %d: its key is %d bytes, not 32", i+1, len(p.Key))
		}
		a, err := netip.ParseAddr(p.Address)
		if err != nil {
			return nil, nil, fmt.Errorf("device %d: %w", i+1, err)
		}
		var key [32]byte
		copy(key[:], p.Key)
		if seenKeys[key] || seenAddrs[a] {
			return nil, nil, fmt.Errorf("device %d repeats a key or address", i+1)
		}
		seenKeys[key], seenAddrs[a] = true, true
		peers = append(peers, Peer{PublicKey: key, Address: a, Paused: p.Paused})
	}
	dns, err := parseDNS(m.DNS)
	if err != nil {
		return nil, nil, err
	}
	return peers, dns, nil
}

// configure lets in exactly the devices in a configMessage. With no server it only checks the
// message: WireGuardServer.swift sends the devices again with each start.
func configure(js string) error {
	peers, dns, err := parseConfig(js)
	if err != nil {
		return err
	}
	mu.Lock()
	defer mu.Unlock()
	if server == nil {
		return nil
	}
	server.SetDNS(dns)
	return server.SetPeers(peers)
}

// statsJSON is the running server's statsMessage, and false when no server runs.
func statsJSON() (string, bool) {
	mu.Lock()
	defer mu.Unlock()
	if server == nil {
		return "", false
	}
	b, err := json.Marshal(server.statsMessage())
	if err != nil {
		return "", false // plain numbers and strings, so it can't fail
	}
	return string(b), true
}

// statsMessage reads the totals and the devices one after the other, so bytes moving meanwhile can
// make the devices differ from the totals for one read.
func (s *Server) statsMessage() statsMessage {
	st := s.Stats()
	connected := map[string]bool{}
	for _, a := range st.Connected {
		connected[a] = true
	}
	m := statsMessage{V: messageVersion, Up: st.Up, Down: st.Down, Peers: []peerStats{}}
	addresses := s.addresses()
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, a := range addresses {
		p := peerStats{Address: a, Connected: connected[a]}
		addr := netip.MustParseAddr(a)
		if t := s.traffic[addr]; t != nil {
			p.Up, p.Down = t.up.Load(), t.down.Load()
		}
		if at, ok := s.shaken[addr]; ok {
			p.Handshake = at.Unix()
		}
		p.Endpoint = s.endpoints[addr]
		m.Peers = append(m.Peers, p)
	}
	m.Stale = s.namedLocked(s.knocks.latest)
	m.Recent = s.knocks.recentAt(s.now())
	for i, st := range m.Recent {
		m.Recent[i] = s.namedLocked(st)
	}
	return m
}

// addresses are the tunnel addresses of the devices the server lets in, in order.
func (s *Server) addresses() []string {
	s.mu.Lock()
	ips := make([]netip.Addr, 0, len(s.peers))
	for _, a := range s.peers {
		ips = append(ips, a)
	}
	s.mu.Unlock()
	sort.Slice(ips, func(i, j int) bool { return ips[i].Less(ips[j]) })
	out := make([]string, len(ips))
	for i, a := range ips {
		out[i] = a.String()
	}
	return out
}

// recovered is the error a recovered panic becomes, see survive.
func recovered(r any) string {
	return fmt.Sprint("wireguard: ", r)
}
