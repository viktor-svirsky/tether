package main

// The server's lines for the log Settings shares (#77). wireguard-go's verbose and error lines go
// into serverLog with their times, and TetherWGLog hands them to Swift, which writes them in its own
// log between its lines. Swift takes them every few seconds, so this holds only what came since.
//
// Lines that say nothing a person could act on are left out: goroutines starting and stopping,
// keepalives, and the UAPI's lines for each change of the device list. A line that comes again and
// again, like a router's dropped packets, is kept once a minute with how many times it came between.
// wireguard-go names a device by 8 characters of its public key, and the log names it by its tunnel
// address instead, which Tether shows.

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/device"
)

const (
	logCap       = 1000        // lines kept between two takes. Swift takes them every 5 to 15 s
	repeatWithin = time.Minute // a line again within this is counted, not kept
	repeatsKept  = 64          // texts remembered for counting
)

// logMessage is what TetherWGLog returns. testdata/log.json is an example, and WireGuardServerTests
// reads it, so a change here shows up on the Swift side.
type logMessage struct {
	V     int       `json:"v"`
	Lines []logLine `json:"lines"`
	// Dropped is how many lines were lost because nobody took them in time.
	Dropped int `json:"dropped"`
}

type logLine struct {
	At   int64  `json:"at"` // Unix milliseconds
	Text string `json:"text"`
}

// lineLog holds the lines until they're taken. Safe from any goroutine.
type lineLog struct {
	mu      sync.Mutex
	lines   []logLine
	dropped int
	recent  map[string]*repeat
}

// repeat is a text kept at kept that came more times since.
type repeat struct {
	kept time.Time
	more int
}

func newLineLog() *lineLog { return &lineLog{recent: map[string]*repeat{}} }

// serverLog is every server's, so the lines of one that stopped are still there for Swift to take.
var serverLog = newLineLog()

func (l *lineLog) add(at time.Time, text string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	line := text
	if r := l.recent[text]; r != nil {
		if at.Sub(r.kept) < repeatWithin {
			r.more++
			return
		}
		if r.more > 0 {
			line = counted(text, r.more)
		}
	} else if len(l.recent) >= repeatsKept {
		l.forget(at, false)
	}
	l.recent[text] = &repeat{kept: at}
	l.push(logLine{At: at.UnixMilli(), Text: line})
}

// counted is a line that came more times than it was kept.
func counted(text string, more int) string {
	return fmt.Sprintf("%s (%d more times since it was last logged)", text, more)
}

// forget drops the texts whose minute is over, writing the count of each that came again, and all
// of them when all is set or there are still too many. A count is stamped now, not when its line
// last came, so it never lands before lines Swift already took. Runs with l.mu held.
func (l *lineLog) forget(now time.Time, all bool) {
	for text, r := range l.recent {
		if !all && now.Sub(r.kept) < repeatWithin {
			continue
		}
		if r.more > 0 {
			l.push(logLine{At: now.UnixMilli(), Text: counted(text, r.more)})
		}
		delete(l.recent, text)
	}
	if !all && len(l.recent) >= repeatsKept {
		l.forget(now, true)
	}
}

// push keeps a line, and drops the oldest once there are logCap. Runs with l.mu held.
func (l *lineLog) push(line logLine) {
	if len(l.lines) >= logCap {
		l.lines = l.lines[1:]
		l.dropped++
	}
	l.lines = append(l.lines, line)
}

// take hands over the lines kept since the last take, oldest first, and false when there are none.
// A count whose minute is over comes with them.
func (l *lineLog) take(now time.Time) (logMessage, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.forget(now, false)
	if len(l.lines) == 0 && l.dropped == 0 {
		return logMessage{}, false
	}
	m := logMessage{V: messageVersion, Lines: l.lines, Dropped: l.dropped}
	sort.SliceStable(m.Lines, func(i, j int) bool { return m.Lines[i].At < m.Lines[j].At })
	l.lines, l.dropped = nil, 0
	return m, true
}

// logJSON is the logMessage TetherWGLog returns, and false when there's nothing in it.
func logJSON() (string, bool) {
	m, ok := serverLog.take(time.Now())
	if !ok {
		return "", false
	}
	b, err := json.Marshal(m)
	if err != nil {
		return "", false // plain numbers and strings, so it can't fail
	}
	return string(b), true
}

// logged says whether a line of wireguard-go's, by its format, goes into the log.
func logged(format string) bool {
	for _, noise := range []string{"Routine:", "keepalive packet", "UAPI:"} {
		if strings.Contains(format, noise) {
			return false
		}
	}
	return true
}

// peerNames matches wireguard-go's name for a device, see peerName.
var peerNames = regexp.MustCompile(`peer\([A-Za-z0-9+/]{4}\x{2026}[A-Za-z0-9+/]{4}\)`)

// keep writes one of wireguard-go's lines into the log, a device named by its tunnel address. A
// device the server doesn't know, one being added or removed, is an unknown device. It reads the
// names without s.mu: wireguard-go logs from inside calls the server makes, see logNames.
func (s *Server) keep(prefix, format string, args []any) {
	if !logged(format) {
		return
	}
	text := fmt.Sprintf(format, args...)
	names, _ := s.logNames.Load().(map[string]netip.Addr)
	text = peerNames.ReplaceAllStringFunc(text, func(name string) string {
		if a, ok := names[name]; ok {
			return "device " + a.String()
		}
		return "unknown device"
	})
	serverLog.add(time.Now(), prefix+text)
}

// printError is where wireguard-go's errors went before the log: stdout, which a test run shows.
var printError = device.NewLogger(device.LogLevelError, "wireguard: ").Errorf

// noticeError is wireguard-go's error logger: the line goes into the log, and to stdout as before.
func (s *Server) noticeError(format string, args ...any) {
	s.keep("error: ", format, args)
	printError(format, args...)
}
