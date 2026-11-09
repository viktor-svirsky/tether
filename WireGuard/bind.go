package main

import (
	"errors"
	"net"
	"net/netip"
	"sync"
	"syscall"

	"golang.zx2c4.com/wireguard/conn"
)

// hostBind is a conn.Bind that listens on the hotspot's addresses only. wireguard-go's own bind
// listens on every interface. There's one socket per address, at most one IPv4 and one IPv6
// (172.20.10.1 and the iPhone's IPv6 address on a carrier that gives it IPv6 only, #98), all on
// one port. A reply goes out of the socket of its device's family.
type hostBind struct {
	hosts  []netip.Addr
	mu     sync.Mutex
	v4, v6 *net.UDPConn
	// died is told when a socket the bind still holds fails underneath it, see failed.
	died func()
	// broken says one did, and Open hasn't opened new ones since.
	broken bool
	// port is where it last listened, so the server can listen there again: the devices' configs
	// point at it.
	port uint16
}

type endpoint struct{ netip.AddrPort }

func (e endpoint) ClearSrc()           {}
func (e endpoint) SrcToString() string { return "" }
func (e endpoint) DstToString() string { return e.AddrPort.String() }
func (e endpoint) DstToBytes() []byte  { b, _ := e.AddrPort.MarshalBinary(); return b }
func (e endpoint) DstIP() netip.Addr   { return e.AddrPort.Addr() }
func (e endpoint) SrcIP() netip.Addr   { return netip.Addr{} }

// Open listens on every address, on port, or on the first socket's port for port 0. One that
// fails fails it all, and the server doesn't start: HotspotSession tries again the next round, so
// an IPv6 address that isn't ready yet is listened on a little later instead of never.
func (b *hostBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.v4 != nil || b.v6 != nil {
		return nil, 0, conn.ErrBindAlreadyOpen
	}
	if len(b.hosts) == 0 {
		return nil, 0, errors.New("no address to listen on")
	}
	var fns []conn.ReceiveFunc
	for _, host := range b.hosts {
		if (host.Is4() && b.v4 != nil) || (!host.Is4() && b.v6 != nil) {
			b.closeAll()
			return nil, 0, errors.New("two addresses of one family: a reply couldn't tell which to go out of")
		}
		c, err := net.ListenUDP("udp", net.UDPAddrFromAddrPort(netip.AddrPortFrom(host, port)))
		if err != nil {
			b.closeAll()
			return nil, 0, err
		}
		port = uint16(c.LocalAddr().(*net.UDPAddr).Port)
		if host.Is4() {
			b.v4 = c
		} else {
			b.v6 = c
		}
		fns = append(fns, b.receiveOn(c))
	}
	b.port = port
	b.broken = false
	return fns, port, nil
}

func (b *hostBind) receiveOn(c *net.UDPConn) conn.ReceiveFunc {
	return func(packets [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
		n, from, err := c.ReadFromUDPAddrPort(packets[0])
		if err != nil {
			// wireguard-go stops reading this socket after most errors, and never reads it again.
			b.failed(c)
			return 0, err
		}
		sizes[0] = n
		eps[0] = endpoint{netip.AddrPortFrom(from.Addr().Unmap(), from.Port())}
		return 1, nil
	}
}

func (b *hostBind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.closeAll()
}

// closeAll closes the sockets. One closed already isn't an error: closing it again changes nothing,
// and wireguard-go doesn't listen again after a Close that failed, see failed.
func (b *hostBind) closeAll() error {
	var err error
	for _, c := range []*net.UDPConn{b.v4, b.v6} {
		if c != nil {
			if e := c.Close(); !errors.Is(e, net.ErrClosed) {
				err = errors.Join(err, e)
			}
		}
	}
	b.v4, b.v6 = nil, nil
	return err
}

func (b *hostBind) Send(bufs [][]byte, ep conn.Endpoint) error {
	e, ok := ep.(endpoint)
	if !ok {
		return conn.ErrWrongEndpointType
	}
	b.mu.Lock()
	c := b.v6
	if e.Addr().Is4() {
		c = b.v4
	}
	b.mu.Unlock()
	if c == nil {
		return net.ErrClosed
	}
	for _, buf := range bufs {
		if _, err := c.WriteToUDPAddrPort(buf, e.AddrPort); err != nil {
			if deadSocket(err) {
				b.failed(c)
			}
			return err
		}
	}
	return nil
}

// failed tells the server that c failed underneath the bind. iOS closes a suspended app's sockets:
// during a phone call Tether is suspended, and at the call's end its reads fail with "socket is not
// connected" and its sends with "broken pipe" (#106). Nothing reads the socket again, so devices get
// no reply until the server listens again. A socket Close closed isn't held any more, and says nothing.
func (b *hostBind) failed(c *net.UDPConn) {
	b.mu.Lock()
	held := c == b.v4 || c == b.v6
	if held {
		b.broken = true
	}
	died := b.died
	b.mu.Unlock()
	if held && died != nil {
		died()
	}
}

// deadSocket says a send failed because the socket is gone, not because of where it went: a device
// that left the hotspot, or a full buffer, is no reason to listen again.
func deadSocket(err error) bool {
	return errors.Is(err, syscall.EPIPE) || errors.Is(err, syscall.ENOTCONN) || errors.Is(err, net.ErrClosed)
}

func (b *hostBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	ap, err := netip.ParseAddrPort(s)
	return endpoint{ap}, err
}

func (b *hostBind) SetMark(uint32) error { return nil }
func (b *hostBind) BatchSize() int       { return 1 }
