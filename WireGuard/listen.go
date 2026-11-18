package main

import (
	"errors"
	"fmt"
	"net/netip"
)

// ListenOn listens on hosts instead, on the same port, and keeps every device's session. On a
// carrier that gives the iPhone IPv6 only, the hotspot comes back with 172.20.10.1 before its IPv6
// address, and a restart to listen there too dropped every device a second time (#219). An address
// that can't be listened on yet leaves the server listening where it did, and returns the error.
func (s *Server) ListenOn(hosts []netip.Addr) error {
	if len(hosts) == 0 {
		return errors.New("no address to listen on")
	}
	s.bind.mu.Lock()
	old, port, broken := s.bind.hosts, s.bind.port, s.bind.broken
	s.bind.hosts = hosts
	s.bind.mu.Unlock()
	// A listen_port line closes the sockets and opens them again on that port, as reopen does.
	err := s.dev.IpcSet(fmt.Sprintf("listen_port=%d\n", port))
	if err == nil {
		// The proxy follows the hotspot's addresses, which may be back. If iOS had closed the
		// sockets, reopen won't see it now, so the proxy listens again here.
		s.wakeProxy(broken)
		return nil
	}
	s.bind.mu.Lock()
	s.bind.hosts = old
	s.bind.mu.Unlock()
	if again := s.dev.IpcSet(fmt.Sprintf("listen_port=%d\n", port)); again != nil {
		// Not listening anywhere now. The refresher listens again on the old addresses, as after
		// iOS closed the sockets, until it works.
		s.bind.mu.Lock()
		s.bind.broken = true
		s.bind.mu.Unlock()
		s.socketDied()
		return fmt.Errorf("%w, and listening again on the old addresses failed: %v", err, again)
	}
	s.wakeProxy(broken) // as above: listening again cleared broken, so reopen won't run
	return err
}
