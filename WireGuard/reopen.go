package main

import (
	"fmt"
	"time"
)

// socketDied asks the refresher to listen again. The bind calls it from wireguard-go's receive
// routine, which listening again waits for, so it can't do it itself.
func (s *Server) socketDied() {
	select {
	case s.dead <- struct{}{}:
	default:
	}
}

// reopen listens again on the same port after iOS closed the server's socket while Tether was
// suspended, during a phone call say (#106). wireguard-go never reads a failed socket again, so
// before this the devices got nothing back until Tether was relaunched: opening it didn't help.
// Their sessions stay, so they carry on as soon as it listens. A try that fails, the hotspot's
// address not back yet say, is tried again. There's at most one try a second, so a socket that
// keeps failing can't spin, and the refresher reads the handshakes between them.
func (s *Server) reopen() {
	s.bind.mu.Lock()
	broken, port := s.bind.broken, s.bind.port
	s.bind.mu.Unlock()
	if !broken {
		return // listening again already: a notice, or a retry, from before it did
	}
	if wait := time.Until(s.reopened.Add(time.Second)); wait > 0 {
		s.retryIn(wait)
		return
	}
	s.reopened = time.Now()
	// A listen_port line closes the sockets and opens them again on that port. BindUpdate alone
	// would lose the port after a try that fails.
	if err := s.dev.IpcSet(fmt.Sprintf("listen_port=%d\n", port)); err != nil {
		s.keep("error: ", "can't listen again on port %d: %v", []any{port, err})
		s.retryIn(time.Second)
		return
	}
	s.keep("", "listening again on port %d after its socket was closed", []any{port})
}

// retryIn has reopen run again after d, unless a retry is coming already: every failed send
// asks, and one retry is enough. After Close nobody reads the notice, so the tries end.
func (s *Server) retryIn(d time.Duration) {
	if time.Now().Before(s.retryAt) {
		return
	}
	s.retryAt = time.Now().Add(d)
	time.AfterFunc(d, s.socketDied)
}
