package main

import (
	"bytes"
	"fmt"
	"net/netip"
	"testing"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/header"
)

// pingFrom sends one echo request from the device and returns the reply, or an error after wait.
func pingFrom(c *client, dst string, seq int, data []byte, wait time.Duration) (*icmp.Echo, error) {
	pc, err := c.net.DialPingAddr(netip.Addr{}, netip.MustParseAddr(dst))
	if err != nil {
		return nil, err
	}
	defer pc.Close()
	b, err := (&icmp.Message{Type: ipv4.ICMPTypeEcho, Body: &icmp.Echo{ID: 1, Seq: seq, Data: data}}).Marshal(nil)
	if err != nil {
		return nil, err
	}
	if _, err := pc.Write(b); err != nil {
		return nil, err
	}
	pc.SetReadDeadline(time.Now().Add(wait))
	buf := make([]byte, 2048)
	n, err := pc.Read(buf)
	if err != nil {
		return nil, err
	}
	m, err := icmp.ParseMessage(1, buf[:n])
	if err != nil {
		return nil, err
	}
	echo, ok := m.Body.(*icmp.Echo)
	if m.Type != ipv4.ICMPTypeEchoReply || !ok {
		return nil, fmt.Errorf("got %v, not an echo reply", m.Type)
	}
	return echo, nil
}

func TestPingGoesThroughTheTunnel(t *testing.T) {
	s, c := setup(t)
	for seq := range 3 {
		data := []byte(fmt.Sprintf("ping %d", seq))
		echo, err := pingFrom(c, remote, seq, data, 5*time.Second)
		if err != nil {
			t.Fatalf("ping %d: %v", seq, err)
		}
		if echo.Seq != seq || !bytes.Equal(echo.Data, data) {
			t.Fatalf("ping %d came back as seq %d %q", seq, echo.Seq, echo.Data)
		}
	}
	// Each way the data, 6 bytes, three times, as UDP counts its payload.
	if st := s.Stats(); st.Up != 18 || st.Down != 18 {
		t.Fatalf("counted up %d down %d, want 18 each", st.Up, st.Down)
	}
}

// iOS closes a suspended app's sockets during a phone call (#106). The ping socket is opened again,
// so pings through the tunnel work after the call, not only TCP and UDP (#151).
func TestPingWorksAfterIOSClosedItsSocket(t *testing.T) {
	s, c := setup(t)
	if _, err := pingFrom(c, remote, 0, []byte("before"), 5*time.Second); err != nil {
		t.Fatal(err)
	}
	s.pings.conn.Load().Close()
	var err error
	for seq := 1; seq <= 5; seq++ { // the first one may go out on the closed socket
		if _, err = pingFrom(c, remote, seq, []byte("after"), 2*time.Second); err == nil {
			return
		}
	}
	t.Fatal("no reply after the socket was closed:", err)
}

// A host that doesn't answer gets the device no reply, the same as from the iPhone.
func TestAPingNobodyAnswersGetsNoReply(t *testing.T) {
	_, c := setup(t)
	if echo, err := pingFrom(c, "198.51.100.99", 0, []byte("x"), time.Second); err == nil {
		t.Fatalf("got a reply %v", echo)
	}
}

// A ping to the tunnel's own addresses or a multicast one stays inside, like UDP.
func TestAPingToTheTunnelStaysInside(t *testing.T) {
	_, c := setup(t)
	for _, dst := range []string{"10.7.0.1", "10.7.0.3", "224.0.0.1"} {
		if echo, err := pingFrom(c, dst, 0, []byte("x"), 500*time.Millisecond); err == nil {
			t.Fatalf("%s answered %v", dst, echo)
		}
	}
}

func TestADevicesWaitingPingsAreCapped(t *testing.T) {
	var p pinger
	p.waiting, p.of = map[uint16]waitingPing{}, map[netip.Addr]int{}
	a, b := netip.MustParseAddr("10.7.0.2"), netip.MustParseAddr("10.7.0.3")
	dst := netip.MustParseAddr(remote)
	now := time.Now()
	for i := range 2 {
		if _, ok := p.add(waitingPing{owner: a, dst: dst, at: now}, 2); !ok {
			t.Fatalf("ping %d of 2 refused", i)
		}
	}
	if _, ok := p.add(waitingPing{owner: a, dst: dst, at: now}, 2); ok {
		t.Fatal("a third waiting ping went out")
	}
	if _, ok := p.add(waitingPing{owner: b, dst: dst, at: now}, 2); !ok {
		t.Fatal("another device's ping was refused")
	}
	if _, ok := p.add(waitingPing{owner: a, dst: dst, at: now.Add(pingWait + time.Second)}, 2); !ok {
		t.Fatal("pings that waited too long still count")
	}
	if p.of[a] != 1 || p.of[b] != 0 || len(p.waiting) != 1 {
		t.Fatalf("%d of a's waiting, %d of b's, %d in all, want only the new one", p.of[a], p.of[b], len(p.waiting))
	}
}

// A reply only ends the wait of the request it answers: the same identifier from another host is
// someone else's.
func TestAReplyFromAnotherHostIsntTaken(t *testing.T) {
	var p pinger
	p.waiting, p.of = map[uint16]waitingPing{}, map[netip.Addr]int{}
	dst := netip.MustParseAddr(remote)
	id, _ := p.add(waitingPing{owner: netip.MustParseAddr("10.7.0.2"), dst: dst, at: time.Now()}, 2)
	if _, ok := p.take(id, netip.MustParseAddr("198.51.100.8")); ok {
		t.Fatal("taken by another host's reply")
	}
	if _, ok := p.take(id, dst); !ok {
		t.Fatal("not taken by its own reply")
	}
	if _, ok := p.take(id, dst); ok {
		t.Fatal("taken twice")
	}
}

func TestOnlyWholeEchoRequestsAreTakenFromTheStack(t *testing.T) {
	request := echoReply(netip.MustParseAddr("10.7.0.2"), netip.MustParseAddr(remote), 1, 1, []byte("x"), 1)
	header.ICMPv4(request[header.IPv4MinimumSize:]).SetType(header.ICMPv4Echo)
	if !isEchoRequest(request) {
		t.Fatal("an echo request wasn't one")
	}
	reply := echoReply(netip.MustParseAddr(remote), netip.MustParseAddr("10.7.0.2"), 1, 1, []byte("x"), 1)
	fragment := append([]byte(nil), request...)
	header.IPv4(fragment).SetFlagsFragmentOffset(header.IPv4FlagMoreFragments, 0)
	udp := append([]byte(nil), request...)
	udp[9] = uint8(header.UDPProtocolNumber)
	short := request[:header.IPv4MinimumSize+4]
	v6 := make([]byte, header.IPv6MinimumSize+8)
	v6[0] = 6 << 4
	for name, p := range map[string][]byte{"reply": reply, "fragment": fragment, "udp": udp, "short": short, "ipv6": v6, "empty": nil} {
		if isEchoRequest(p) {
			t.Errorf("%s taken as an echo request", name)
		}
	}
}
