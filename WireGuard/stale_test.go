package main

import (
	"context"
	"net/netip"
	"testing"
	"time"
)

// A config that no longer works knocks with handshakes the server can't answer, and the stats say
// so (#89). See stale.go.

// knock is a device the server can't answer, sending one handshake: its dial gives up long before
// wireguard-go's 5 s retry.
func knock(t *testing.T, s *Server, serverPub [32]byte) {
	t.Helper()
	priv, _ := keyPair(t)
	c := newClient(t, s, serverPub, priv, netip.MustParseAddr("10.7.0.9"))
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	if _, err := c.net.DialContext(ctx, "tcp", tcpServer(t, 1)); err == nil {
		t.Fatal("a device the server can't answer got through")
	}
}

// startOneDevice starts a server that lets one device in, and returns it with its public key.
func startOneDevice(t *testing.T) (*Server, [32]byte) {
	t.Helper()
	sPriv, sPub := keyPair(t)
	_, cPub := keyPair(t)
	s, err := Start([]netip.Addr{loopback}, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	if err := s.SetPeers([]Peer{{PublicKey: cPub, Address: netip.MustParseAddr("10.7.0.2")}}); err != nil {
		t.Fatal(err)
	}
	return s, sPub
}

// staleAfter waits up to a second for the stats to name a stale config, since wireguard-go logs
// the handshake on its own goroutine.
func staleAfter(s *Server) staleStats {
	deadline := time.Now().Add(time.Second)
	for {
		st := s.statsMessage().Stale
		if st.Kind != "" || time.Now().After(deadline) {
			return st
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestACodeThatExpiredIsAStaleDevice(t *testing.T) {
	s, sPub := startOneDevice(t)
	before := time.Now().Unix()
	knock(t, s, sPub)
	knock(t, s, sPub)
	st := staleAfter(s)
	if st.Kind != staleDevice || st.At < before {
		t.Fatalf("stale %+v, want a stale device from now on", st)
	}
	// Where it knocked from, for the config page to tell that device (#63).
	if from, err := netip.ParseAddrPort(st.From); err != nil || from.Addr() != loopback {
		t.Fatalf("stale from %q, want the device's ip:port", st.From)
	}
}

// wireguard-go doesn't say where a handshake with a bad mac1 came from.
func TestAConfigForOtherServerKeysIsAStaleServer(t *testing.T) {
	s, _ := startOneDevice(t)
	_, other := keyPair(t) // the keys Tether had before it started over
	knock(t, s, other)
	knock(t, s, other)
	if st := staleAfter(s); st.Kind != staleServer || st.From != "" {
		t.Fatalf("stale %+v, want a config for other server keys, from nowhere", st)
	}
}

// One stray handshake isn't a device that keeps trying.
func TestOneKnockIsNotEnough(t *testing.T) {
	s, sPub := startOneDevice(t)
	knock(t, s, sPub)
	if st := staleAfter(s); st.Kind != "" {
		t.Fatalf("stale %+v after one handshake, want none", st)
	}
}

func TestAWorkingDeviceIsNoStaleConfig(t *testing.T) {
	s, c := setup(t)
	fetchAndShake(t, s, c, tcpServer(t, 10))
	fetchAndShake(t, s, c, tcpServer(t, 10))
	if st := s.statsMessage().Stale; st != (staleStats{}) {
		t.Fatalf("stale %+v, want none", st)
	}
}

// wireguard-go says "invalid initiation" for a known device's replayed or flooded handshake too, so
// one from where a device last connected from doesn't count.
func TestAKnownDevicesDroppedHandshakeIsNoStaleConfig(t *testing.T) {
	s, c := setup(t)
	fetchAndShake(t, s, c, tcpServer(t, 10))
	s.mu.Lock()
	from := s.endpoints[netip.MustParseAddr("10.7.0.2")]
	s.mu.Unlock()
	if from == "" {
		t.Fatal("no endpoint for the device")
	}
	s.notice("Received invalid initiation message from %s", from)
	s.notice("Received invalid initiation message from %s", from)
	if st := s.statsMessage().Stale; st.Kind != "" {
		t.Fatalf("stale %+v, want none for a known device", st)
	}
	s.notice("Received invalid initiation message from %s", "172.20.10.9:51820")
	s.notice("Received invalid initiation message from %s", "172.20.10.9:51820")
	if st := s.statsMessage().Stale; st.Kind != staleDevice || st.From != "172.20.10.9:51820" {
		t.Fatalf("stale %+v, want a stale device from somewhere else", st)
	}
}

func TestKnocksCountOnlyCloseTogetherAndByKind(t *testing.T) {
	t0 := time.Unix(1_800_000_000, 0)
	k := newKnocks()
	k.heard(staleDevice, "172.20.10.9:51820", t0)
	k.heard(staleServer, "", t0.Add(time.Second))
	if k.stale.Kind != "" {
		t.Fatalf("stale %+v from two kinds, want none", k.stale)
	}
	k.heard(staleDevice, "172.20.10.9:51820", t0.Add(knockWithin+time.Second))
	if k.stale.Kind != "" {
		t.Fatalf("stale %+v from knocks %v apart, want none", k.stale, knockWithin+time.Second)
	}
	k.heard(staleDevice, "172.20.10.9:51820", t0.Add(knockWithin+6*time.Second))
	want := staleStats{Kind: staleDevice, At: t0.Add(knockWithin + 6*time.Second).Unix(), From: "172.20.10.9:51820"}
	if k.stale != want {
		t.Fatalf("stale %+v, want %+v", k.stale, want)
	}
	// The latest one is kept, with where it came from: nowhere for the server kind.
	k.heard(staleServer, "", t0.Add(knockWithin+7*time.Second))
	k.heard(staleServer, "", t0.Add(knockWithin+8*time.Second))
	if k.stale.Kind != staleServer || k.stale.From != "" {
		t.Fatalf("stale %+v, want the server kind that came last", k.stale)
	}
}

// connectedOne starts a server with one device connected, and returns them with another port at
// the device's address: where a stale config on it, or behind it, knocks from.
func connectedOne(t *testing.T) (*Server, time.Time, string) {
	t.Helper()
	s, c := setup(t)
	fetchAndShake(t, s, c, tcpServer(t, 10))
	s.mu.Lock()
	defer s.mu.Unlock()
	ep, err := netip.ParseAddrPort(s.endpoints[netip.MustParseAddr("10.7.0.2")])
	if err != nil {
		t.Fatalf("no endpoint for the device: %v", err)
	}
	return s, s.shaken[netip.MustParseAddr("10.7.0.2")], netip.AddrPortFrom(ep.Addr(), ep.Port()^1).String()
}

// knockTwice is a stale device knocking from from, the second time at at.
func knockTwice(s *Server, from string, at time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.knocks.heard(staleDevice, from, at.Add(-5*time.Second))
	s.knocks.heard(staleDevice, from, at)
}

// A device added again connects from where it knocked, so the page doesn't tell it for the rest of
// the minute that its config no longer works. The main screen still says a device knocked.
func TestADeviceThatConnectsFromWhereItKnockedIsNoLongerNamed(t *testing.T) {
	s, shook, old := connectedOne(t)
	knockTwice(s, old, shook.Add(-5*time.Second))
	if st := s.statsMessage().Stale; st.Kind != staleDevice || st.From != "" {
		t.Fatalf("stale %+v, want a stale device from nowhere once one connected from there", st)
	}
	// Once that device is gone, a knock from there names it again.
	later := shook.Add(onlineWithin + time.Minute)
	s.mu.Lock()
	s.now = func() time.Time { return later }
	s.mu.Unlock()
	knockTwice(s, old, later)
	if st := s.statsMessage().Stale; st.Kind != staleDevice || st.From != old {
		t.Fatalf("stale %+v, want a stale device from %s", st, old)
	}
}

// A travel router's clients share its address, and the router handshakes only every 2 minutes,
// so a stale config behind it knocks after the router's last handshake. The page can't tell which
// device that is, so it names none, or every device behind the router would hear it.
func TestAKnockFromBehindARouterNamesNoDevice(t *testing.T) {
	s, shook, behind := connectedOne(t)
	knockTwice(s, behind, shook.Add(time.Minute))
	if st := s.statsMessage().Stale; st.Kind != staleDevice || st.From != "" {
		t.Fatalf("stale %+v, want a stale device from nowhere", st)
	}
}

// One stale device at a time is what a hotspot sees, so the knock that made it names where it's from.
func TestAStaleDeviceIsWhereItsLatestKnockCameFrom(t *testing.T) {
	t0 := time.Unix(1_800_000_000, 0)
	k := newKnocks()
	k.heard(staleDevice, "172.20.10.9:51820", t0)
	k.heard(staleDevice, "172.20.10.9:51820", t0.Add(5*time.Second))
	k.heard(staleDevice, "172.20.10.4:60000", t0.Add(10*time.Second))
	if k.stale.From != "172.20.10.4:60000" {
		t.Fatalf("stale from %q, want the latest knock's", k.stale.From)
	}
}
