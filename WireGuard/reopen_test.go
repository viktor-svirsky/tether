package main

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// closeUnder closes the server's IPv4 socket the way iOS does to a suspended app's: underneath it,
// with the bind still holding it (#106).
func closeUnder(t *testing.T, s *Server) {
	t.Helper()
	s.bind.mu.Lock()
	sock := s.bind.v4
	s.bind.mu.Unlock()
	if sock == nil {
		t.Fatal("no IPv4 socket")
	}
	sock.Close()
}

// fetchesAgain fails the test unless the device's traffic gets through again within within. A
// fetch that works only after that fails it too.
func fetchesAgain(t *testing.T, c *client, addr string, within time.Duration) {
	t.Helper()
	deadline := time.Now().Add(within)
	for {
		n, err := fetchBy(c, addr, deadline)
		if time.Now().After(deadline) {
			t.Fatalf("no traffic %v after the socket closed: %d bytes, %v", within, n, err)
		}
		if err == nil && n == 1000 {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// listenTries counts the server's tries to listen again, from wireguard-go's log.
func listenTries(t *testing.T, s *Server) *atomic.Int32 {
	t.Helper()
	var tries atomic.Int32
	heard := func(line string) {
		if strings.Contains(line, "Updating listen port") {
			tries.Add(1)
		}
	}
	s.heard.Store(&heard)
	t.Cleanup(func() { s.heard.Store(nil) })
	return &tries
}

// During a phone call iOS suspends Tether and closes its sockets. At the call's end the server's
// reads fail with "socket is not connected", and wireguard-go stops reading for good (#106). The
// server listens again by itself, on the same port the devices' configs point at, so a device's
// traffic gets through again without anyone opening Tether.
func TestTheServerReopensItsSocketAfterIOSClosedIt(t *testing.T) {
	s, c := setup(t)
	addr := tcpServer(t, 1000)
	if n, err := fetch(t, c, addr); err != nil || n != 1000 {
		t.Fatalf("before: got %d bytes, %v", n, err)
	}
	port := s.port(t)
	closeUnder(t, s)
	fetchesAgain(t, c, addr, 5*time.Second)
	if got := s.port(t); got != port {
		t.Fatalf("listening on port %d, want %d where the device's config points", got, port)
	}
}

// A try that fails, the hotspot's address not back yet say, is tried again until one works.
func TestTheServerKeepsTryingToReopenItsSocket(t *testing.T) {
	s, c := setup(t)
	addr := tcpServer(t, 1000)
	if n, err := fetch(t, c, addr); err != nil || n != 1000 {
		t.Fatalf("before: got %d bytes, %v", n, err)
	}
	tries := listenTries(t, s)
	s.bind.mu.Lock()
	hosts := s.bind.hosts
	// An address on no interface here, like a hotspot address that isn't back yet.
	s.bind.hosts = []netip.Addr{netip.MustParseAddr("192.0.2.1")}
	s.bind.mu.Unlock()
	closeUnder(t, s)
	deadline := time.Now().Add(10 * time.Second)
	for tries.Load() < 2 {
		if time.Now().After(deadline) {
			t.Fatalf("%d tries to listen again, want a second one after the first failed", tries.Load())
		}
		time.Sleep(20 * time.Millisecond)
	}
	s.bind.mu.Lock()
	s.bind.hosts = hosts
	s.bind.mu.Unlock()
	fetchesAgain(t, c, addr, 5*time.Second)
}

// A socket that fails again right after it was opened is opened again a second later, not at once,
// so one that keeps failing can't spin.
func TestASocketThatKeepsFailingIsReopenedOnceASecond(t *testing.T) {
	s, c := setup(t)
	addr := tcpServer(t, 1000)
	if n, err := fetch(t, c, addr); err != nil || n != 1000 {
		t.Fatalf("before: got %d bytes, %v", n, err)
	}
	var mu sync.Mutex
	var tries []time.Time
	heard := func(line string) {
		if strings.Contains(line, "Updating listen port") {
			mu.Lock()
			tries = append(tries, time.Now())
			mu.Unlock()
		}
	}
	s.heard.Store(&heard)
	t.Cleanup(func() { s.heard.Store(nil) })
	s.bind.mu.Lock()
	first := s.bind.v4
	s.bind.mu.Unlock()
	closeUnder(t, s)
	deadline := time.Now().Add(10 * time.Second)
	for {
		s.bind.mu.Lock()
		reopened := s.bind.v4 != nil && s.bind.v4 != first
		s.bind.mu.Unlock()
		if reopened {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("not listening again")
		}
		time.Sleep(time.Millisecond)
	}
	closeUnder(t, s)
	fetchesAgain(t, c, addr, 5*time.Second)
	mu.Lock()
	defer mu.Unlock()
	if len(tries) < 2 {
		t.Fatalf("%d tries, want one for each time the socket was closed", len(tries))
	}
	if gap := tries[1].Sub(tries[0]); gap < 900*time.Millisecond {
		t.Fatalf("the second try came %v after the first, want a second", gap)
	}
}

// While a try can't work, every failed send says the socket is dead. Once the server listens
// again, those notices, and the retries they asked for, don't close the new socket: each one would
// cut the devices off for a moment.
func TestNoticesFromBeforeTheServerListenedAgainDontReopenIt(t *testing.T) {
	s, c := setup(t)
	addr := tcpServer(t, 1000)
	if n, err := fetch(t, c, addr); err != nil || n != 1000 {
		t.Fatalf("before: got %d bytes, %v", n, err)
	}
	tries := listenTries(t, s)
	s.bind.mu.Lock()
	hosts := s.bind.hosts
	s.bind.hosts = []netip.Addr{netip.MustParseAddr("192.0.2.1")}
	s.bind.mu.Unlock()
	closeUnder(t, s)
	deadline := time.Now().Add(10 * time.Second)
	for tries.Load() < 1 {
		if time.Now().After(deadline) {
			t.Fatal("no try to listen again")
		}
		time.Sleep(10 * time.Millisecond)
	}
	for range 20 { // sends failing during the second the server waits between tries
		s.socketDied()
		time.Sleep(20 * time.Millisecond)
	}
	s.bind.mu.Lock()
	s.bind.hosts = hosts
	s.bind.mu.Unlock()
	fetchesAgain(t, c, addr, 5*time.Second)
	s.socketDied() // one more, from a send that failed just before
	n := tries.Load()
	time.Sleep(2500 * time.Millisecond)
	if got := tries.Load(); got != n {
		t.Fatalf("listened again %d more times after it was listening", got-n)
	}
	if n, err := fetch(t, c, addr); err != nil || n != 1000 {
		t.Fatalf("after: got %d bytes, %v", n, err)
	}
}

// Close ends the tries: a server that can't listen again doesn't keep trying after it's stopped.
func TestClosingTheServerEndsTheTriesToReopen(t *testing.T) {
	s, _ := setup(t)
	tries := listenTries(t, s)
	s.bind.mu.Lock()
	s.bind.hosts = []netip.Addr{netip.MustParseAddr("192.0.2.1")}
	s.bind.mu.Unlock()
	closeUnder(t, s)
	deadline := time.Now().Add(10 * time.Second)
	for tries.Load() < 1 {
		if time.Now().After(deadline) {
			t.Fatal("no try to listen again")
		}
		time.Sleep(10 * time.Millisecond)
	}
	s.Close() // before the next try, a second later
	n := tries.Load()
	time.Sleep(1500 * time.Millisecond)
	if got := tries.Load(); got != n {
		t.Fatalf("%d more tries after Close", got-n)
	}
}

// Close closes the sockets too, and that's no reason to listen again: the server is going away.
func TestClosingTheServerDoesntReopenItsSocket(t *testing.T) {
	sPriv, _ := keyPair(t)
	s, err := Start([]netip.Addr{loopback}, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	var died atomic.Int32
	s.bind.mu.Lock()
	s.bind.died = func() { died.Add(1) }
	s.bind.mu.Unlock()
	s.Close() // waits for the receive routine, which has seen its socket closed
	if n := died.Load(); n != 0 {
		t.Fatalf("told %d times that a socket died, by the server's own Close", n)
	}
}

// A send that fails because the socket is gone says so as well, in case no read is waiting to.
// The errors iOS gives for a socket it closed, and one closed underneath the bind, count. Others,
// like a device that left the hotspot, don't.
func TestASendOnADeadSocketAsksForANewOne(t *testing.T) {
	var died atomic.Int32
	b := &hostBind{hosts: []netip.Addr{loopback}, died: func() { died.Add(1) }}
	if _, _, err := b.Open(0); err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	to := endpoint{netip.AddrPortFrom(loopback, 9)}
	if err := b.Send([][]byte{[]byte("x")}, to); err != nil {
		t.Fatalf("send on a live socket: %v", err)
	}
	if died.Load() != 0 {
		t.Fatal("a live socket counted as dead")
	}
	b.mu.Lock()
	b.v4.Close()
	b.mu.Unlock()
	if err := b.Send([][]byte{[]byte("x")}, to); err == nil {
		t.Fatal("a send on a closed socket worked")
	}
	if died.Load() != 1 {
		t.Fatalf("told %d times, want once", died.Load())
	}

	opErr := func(e error) error { return &net.OpError{Op: "write", Err: os.NewSyscallError("sendto", e)} }
	for _, tc := range []struct {
		err  error
		dead bool
	}{
		{opErr(syscall.EPIPE), true},
		{opErr(syscall.ENOTCONN), true},
		{fmt.Errorf("wrapped: %w", net.ErrClosed), true},
		{opErr(syscall.EHOSTUNREACH), false},
		{opErr(syscall.ENOBUFS), false},
		{errors.New("something else"), false},
	} {
		if got := deadSocket(tc.err); got != tc.dead {
			t.Errorf("deadSocket(%v) = %v, want %v", tc.err, got, tc.dead)
		}
	}
}
