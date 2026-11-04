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
	s, err := Start(loopback, 0, sPriv)
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
}

func TestAConfigForOtherServerKeysIsAStaleServer(t *testing.T) {
	s, _ := startOneDevice(t)
	_, other := keyPair(t) // the keys Tether had before it started over
	knock(t, s, other)
	knock(t, s, other)
	if st := staleAfter(s); st.Kind != staleServer {
		t.Fatalf("stale %+v, want a config for other server keys", st)
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
	if st := s.statsMessage().Stale; st.Kind != staleDevice {
		t.Fatalf("stale %+v, want a stale device from somewhere else", st)
	}
}

func TestKnocksCountOnlyCloseTogetherAndByKind(t *testing.T) {
	t0 := time.Unix(1_800_000_000, 0)
	k := newKnocks()
	k.heard(staleDevice, t0)
	k.heard(staleServer, t0.Add(time.Second))
	if k.stale.Kind != "" {
		t.Fatalf("stale %+v from two kinds, want none", k.stale)
	}
	k.heard(staleDevice, t0.Add(knockWithin+time.Second))
	if k.stale.Kind != "" {
		t.Fatalf("stale %+v from knocks %v apart, want none", k.stale, knockWithin+time.Second)
	}
	k.heard(staleDevice, t0.Add(knockWithin+6*time.Second))
	if want := (staleStats{Kind: staleDevice, At: t0.Add(knockWithin + 6*time.Second).Unix()}); k.stale != want {
		t.Fatalf("stale %+v, want %+v", k.stale, want)
	}
	// The latest one is kept.
	k.heard(staleServer, t0.Add(knockWithin+7*time.Second))
	k.heard(staleServer, t0.Add(knockWithin+8*time.Second))
	if k.stale.Kind != staleServer {
		t.Fatalf("stale %+v, want the server kind that came last", k.stale)
	}
}
