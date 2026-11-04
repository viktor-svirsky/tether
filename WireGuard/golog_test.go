package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// The server's lines for the log Swift shares (#77), see golog.go.

var t0 = time.Date(2026, 11, 4, 10, 42, 33, 120e6, time.UTC)

func texts(m logMessage) []string {
	out := make([]string, len(m.Lines))
	for i, l := range m.Lines {
		out[i] = l.Text
	}
	return out
}

func TestTheLogKeepsLinesInOrderWithTheirTimes(t *testing.T) {
	l := newLineLog()
	l.add(t0, "Interface up requested")
	l.add(t0.Add(time.Second), "UDP bind has been updated")
	m, ok := l.take(t0.Add(2 * time.Second))
	if !ok || len(m.Lines) != 2 || m.Lines[0].Text != "Interface up requested" || m.Lines[0].At != t0.UnixMilli() ||
		m.Lines[1].At != t0.Add(time.Second).UnixMilli() || m.Dropped != 0 || m.V != messageVersion {
		t.Fatalf("%+v %v", m, ok)
	}
	if m, ok := l.take(t0.Add(3 * time.Second)); ok {
		t.Fatalf("taken again: %+v", m)
	}
}

// Swift takes the lines every few seconds. A log nobody takes keeps the newest, and says how many it lost.
func TestTheLogKeepsTheNewestLinesUpToItsCap(t *testing.T) {
	l := newLineLog()
	for i := 1; i <= logCap+5; i++ {
		l.add(t0.Add(time.Duration(i)*time.Millisecond), fmt.Sprint("line ", i))
	}
	m, _ := l.take(t0.Add(time.Minute))
	if len(m.Lines) != logCap || m.Dropped != 5 || m.Lines[0].Text != "line 6" || m.Lines[logCap-1].Text != fmt.Sprint("line ", logCap+5) {
		t.Fatalf("%d lines, %d dropped, first %q", len(m.Lines), m.Dropped, m.Lines[0].Text)
	}
}

// A line that comes again and again, like a dropped packet's, is kept once a minute with a count.
func TestARepeatedLineIsCountedNotKept(t *testing.T) {
	l := newLineLog()
	for i := 0; i < 100; i++ {
		l.add(t0.Add(time.Duration(i)*100*time.Millisecond), "IPv6 packet with disallowed source address from device 10.7.0.3")
	}
	l.add(t0.Add(61*time.Second), "IPv6 packet with disallowed source address from device 10.7.0.3")
	m, _ := l.take(t0.Add(62 * time.Second))
	want := []string{
		"IPv6 packet with disallowed source address from device 10.7.0.3",
		"IPv6 packet with disallowed source address from device 10.7.0.3 (99 more times since it was last logged)",
	}
	if got := texts(m); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("%q", got)
	}
}

// Two lines that take turns are each counted too.
func TestLinesThatTakeTurnsAreCountedEach(t *testing.T) {
	l := newLineLog()
	for i := 0; i < 10; i++ {
		l.add(t0.Add(time.Duration(i)*time.Second), "a")
		l.add(t0.Add(time.Duration(i)*time.Second), "b")
	}
	if m, _ := l.take(t0.Add(10 * time.Second)); strings.Join(texts(m), " ") != "a b" {
		t.Fatalf("%q", texts(m))
	}
}

// A repeat that stops still gets its count once its minute is over, stamped when it's taken, so it
// never comes before lines taken already.
func TestARepeatThatStopsIsCountedAtTheNextTake(t *testing.T) {
	l := newLineLog()
	for i := 0; i < 5; i++ {
		l.add(t0.Add(time.Duration(i)*time.Second), "Received packet with invalid mac1")
	}
	if m, _ := l.take(t0.Add(10 * time.Second)); len(m.Lines) != 1 {
		t.Fatalf("%q, want only the first while its minute runs", texts(m))
	}
	l.add(t0.Add(20*time.Second), "Device closing")
	m, ok := l.take(t0.Add(70 * time.Second))
	if !ok || len(m.Lines) != 2 {
		t.Fatalf("%q", texts(m))
	}
	if m.Lines[0].Text != "Device closing" || m.Lines[1].Text != "Received packet with invalid mac1 (4 more times since it was last logged)" ||
		m.Lines[1].At != t0.Add(70*time.Second).UnixMilli() {
		t.Fatalf("%+v, want the count at the take, after the line before it", m.Lines)
	}
	if m, ok := l.take(t0.Add(200 * time.Second)); ok {
		t.Fatalf("counted twice: %q", texts(m))
	}
}

// The texts it remembers for counting stay few, whatever comes.
func TestTheRepeatsItRemembersStayFew(t *testing.T) {
	l := newLineLog()
	for i := 0; i < 1000; i++ {
		l.add(t0.Add(time.Duration(i)*time.Millisecond), fmt.Sprint("different ", i))
	}
	if len(l.recent) > repeatsKept {
		t.Fatalf("%d remembered, want at most %d", len(l.recent), repeatsKept)
	}
	if m, _ := l.take(t0.Add(2 * time.Second)); len(m.Lines) != 1000 {
		t.Fatalf("%d lines, want every different one", len(m.Lines))
	}
}

func TestOnlyLinesThatSaySomethingAreKept(t *testing.T) {
	for format, want := range map[string]bool{
		"Routine: decryption worker %d - started":            false,
		"%v - Routine: sequential sender - stopped":          false,
		"%v - Sending keepalive packet":                      false,
		"%v - Receiving keepalive packet":                    false,
		"%v - UAPI: Created":                                 false,
		"%v - UAPI: Adding allowedip":                        false,
		"UAPI: Updating private key":                         false,
		"%v - Received handshake initiation":                 true,
		"%v - Sending handshake response":                    true,
		"Received packet with invalid mac1":                  true,
		"Received invalid initiation message from %s":        true,
		"IPv4 packet with disallowed source address from %v": true,
		"Interface state was %s, requested %s, now %s":       true,
		"Device closing":                                     true,
	} {
		if logged(format) != want {
			t.Errorf("%q kept %v, want %v", format, !want, want)
		}
	}
}

// wireguard-go names a device by 8 characters of its public key. The log names it by its tunnel
// address, which Tether shows, and no piece of a key gets in.
func TestTheLogNamesDevicesByTheirAddress(t *testing.T) {
	s, c := setup(t)
	serverLog.reset()
	fetchAndShake(t, s, c, tcpServer(t, 10))
	all := strings.Join(texts(waitForLine(t, "device 10.7.0.2 - ")), "\n")
	if strings.Contains(all, "peer(") || strings.Contains(all, "Routine:") || strings.Contains(all, "keepalive") {
		t.Fatalf("a key's piece or noise in the log:\n%s", all)
	}
	s.keep("", "%v - Received handshake initiation", []any{"peer(AbCd…WxYz)"})
	if m, _ := serverLog.take(time.Now()); len(m.Lines) != 1 || m.Lines[0].Text != "unknown device - Received handshake initiation" {
		t.Fatalf("%q, want a device the server doesn't know named as one", texts(m))
	}
}

// A config that no longer works shows up in the log as wireguard-go says it.
func TestAStaleKnockIsLogged(t *testing.T) {
	s, _ := startOneDevice(t)
	serverLog.reset()
	_, other := keyPair(t)
	knock(t, s, other)
	waitForLine(t, "Received packet with invalid mac1")
}

func TestErrorsAreLoggedAsErrors(t *testing.T) {
	s, _ := startOneDevice(t)
	serverLog.reset()
	s.noticeError("%v - Failed to send handshake response: %v", "peer(AbCd…WxYz)", "write: no route to host")
	if m, _ := serverLog.take(time.Now()); len(m.Lines) != 1 || m.Lines[0].Text != "error: unknown device - Failed to send handshake response: write: no route to host" {
		t.Fatalf("%q", texts(m))
	}
}

// reset empties the log, and what it remembers for counting, so an earlier test's lines don't count
// as repeats in the next.
func (l *lineLog) reset() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.lines, l.dropped, l.recent = nil, 0, map[string]*repeat{}
}

// waitForLine takes the server's lines until one contains want, for up to 2 s, since wireguard-go
// logs on its own goroutines. It returns everything taken.
func waitForLine(t *testing.T, want string) logMessage {
	t.Helper()
	var all logMessage
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		m, _ := serverLog.take(time.Now())
		all.Lines = append(all.Lines, m.Lines...)
		for _, l := range m.Lines {
			if strings.Contains(l.Text, want) {
				return all
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no line with %q in:\n%s", want, strings.Join(texts(all), "\n"))
	return all
}

// The message Swift reads, from the live log. Every key it has is in testdata/log.json and the
// other way round, so the fixture WireGuardServerTests decodes is the shape Go really sends.
func TestLogMatchesTheFixtureSwiftReads(t *testing.T) {
	serverLog.reset()
	if js, ok := logJSON(); ok {
		t.Fatalf("a message with nothing to say: %s", js)
	}
	serverLog.add(time.Now(), "Device closing")
	js, ok := logJSON()
	if !ok {
		t.Fatal("no message with a line in the log")
	}
	var live logMessage
	if err := json.Unmarshal([]byte(js), &live); err != nil || live.V != messageVersion || len(live.Lines) != 1 {
		t.Fatalf("%s %v", js, err)
	}
	fixture, err := os.ReadFile("testdata/log.json")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := keys(t, []byte(js)), keys(t, fixture); got != want {
		t.Fatalf("live log has keys %s, testdata/log.json has %s: update the fixture and WireGuardServer.swift", got, want)
	}
}
