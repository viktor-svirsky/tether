package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
)

// configJSON is a configMessage with these keys and addresses, as WireGuardServer.swift sends it.
func configJSON(v int, keys [][]byte, addresses []string) string {
	var peers []string
	for i, a := range addresses {
		peers = append(peers, fmt.Sprintf(`{"key":%q,"address":%q}`, base64.StdEncoding.EncodeToString(keys[i]), a))
	}
	return fmt.Sprintf(`{"v":%d,"peers":[%s]}`, v, strings.Join(peers, ","))
}

func key(b byte) []byte {
	k := make([]byte, 32)
	k[0] = b
	return k
}

func TestParseConfig(t *testing.T) {
	peers, err := parseConfig(configJSON(1, [][]byte{key(1), key(7)}, []string{"10.7.0.2", "10.7.0.3"}))
	if err != nil || len(peers) != 2 || peers[1].PublicKey[0] != 7 || peers[1].Address.String() != "10.7.0.3" {
		t.Fatalf("%+v %v", peers, err)
	}
	if peers, err := parseConfig(`{"v":1,"peers":[]}`); err != nil || len(peers) != 0 {
		t.Fatalf("no devices is fine: %v %v", peers, err)
	}
	if _, err := parseConfig(`{"v":1,"peers":[],"paused":[]}`); err != nil {
		t.Fatalf("a key this version doesn't know is skipped, so one can be added without a new version: %v", err)
	}
	refused := map[string]string{
		"another version":           configJSON(2, [][]byte{key(1)}, []string{"10.7.0.2"}),
		"no version":                `{"peers":[]}`,
		"not JSON":                  `10.7.0.2`,
		"a short key":               configJSON(1, [][]byte{make([]byte, 31)}, []string{"10.7.0.2"}),
		"a key that isn't base64":   `{"v":1,"peers":[{"key":"not base64!","address":"10.7.0.2"}]}`,
		"a bad address":             configJSON(1, [][]byte{key(1)}, []string{"nonsense"}),
		"anything after an address": configJSON(1, [][]byte{key(1)}, []string{"10.7.0.2 router"}),
		"a repeated key":            configJSON(1, [][]byte{key(1), key(1)}, []string{"10.7.0.2", "10.7.0.3"}),
		"a repeated address":        configJSON(1, [][]byte{key(1), key(2)}, []string{"10.7.0.2", "10.7.0.2"}),
	}
	for what, js := range refused {
		if _, err := parseConfig(js); err == nil {
			t.Errorf("%s should be refused: %s", what, js)
		}
	}
}

// exported makes s the server the exports use, for one test.
func exported(t *testing.T, s *Server) {
	mu.Lock()
	server = s
	mu.Unlock()
	t.Cleanup(func() {
		mu.Lock()
		server = nil
		mu.Unlock()
	})
}

func TestConfigureWithNoServerDoesNothing(t *testing.T) {
	if err := configure(configJSON(1, [][]byte{key(1)}, []string{"10.7.0.2"})); err != nil {
		t.Fatalf("Swift sends the devices again with each start, so there's nothing to do: %v", err)
	}
	if err := configure(`{"v":9,"peers":[]}`); err == nil {
		t.Fatal("a list it can't read is an error even with no server")
	}
}

func TestConfigureReplacesTheDevices(t *testing.T) {
	s, _ := setup(t)
	exported(t, s)
	if err := configure(configJSON(1, [][]byte{key(1), key(2)}, []string{"10.7.0.5", "10.7.0.6"})); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(s.addresses(), " "); got != "10.7.0.5 10.7.0.6" {
		t.Fatalf("devices %q, want the two configured", got)
	}
}

func TestStatsWithNoServerAreNone(t *testing.T) {
	if js, ok := statsJSON(); ok {
		t.Fatalf("stats %s with no server", js)
	}
}

// The stats Swift reads, from a server with traffic and one of its two devices connected. Every key
// the live message has is in testdata/stats.json and the other way round, so the fixture
// WireGuardServerTests decodes is the shape Go really sends.
func TestStatsMatchTheFixtureSwiftReads(t *testing.T) {
	s, a, _ := setupTwo(t)
	fetchAndShake(t, s, a, tcpServer(t, 1000))
	exported(t, s)
	js, ok := statsJSON()
	if !ok {
		t.Fatal("no stats from a running server")
	}
	var live statsMessage
	if err := json.Unmarshal([]byte(js), &live); err != nil {
		t.Fatal(err)
	}
	if live.V != messageVersion || live.Up == 0 || live.Down == 0 {
		t.Fatalf("stats %s, want this version and traffic both ways", js)
	}
	if len(live.Peers) != 2 || !live.Peers[0].Connected || live.Peers[0].Address != "10.7.0.2" || live.Peers[1].Connected {
		t.Fatalf("peers %+v, want 10.7.0.2 connected and 10.7.0.3 not", live.Peers)
	}
	fixture, err := os.ReadFile("testdata/stats.json")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := keys(t, []byte(js)), keys(t, fixture); got != want {
		t.Fatalf("live stats have keys %s, testdata/stats.json has %s: update the fixture and WireGuardServer.swift", got, want)
	}
}

// keys lists every key path in a JSON document, the first element standing for each array.
func keys(t *testing.T, js []byte) string {
	var doc any
	if err := json.Unmarshal(js, &doc); err != nil {
		t.Fatal(err)
	}
	var paths []string
	var walk func(prefix string, v any)
	walk = func(prefix string, v any) {
		switch v := v.(type) {
		case map[string]any:
			for k, child := range v {
				paths = append(paths, prefix+k)
				walk(prefix+k+".", child)
			}
		case []any:
			if len(v) > 0 {
				walk(prefix+"[].", v[0])
			}
		}
	}
	walk("", doc)
	sort.Strings(paths)
	return strings.Join(paths, " ")
}

func TestRecoveredSaysWhatPanicked(t *testing.T) {
	if got := recovered("index out of range"); got != "wireguard: index out of range" {
		t.Fatalf("%q", got)
	}
}
