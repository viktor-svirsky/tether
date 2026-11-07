package main

import (
	"fmt"
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
// Two of a kind within knockWithin is a stale config, so one stray packet isn't. wireguard-go reads
// handshakes on several goroutines at once, so this runs under s.mu. Under load wireguard-go answers
// with a cookie before it reads a handshake, which takes 128 queued handshakes: not on a hotspot.

const (
	staleDevice = "device" // a device key the server doesn't let in
	staleServer = "server" // a config for other server keys
	knockWithin = 30 * time.Second
)

// knocks remembers when each kind last knocked, and the last stale config they made.
type knocks struct {
	last  map[string]time.Time
	stale staleStats
}

func newKnocks() knocks { return knocks{last: map[string]time.Time{}} }

// heard counts one knock of kind at at.
func (k *knocks) heard(kind string, at time.Time) {
	if prev, ok := k.last[kind]; ok && at.Sub(prev) < knockWithin {
		k.stale = staleStats{Kind: kind, At: at.Unix()}
	}
	k.last[kind] = at
}

// noticeStale counts a handshake the server dropped because its config no longer works.
func (s *Server) noticeStale(format string, args ...any) {
	var kind string
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
		from := fmt.Sprint(args[0])
		for _, ep := range s.endpoints {
			if ep == from {
				return
			}
		}
	}
	s.knocks.heard(kind, s.now())
}
