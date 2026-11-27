package main

import (
	"os"
	"sync"
	"sync/atomic"

	"golang.zx2c4.com/wireguard/tun"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
)

// stackTun is a tun.Device whose other end is the gVisor stack instead of the kernel.
type stackTun struct {
	ep       *channel.Endpoint
	events   chan tun.Event
	incoming chan *buffer.View
	done     chan struct{}
	once     sync.Once
	// timeWait says a packet is a SYN to drop, see synInTimeWait. Nil in tests that make a
	// stackTun of their own.
	timeWait func([]byte) bool
	// dropped counts the packets for devices that found incoming full: TCP's from WriteNotify and
	// UDP and ping replies from inject. Tests read it to tell this loss from any other.
	dropped atomic.Uint64
}

// It sends no up event, unlike wireguard-go's netstack TUN. Start brings the device up itself, and
// the event would bring it up a second time on another goroutine. When that one failed on a taken
// port, wireguard-go set its port to 0, and Start's Up then listened on a random port (#39).
func newStackTun() *stackTun {
	t := &stackTun{
		ep:       channel.New(queueLen, MTU, ""),
		events:   make(chan tun.Event),
		incoming: make(chan *buffer.View, queueLen),
		done:     make(chan struct{}),
	}
	t.ep.AddNotify(t)
	return t
}

func (t *stackTun) File() *os.File           { return nil }
func (t *stackTun) Name() (string, error)    { return "tether", nil }
func (t *stackTun) MTU() (int, error)        { return MTU, nil }
func (t *stackTun) Events() <-chan tun.Event { return t.events }
func (t *stackTun) BatchSize() int           { return 1 }

// Close also closes events, which ends wireguard-go's goroutine that reads them.
func (t *stackTun) Close() error {
	t.once.Do(func() { close(t.done); close(t.events); t.ep.Close() })
	return nil
}

// Read hands wireguard-go the next packet the stack sends to a device.
func (t *stackTun) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	for {
		select {
		case v := <-t.incoming:
			n, _ := v.Read(bufs[0][offset:])
			v.Release()
			if n == 0 {
				continue // any error but ErrClosed would make wireguard-go shut the device down
			}
			sizes[0] = n
			return 1, nil
		case <-t.done:
			return 0, os.ErrClosed
		}
	}
}

// Write gives the stack the packets wireguard-go decrypted.
func (t *stackTun) Write(bufs [][]byte, offset int) (int, error) {
	for _, b := range bufs {
		p := b[offset:]
		if len(p) == 0 {
			continue
		}
		if t.timeWait != nil && t.timeWait(p) {
			continue
		}
		pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(p)})
		if p[0]>>4 == 6 {
			t.ep.InjectInbound(header.IPv6ProtocolNumber, pkt)
		} else {
			t.ep.InjectInbound(header.IPv4ProtocolNumber, pkt)
		}
		pkt.DecRef()
	}
	return len(bufs), nil
}

// WriteNotify runs when the stack has a packet for a device. When wireguard-go falls behind, the
// packet is dropped like on a real network card, so one busy connection can't stall the others.
func (t *stackTun) WriteNotify() {
	pkt := t.ep.Read()
	if pkt == nil {
		return
	}
	v := pkt.ToView()
	pkt.DecRef()
	select {
	case t.incoming <- v:
	default:
		t.dropped.Add(1)
		v.Release()
	}
}

// inject sends a ready packet to its device, dropped when wireguard-go is behind, like WriteNotify.
func (t *stackTun) inject(p []byte) {
	v := buffer.NewViewWithData(p)
	select {
	case t.incoming <- v:
	case <-t.done:
		v.Release()
	default:
		t.dropped.Add(1)
		v.Release()
	}
}
