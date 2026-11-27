package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/checksum"
	"gvisor.dev/gvisor/pkg/tcpip/header"
)

// replyPackets turns whatever a host on the internet sends into packets for a device, so any
// payload must give valid IPv4 fragments that put the datagram back together exactly.
// `go test` runs the seeds. CI fuzzes it for 30 s: go test -run '^$' -fuzz FuzzReplyPackets
func FuzzReplyPackets(f *testing.F) {
	f.Add([]byte("hello"), uint16(53), uint16(5000), uint16(7))
	f.Add([]byte{}, uint16(0), uint16(0), uint16(0))
	f.Add(make([]byte, 3000), uint16(443), uint16(40000), uint16(0xffff))
	f.Add(make([]byte, MTU-28), uint16(1), uint16(2), uint16(3)) // exactly one full packet
	f.Fuzz(func(t *testing.T, payload []byte, srcPort, dstPort, id uint16) {
		src := netip.AddrPortFrom(netip.MustParseAddr("1.2.3.4"), srcPort)
		dst := netip.AddrPortFrom(netip.MustParseAddr("10.7.0.2"), dstPort)
		ps := replyPackets(src, dst, payload, id)
		if header.UDPMinimumSize+len(payload) > 0xffff-header.IPv4MinimumSize {
			if ps != nil {
				t.Fatal("a datagram too big for IPv4 was sent")
			}
			return
		}
		var datagram []byte
		for i, p := range ps {
			ip := header.IPv4(p)
			if len(p) > MTU || !ip.IsValid(len(p)) || !ip.IsChecksumValid() {
				t.Fatalf("fragment %d of %d is not a valid IPv4 packet of at most the MTU", i, len(ps))
			}
			if ip.ID() != id || int(ip.FragmentOffset()) != len(datagram) || ip.More() != (i < len(ps)-1) {
				t.Fatalf("fragment %d: id %d offset %d more %v", i, ip.ID(), ip.FragmentOffset(), ip.More())
			}
			datagram = append(datagram, ip.Payload()...)
		}
		u := header.UDP(datagram)
		if len(datagram) != header.UDPMinimumSize+len(payload) || !bytes.Equal(u.Payload(), payload) {
			t.Fatalf("the fragments carry %d bytes, want the %d byte payload behind a UDP header", len(datagram), len(payload))
		}
		if u.SourcePort() != srcPort || u.DestinationPort() != dstPort {
			t.Fatalf("ports %d -> %d, want %d -> %d", u.SourcePort(), u.DestinationPort(), srcPort, dstPort)
		}
		srcAddr, dstAddr := tcpip.AddrFrom4(src.Addr().As4()), tcpip.AddrFrom4(dst.Addr().As4())
		if !u.IsChecksumValid(srcAddr, dstAddr, checksum.Checksum(u.Payload(), 0)) {
			t.Fatal("the UDP checksum is wrong")
		}
	})
}

// fuzzServer is a running server with a device at 10.7.0.2 whose traffic never leaves the host:
// dials and sends fail at once, and pings get no place to wait for a reply, so none goes out.
func fuzzServer(f *testing.F) *Server {
	s := startAlone(f)
	_, pub := keyPair(f)
	if err := s.SetPeers([]Peer{{PublicKey: pub, Address: netip.MustParseAddr("10.7.0.2")}}); err != nil {
		f.Fatal(err)
	}
	offline := errors.New("offline")
	s.dial = func(context.Context, string, string) (net.Conn, error) { return nil, offline }
	s.sendTo = func(*net.UDPConn, []byte, netip.AddrPort) error { return offline }
	s.mu.Lock()
	s.maxPings = 0
	s.mu.Unlock()
	return s
}

// A device can put any bytes into the tunnel. The stack must take them without a panic, and what
// it sends back must fit the MTU. wireguard-go reads the same channel, so this checks only the
// packets it gets first, and a reply made later can show up in a later input. Fuzz with:
// go test -run '^$' -fuzz '^FuzzTunWrite$'
func FuzzTunWrite(f *testing.F) {
	dev := netip.MustParseAddrPort("10.7.0.2:40000")
	echo := header.ICMPv4(make([]byte, header.ICMPv4MinimumSize))
	echo.SetType(header.ICMPv4Echo)
	echo.SetChecksum(header.ICMPv4Checksum(echo, 0))
	f.Add(rawSYN(dev, netip.MustParseAddrPort(remote+":443")))
	f.Add(replyPackets(dev, dnsAddr, lookupFor(f, 1, "example.com.", 0), 1)[0])
	f.Add(ipv4Packets(header.ICMPv4ProtocolNumber, dev.Addr(), dnsAddr.Addr(), echo, 1)[0])
	f.Add([]byte{0x60})
	s := fuzzServer(f)
	f.Fuzz(func(t *testing.T, packet []byte) {
		s.tun.Write([][]byte{bytes.Clone(packet)}, 0)
		for {
			select {
			case v := <-s.tun.incoming:
				if n := v.Size(); n > MTU {
					t.Fatalf("a %d byte packet for the device", n)
				}
				v.Release()
			default:
				return
			}
		}
	})
}

// dohAnswer stands in for a DoH server: it answers each request with what it makes of the query.
type dohAnswer func(query []byte) []byte

func (d dohAnswer) RoundTrip(r *http.Request) (*http.Response, error) {
	q, err := io.ReadAll(r.Body)
	if err != nil {
		return nil, err
	}
	return &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": {"application/dns-message"}},
		Body: io.NopCloser(bytes.NewReader(d(q))), Request: r}, nil
}

func viaFakeDoH(s *Server, d dohAnswer) {
	s.dohClient = &http.Client{Transport: d}
	s.dohSpare = s.dohClient
	s.SetDNS(&dnsUpstream{doh: "https://dns.example/abc123"})
}

// resolve takes any query from a device and any answer from the upstream. What it gives the device
// carries the query's ID and fits TCP's 2-byte length.
func FuzzResolve(f *testing.F) {
	q := lookupFor(f, 0, "example.com.", 1232)
	f.Add(q, answerTo(f, q, 3), false)
	f.Add(q, []byte{}, true)
	f.Add([]byte{}, []byte{}, false)
	s := startAlone(f)
	// A request still out when doh returns, its hedge say, reads this during the next input.
	var upstream atomic.Pointer[[]byte]
	viaFakeDoH(s, func([]byte) []byte { return bytes.Clone(*upstream.Load()) })
	f.Fuzz(func(t *testing.T, query, answer []byte, overTCP bool) {
		mine := bytes.Clone(answer) // the fuzzer reuses answer for the next input
		upstream.Store(&mine)
		got := s.resolve(s.ctx, query, overTCP)
		if len(got) > dnsMessageMax {
			t.Fatalf("a %d byte answer", len(got))
		}
		if got != nil && (got[0] != query[0] || got[1] != query[1]) {
			t.Fatalf("the answer has ID %x, the query %x", got[:2], query[:2])
		}
	})
}

// serveTCP reads any stream a device sends to 10.7.0.1:53. Each answer it writes is a whole frame,
// and there are no more of them than queries the stream can hold.
func FuzzServeTCP(f *testing.F) {
	q := lookupFor(f, 1, "example.com.", 0)
	frame := append(binary.BigEndian.AppendUint16(nil, uint16(len(q))), q...)
	f.Add(append(frame, frame...))
	f.Add([]byte{0, 0})
	s := startAlone(f)
	viaFakeDoH(s, func(q []byte) []byte { q[2] |= 0x80; return q }) // the query back as its answer
	f.Fuzz(func(t *testing.T, stream []byte) {
		var out bytes.Buffer
		s.serveTCP(s.ctx, bytes.NewReader(stream), &out)
		frames := 0
		for b := out.Bytes(); len(b) > 0; frames++ {
			if len(b) < 2 || len(b) < 2+int(binary.BigEndian.Uint16(b)) {
				t.Fatalf("a frame cut short: %x", b)
			}
			b = b[2+int(binary.BigEndian.Uint16(b)):]
		}
		if frames > len(stream)/(2+dnsHeaderLen) {
			t.Fatalf("%d answers from %d bytes", frames, len(stream))
		}
	})
}

// questionsOf and answers read what devices and upstreams send. A question takes at least 5 bytes:
// the root name, a type and a class.
func FuzzQuestions(f *testing.F) {
	q := lookupFor(f, 7, "example.com.", 0)
	f.Add(q, answerTo(f, q, 2))
	f.Add(q, q)
	f.Fuzz(func(t *testing.T, query, m []byte) {
		if qs, err := questionsOf(m); err == nil && 5*len(qs) > len(m)-dnsHeaderLen {
			t.Fatalf("%d questions in %d bytes", len(qs), len(m))
		}
		if len(query) < dnsHeaderLen {
			return // every caller passes a query resolve took, a whole header at least
		}
		if answers(query, m) && (m[2]&0x80 == 0 || m[0] != query[0] || m[1] != query[1]) {
			t.Fatalf("%x taken as the answer to %x", m, query)
		}
	})
}

// echoReply turns the data a pinged host sent back into packets for the device: valid IPv4 within
// the MTU that put the echo reply back together exactly.
func FuzzEchoReply(f *testing.F) {
	f.Add([]byte("abcdefgh"), uint16(1), uint16(2), uint16(3))
	f.Add([]byte{}, uint16(0), uint16(0), uint16(0))
	f.Add(make([]byte, maxEcho), uint16(0xffff), uint16(0xffff), uint16(0xffff))
	src, dst := netip.MustParseAddr("1.2.3.4"), netip.MustParseAddr("10.7.0.2")
	f.Fuzz(func(t *testing.T, data []byte, id, seq, ipID uint16) {
		ps := echoReply(src, dst, id, seq, data, ipID)
		if ps == nil && header.ICMPv4MinimumSize+len(data) <= 0xffff-header.IPv4MinimumSize {
			t.Fatalf("no reply for %d bytes", len(data))
		}
		var m header.ICMPv4
		for i, p := range ps {
			ip := header.IPv4(p)
			if len(p) > MTU || !ip.IsValid(len(p)) || !ip.IsChecksumValid() || ip.ID() != ipID {
				t.Fatalf("fragment %d of %d is not a valid IPv4 packet of at most the MTU", i, len(ps))
			}
			m = append(m, ip.Payload()...)
		}
		if ps != nil && (len(m) != header.ICMPv4MinimumSize+len(data) || m.Type() != header.ICMPv4EchoReply ||
			m.Ident() != id || m.Sequence() != seq || !bytes.Equal(m.Payload(), data) || checksum.Checksum(m, 0) != 0xffff) {
			t.Fatalf("the reply is wrong: %x", m[:min(len(m), header.ICMPv4MinimumSize)])
		}
	})
}

// nat64In reads any answer for ipv4only.arpa. A prefix it finds is a /96 from the answer, and an
// IPv4 address put in it comes back out as itself.
func FuzzNAT64(f *testing.F) {
	well := wellKnownNAT64.Addr().As16()
	well[12], well[13], well[14], well[15] = 192, 0, 0, 170
	f.Add(well[:], uint32(0x08080808), uint16(53))
	mapped := netip.MustParseAddr("::ffff:192.0.0.170").As16()
	f.Add(mapped[:], uint32(0x01010101), uint16(443))
	f.Fuzz(func(t *testing.T, answer []byte, v4 uint32, port uint16) {
		var addrs []netip.Addr
		for b := answer; len(b) >= 16; b = b[16:] {
			addrs = append(addrs, netip.AddrFrom16([16]byte(b)))
		}
		p, ok := nat64In(addrs)
		if !ok {
			return
		}
		if p.Bits() != 96 || !slices.ContainsFunc(addrs, p.Contains) {
			t.Fatalf("%v from %v", p, addrs)
		}
		s := &Server{now: time.Now} // viaNAT64 reads the expiry by the server clock
		s.nat64.found.Store(&p)
		s.nat64.expiry = time.Now().Add(time.Hour)
		dst := netip.AddrPortFrom(netip.AddrFrom4([4]byte(binary.BigEndian.AppendUint32(nil, v4))), port)
		via, ok := s.viaNAT64(context.Background(), dst)
		if !ok || !p.Contains(via.Addr()) || s.fromNAT64(via) != dst || s.fromNAT64(dst) != dst {
			t.Fatalf("%v went out as %v under %v", dst, via, p)
		}
	})
}
