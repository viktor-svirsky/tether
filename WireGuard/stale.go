package main

import (
	"cmp"
	"fmt"
	"net/netip"
	"slices"
	"strings"
	"time"
)

// A device whose config no longer works keeps sending handshakes the server can't answer, every 5 s
// while it has something to send, and the person sees only that it never connects. wireguard-go drops
// them and says why in its verbose log, which notice reads (#89):
//
//   - "Received invalid initiation message from <endpoint>": the server's key is right, but the
//     device's isn't one the server lets in. A code that expired (#29), or a removed device. A known
//     device gets the same line for a replayed or flooded handshake, so one from where a device last
//     connected from doesn't count.
//   - "Received packet with invalid mac1": the config was made for other server keys, so Tether
//     started over with new ones since. It names no endpoint.
//
// Two of a kind from one address within knockWithin is a stale config, so one stray packet isn't,
// also not one from another device. Each address keeps its own for staleFor, with where the knock
// that made it came from, so the config page can tell each device its own (#63): two removed devices
// may keep trying at once. The main screen says the latest. wireguard-go reads handshakes on several
// goroutines at once, so this runs under s.mu. Under load wireguard-go answers with a cookie before
// it reads a handshake, which takes 128 queued handshakes: not on a hotspot.

const (
	staleDevice = "device" // a device key the server doesn't let in
	staleServer = "server" // a config for other server keys
	knockWithin = 30 * time.Second
	// staleFor is how long a stale config is kept after it last knocked, the minute Swift shows it
	// for (StaleConfig.shownFor).
	staleFor = time.Minute
	// knockersKept bounds the (kind, address) keys remembered: a hotspot has a few devices, and
	// anyone on it can send handshakes from many addresses.
	knockersKept = 16
)

// knockKey is where a knock came from, the address alone ("" when wireguard-go doesn't say), and
// its kind.
type knockKey struct{ kind, addr string }

// knocks remembers when each address last knocked with each kind, the stale configs they made, and
// the latest of those.
type knocks struct {
	last   map[knockKey]time.Time
	stale  map[knockKey]staleStats
	latest staleStats
}

func newKnocks() knocks {
	return knocks{last: map[knockKey]time.Time{}, stale: map[knockKey]staleStats{}}
}

// heard counts one knock of kind from from ("" when wireguard-go doesn't say) at at.
func (k *knocks) heard(kind, from string, at time.Time) {
	key := knockKey{kind, from}
	if ap, err := netip.ParseAddrPort(from); err == nil {
		key.addr = ap.Addr().String()
	}
	if prev, ok := k.last[key]; ok && at.Sub(prev) < knockWithin {
		// Kept apart from k.stale: under a flood of more than knockersKept keys, forget can drop the
		// key behind it, so the main screen can say a knock the page no longer has.
		k.latest = staleStats{Kind: kind, At: at.Unix(), From: from}
		k.stale[key] = k.latest
	}
	k.last[key] = at
	k.forget(at)
}

// forget drops what knocked staleFor before now, and the addresses that knocked longest ago beyond
// knockersKept.
func (k *knocks) forget(now time.Time) {
	for key, at := range k.last {
		if now.Sub(at) >= staleFor {
			delete(k.last, key)
			delete(k.stale, key)
		}
	}
	for len(k.last) > knockersKept {
		var oldest knockKey // the zero key is none: a knock always has a kind
		for key, at := range k.last {
			if prev, ok := k.last[oldest]; !ok || at.Before(prev) {
				oldest = key
			}
		}
		delete(k.last, oldest)
		delete(k.stale, oldest)
	}
}

// recentAt is each address's stale config that knocked less than staleFor before now, oldest first.
func (k *knocks) recentAt(now time.Time) []staleStats {
	recent := []staleStats{}
	for _, st := range k.stale {
		if now.Sub(time.Unix(st.At, 0)) < staleFor {
			recent = append(recent, st)
		}
	}
	slices.SortFunc(recent, func(a, b staleStats) int {
		return cmp.Or(cmp.Compare(a.At, b.At), strings.Compare(a.Kind, b.Kind), strings.Compare(a.From, b.From))
	})
	return recent
}

// namedLocked is st for the stats, naming nowhere when a connected device has its address: that
// device was added again, or it's a travel router whose clients share its address, so the config
// page can't tell which device knocked. Its old tunnel may have had another port, so only the
// address counts. The main screen still says a device knocked. Runs with s.mu held.
func (s *Server) namedLocked(st staleStats) staleStats {
	from, err := netip.ParseAddrPort(st.From)
	if err != nil {
		return st
	}
	for addr, ep := range s.endpoints {
		e, err := netip.ParseAddrPort(ep)
		if at, ok := s.shaken[addr]; ok && s.now().Sub(at) < onlineWithin && err == nil && e.Addr() == from.Addr() {
			st.From = ""
			return st
		}
	}
	return st
}

// noticeStale counts a handshake the server dropped because its config no longer works.
func (s *Server) noticeStale(format string, args ...any) {
	var kind, from string
	switch {
	case format == "Received packet with invalid mac1":
		kind = staleServer
	case strings.HasPrefix(format, "Received invalid initiation message from") && len(args) == 1:
		kind = staleDevice
	default:
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if kind == staleDevice {
		from = fmt.Sprint(args[0])
		for _, ep := range s.endpoints {
			if ep == from {
				return
			}
		}
	}
	s.knocks.heard(kind, from, s.now())
}
