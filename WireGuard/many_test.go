package main

import (
	"fmt"
	"net"
	"net/netip"
	"os"
	"runtime"
	"sort"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// setupMany starts a server with n devices at 10.7.0.2 and up.
func setupMany(t *testing.T, n int) (*Server, []*client, []netip.Addr) {
	sPriv, sPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	var peers []Peer
	var privs [][32]byte
	var addrs []netip.Addr
	for i := range n {
		priv, pub := keyPair(t)
		addr := netip.AddrFrom4([4]byte{10, 7, 0, byte(2 + i)})
		peers = append(peers, Peer{PublicKey: pub, Address: addr})
		privs = append(privs, priv)
		addrs = append(addrs, addr)
	}
	if err := s.SetPeers(peers); err != nil {
		t.Fatal(err)
	}
	clients := make([]*client, n)
	for i := range n {
		clients[i] = newClient(t, s, sPub, privs[i], addrs[i])
	}
	return s, clients, addrs
}

// pings sends count UDP pings from c to an echo server and returns the round trips of those that
// came back.
func pings(c *client, echo string, count int, wait time.Duration) ([]time.Duration, error) {
	conn, err := c.net.Dial("udp", echo)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	var rtts []time.Duration
	buf := make([]byte, 1500)
	for p := range count {
		msg := fmt.Sprintf("ping %d", p)
		sent := time.Now()
		conn.SetDeadline(sent.Add(wait))
		conn.Write([]byte(msg))
		for {
			n, err := conn.Read(buf)
			if err != nil {
				break // lost
			}
			if string(buf[:n]) == msg {
				rtts = append(rtts, time.Since(sent))
				break
			}
		}
	}
	return rtts, nil
}

// downloadAndPing has every device download and ping at the same time. It returns how long each
// device took and how many pings were lost.
func downloadAndPing(t *testing.T, clients []*client, tcp string, size, downloads, count int, echo string) ([]time.Duration, int, []error) {
	var wg sync.WaitGroup
	var mu sync.Mutex
	var errs []error
	var lost atomic.Int64
	took := make([]time.Duration, len(clients))
	for i, c := range clients {
		wg.Add(1)
		go func() {
			defer wg.Done()
			began := time.Now()
			var inner sync.WaitGroup
			for range downloads {
				inner.Add(1)
				go func() {
					defer inner.Done()
					if n, err := fetch(t, c, tcp); err != nil || n != size {
						mu.Lock()
						errs = append(errs, fmt.Errorf("device %d got %d of %d bytes: %v", i, n, size, err))
						mu.Unlock()
					}
				}()
			}
			inner.Add(1)
			go func() {
				defer inner.Done()
				rtts, err := pings(c, echo, count, 2*time.Second)
				if err != nil {
					mu.Lock()
					errs = append(errs, fmt.Errorf("device %d udp: %v", i, err))
					mu.Unlock()
				}
				lost.Add(int64(count - len(rtts)))
			}()
			inner.Wait()
			took[i] = time.Since(began)
		}()
	}
	wg.Wait()
	return took, int(lost.Load()), errs
}

// Many devices download at the same time, then ping at the same time. Each gets all its bytes and
// its echoes, and is listed as connected. Small, since CI runs it under the race detector, which
// slows gVisor down a hundredfold. TestLoadManyDevices is the big version.
func TestManyDevicesAtOnce(t *testing.T) {
	const devices, count = 8, 3
	s, clients, addrs := setupMany(t, devices)
	_, _, errs := downloadAndPing(t, clients, tcpServer(t, 8<<10), 8<<10, 2, 0, udpEcho(t))
	for _, err := range errs {
		t.Error(err)
	}
	echo := udpEcho(t)
	var wg sync.WaitGroup
	for i, c := range clients {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rtts, err := pings(c, echo, count, 10*time.Second)
			if err != nil || len(rtts) != count {
				t.Errorf("device %d got %d of %d echoes: %v", i, len(rtts), count, err)
			}
		}()
	}
	wg.Wait()
	s.readHandshakes()
	connected := map[string]bool{}
	for _, a := range s.Stats().Connected {
		connected[a] = true
	}
	for _, a := range addrs {
		if !connected[a.String()] {
			t.Errorf("%v isn't listed as connected", a)
		}
	}
}

func envInt(name string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil {
		return v
	}
	return def
}

func needLoad(t *testing.T) {
	if os.Getenv("LOAD") == "" {
		t.Skip("a measurement: set LOAD=1, without -race")
	}
}

// Throughput, fairness and UDP loss with DEVICES devices downloading at once. Both ends run in
// this process, so it measures the server's limits on this computer, not the iPhone's.
func TestLoadManyDevices(t *testing.T) {
	needLoad(t)
	devices, downloads, size := envInt("DEVICES", 12), envInt("DOWNLOADS", 3), envInt("SIZE", 2<<20)
	_, clients, _ := setupMany(t, devices)
	start := time.Now()
	took, lost, errs := downloadAndPing(t, clients, tcpServer(t, size), size, downloads, 20, udpEcho(t))
	total := time.Since(start)
	for _, err := range errs {
		t.Error(err)
	}
	sort.Slice(took, func(a, b int) bool { return took[a] < took[b] })
	mb := float64(devices*downloads*size) / (1 << 20)
	t.Logf("%d devices, %d downloads of %d KB each: %.0f MB in %v (%.0f MB/s). Per device: fastest %v, slowest %v. UDP pings lost: %d of %d",
		devices, downloads, size>>10, mb, total.Round(time.Millisecond), mb/total.Seconds(),
		took[0].Round(time.Millisecond), took[len(took)-1].Round(time.Millisecond), lost, devices*20)
}

// How long one device's pings take while another device downloads on STREAMS connections.
func TestLoadPingsWhileAnotherDeviceDownloads(t *testing.T) {
	needLoad(t)
	streams := envInt("STREAMS", 8)
	_, clients, _ := setupMany(t, 2)
	tcp, echo := tcpServer(t, 64<<20), udpEcho(t)
	ping := func(label string) {
		rtts, err := pings(clients[1], echo, 200, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		if len(rtts) == 0 {
			t.Errorf("%s: all 200 pings lost", label)
			return
		}
		sort.Slice(rtts, func(a, b int) bool { return rtts[a] < rtts[b] })
		t.Logf("%s: lost %d of 200, median %v, 95th %v, worst %v", label, 200-len(rtts),
			rtts[len(rtts)/2].Round(time.Microsecond), rtts[len(rtts)*95/100].Round(time.Microsecond), rtts[len(rtts)-1].Round(time.Microsecond))
	}
	ping("idle")
	stop := make(chan struct{})
	var wg sync.WaitGroup
	for range streams {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				fetch(t, clients[0], tcp)
			}
		}()
	}
	time.Sleep(time.Second)
	ping(fmt.Sprintf("other device downloading on %d streams", streams))
	close(stop)
	wg.Wait()
}

// The memory DEVICES devices take, each holding EACH idle connections (its cap by default).
func TestLoadMemoryAtTheConnectionCap(t *testing.T) {
	needLoad(t)
	devices, each := envInt("DEVICES", 4), envInt("EACH", maxConns)
	_, clients, _ := setupMany(t, devices)
	hold := holdServer(t)
	inUse := func() uint64 {
		runtime.GC()
		var m runtime.MemStats
		runtime.ReadMemStats(&m)
		return m.HeapInuse + m.StackInuse
	}
	before, goroutines := inUse(), runtime.NumGoroutine()
	var mu sync.Mutex
	var open []net.Conn
	var refused int
	var wg sync.WaitGroup
	for _, c := range clients {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range each {
				conn, err := openHeld(c, hold)
				mu.Lock()
				if err != nil {
					refused++
				} else {
					open = append(open, conn)
				}
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	t.Cleanup(func() {
		for _, c := range open {
			c.Close()
		}
	})
	if len(open) == 0 {
		t.Fatal("no connection opened")
	}
	after := inUse()
	// The devices' own netstacks run in this process too, so this counts both ends of each one.
	t.Logf("%d devices, %d open, %d refused: heap and stacks %d MB -> %d MB (%d KB per connection, both ends), goroutines %d -> %d",
		devices, len(open), refused, before>>20, after>>20, (after-before)/uint64(len(open))>>10,
		goroutines, runtime.NumGoroutine())
}

// A travel router and devices that connect directly, all busy at once: the router's client and
// each device get all their bytes and echoes, the router keeps its role, and no device takes it.
func TestARouterAndDevicesAtOnce(t *testing.T) {
	const devices, count = 3, 3
	sPriv, sPub := keyPair(t)
	s, err := Start(loopback, 0, sPriv)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	viaLoopback(s)
	routerPriv, routerPub := keyPair(t)
	routerAddr := netip.MustParseAddr("10.7.0.2")
	peers := []Peer{{PublicKey: routerPub, Address: routerAddr}}
	var privs [][32]byte
	var addrs []netip.Addr
	for i := range devices {
		priv, pub := keyPair(t)
		addr := netip.AddrFrom4([4]byte{10, 7, 0, byte(3 + i)})
		peers = append(peers, Peer{PublicKey: pub, Address: addr})
		privs = append(privs, priv)
		addrs = append(addrs, addr)
	}
	if err := s.SetPeers(peers); err != nil {
		t.Fatal(err)
	}
	// The router's client sends from its own address on the router's LAN.
	clients := []*client{newClient(t, s, sPub, routerPriv, netip.MustParseAddr("192.168.4.20"))}
	for i := range devices {
		clients = append(clients, newClient(t, s, sPub, privs[i], addrs[i]))
	}
	// The router's first packet is the one that makes it the router, and it's dropped. Its first
	// connection is sent again, so it's the router before the rest starts.
	if _, err := fetch(t, clients[0], tcpServer(t, 10)); err != nil {
		t.Fatal(err)
	}
	_, _, errs := downloadAndPing(t, clients, tcpServer(t, 8<<10), 8<<10, 2, 0, udpEcho(t))
	for _, err := range errs {
		t.Error(err)
	}
	echo := udpEcho(t)
	var wg sync.WaitGroup
	for i, c := range clients {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rtts, err := pings(c, echo, count, 10*time.Second)
			if err != nil || len(rtts) != count {
				t.Errorf("client %d got %d of %d echoes: %v", i, len(rtts), count, err)
			}
		}()
	}
	wg.Wait()
	if r := s.routerOf(); r != routerAddr {
		t.Fatalf("router %v, want %v", r, routerAddr)
	}
}
