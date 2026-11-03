package main

import (
	"fmt"
	"net/netip"
	"testing"
	"time"
)

// deviceStats is the device's entry in the stats Swift gets.
func deviceStats(t *testing.T, s *Server, addr string) peerStats {
	t.Helper()
	for _, p := range s.statsMessage().Peers {
		if p.Address == addr {
			return p
		}
	}
	t.Fatalf("no stats for %s", addr)
	return peerStats{}
}

// Each device's bytes are counted as its own, the same bytes as the totals, so the devices add up
// to the totals on the main screen.
func TestEachDeviceCountsItsOwnTCP(t *testing.T) {
	s, a, b := setupTwo(t)
	fetchAndShake(t, s, a, tcpServer(t, 1000))
	fetchAndShake(t, s, b, tcpServer(t, 5000))
	pa, pb := deviceStats(t, s, "10.7.0.2"), deviceStats(t, s, "10.7.0.3")
	if pa.Up != 5 || pa.Down != 1000 || pb.Up != 5 || pb.Down != 5000 {
		t.Fatalf("counted %+v and %+v, want 5 up each and 1000 and 5000 down", pa, pb)
	}
	if m := s.statsMessage(); pa.Up+pb.Up != m.Up || pa.Down+pb.Down != m.Down {
		t.Fatalf("devices %+v don't add up to the totals, up %d down %d", m.Peers, m.Up, m.Down)
	}
}

func TestUDPCountsForItsDevice(t *testing.T) {
	s, c := setup(t)
	conn, err := c.net.Dial("udp", udpEcho(t))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	for i := range 3 {
		msg := fmt.Sprintf("ping %d", i)
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		conn.Write([]byte(msg))
		if _, err := conn.Read(make([]byte, 100)); err != nil {
			t.Fatalf("echo %d: %v", i, err)
		}
	}
	if p := deviceStats(t, s, "10.7.0.2"); p.Up != 18 || p.Down != 18 {
		t.Fatalf("counted %+v, want 18 each way", p)
	}
}

func TestPingCountsForItsDevice(t *testing.T) {
	s, c := setup(t)
	for seq := range 3 {
		if _, err := pingFrom(c, remote, seq, []byte(fmt.Sprintf("ping %d", seq)), 5*time.Second); err != nil {
			t.Fatalf("ping %d: %v", seq, err)
		}
	}
	if p := deviceStats(t, s, "10.7.0.2"); p.Up != 18 || p.Down != 18 {
		t.Fatalf("counted %+v, want 18 each way", p)
	}
}

// A device that leaves and comes back, or another device given its address, starts from zero:
// what the old one used isn't the new one's.
func TestADeviceThatLeavesStartsFromZero(t *testing.T) {
	s, c := setup(t)
	fetchAndShake(t, s, c, tcpServer(t, 1000))
	s.mu.Lock()
	var peers []Peer
	for key, addr := range s.peers {
		peers = append(peers, Peer{PublicKey: key, Address: addr})
	}
	s.mu.Unlock()
	if err := s.SetPeers(nil); err != nil {
		t.Fatal(err)
	}
	if err := s.SetPeers(peers); err != nil {
		t.Fatal(err)
	}
	if p := deviceStats(t, s, "10.7.0.2"); p.Up != 0 || p.Down != 0 {
		t.Fatalf("counted %+v after it came back, want zero", p)
	}
	if m := s.statsMessage(); m.Up != 5 || m.Down != 1000 {
		t.Fatalf("totals up %d down %d, want them kept", m.Up, m.Down)
	}
}

// The last handshake and where the device connects from, for the device's screen and the log.
// A device that never connected has neither.
func TestStatsSayWhenAndWhereADeviceConnected(t *testing.T) {
	s, a, _ := setupTwo(t)
	before := time.Now().Add(-time.Second).Unix()
	fetchAndShake(t, s, a, tcpServer(t, 10))
	pa, pb := deviceStats(t, s, "10.7.0.2"), deviceStats(t, s, "10.7.0.3")
	if pa.Handshake < before || !pa.Connected {
		t.Fatalf("%+v, want a handshake just now", pa)
	}
	if ep, err := netip.ParseAddrPort(pa.Endpoint); err != nil || !ep.Addr().IsLoopback() {
		t.Fatalf("endpoint %q, want the device's loopback address and port: %v", pa.Endpoint, err)
	}
	if pb.Handshake != 0 || pb.Endpoint != "" || pb.Connected {
		t.Fatalf("%+v, want nothing for a device that never connected", pb)
	}
}

// The counter a device that isn't let in gets is kept by nobody, so a late flow of a device that
// left doesn't give its bytes to a device given that address later.
func TestTheCounterOfAGoneDeviceIsKeptByNobody(t *testing.T) {
	s, _ := setup(t)
	gone := netip.MustParseAddr("10.7.0.9")
	s.count(s.trafficOf(gone), false, 1000)
	s.mu.Lock()
	_, kept := s.traffic[gone]
	s.mu.Unlock()
	if kept {
		t.Fatal("a device that isn't let in got a counter")
	}
	if m := s.statsMessage(); m.Down != 1000 {
		t.Fatalf("totals down %d, want the bytes in the totals still", m.Down)
	}
}
