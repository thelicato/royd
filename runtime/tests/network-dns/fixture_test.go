package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"net"
	"strings"
	"testing"
)

func question(name string, kind uint16) []byte {
	packet := []byte{0x4a, 0x31, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0}
	for _, label := range strings.Split(name, ".") {
		packet = append(packet, byte(len(label)))
		packet = append(packet, label...)
	}
	packet = append(packet, 0, 0, 0, 0, 1)
	binary.BigEndian.PutUint16(packet[len(packet)-4:len(packet)-2], kind)
	return packet
}

func TestAnswers(t *testing.T) {
	ip := net.ParseIP("172.17.0.1")
	query := question("royd-probe.test", 1)
	response := answer(query, ip)
	if len(response) != len(query)+16 || response[7] != 1 || response[2]&0x80 == 0 ||
		!bytes.Equal(response[:2], query[:2]) || !bytes.Equal(response[len(response)-4:], ip.To4()) {
		t.Fatalf("invalid A answer: %x", response)
	}
	if got := answer(question("ROYD-PROBE.TEST", 1), ip); got[7] != 1 {
		t.Fatal("DNS names are case-insensitive")
	}
	if got := answer(question("recovery.royd-probe.test", 1), ip); got[7] != 1 {
		t.Fatal("recovery must resolve its separate, previously unused name")
	}
	if got := answer(question("royd-probe.test", 28), ip); len(got) != len(query) || got[7] != 0 || got[3] != 0 {
		t.Fatal("AAAA must return NODATA, not a fabricated address")
	}
	if got := answer(question("other.test", 1), ip); got[3] != 3 || got[7] != 0 {
		t.Fatal("unknown names must not be forwarded")
	}
	if got := answer(question("other.royd-probe.test", 1), ip); got[3] != 3 || got[7] != 0 {
		t.Fatal("the recovery name must not enable arbitrary subdomains")
	}
	for length := 0; length < len(query); length++ {
		if answer(query[:length], ip) != nil {
			t.Fatalf("accepted truncated query %d", length)
		}
	}
	for _, offset := range []int{2, 4, 12} {
		bad := append([]byte(nil), query...)
		bad[offset] = 0xc0
		if answer(bad, ip) != nil {
			t.Fatalf("accepted malformed query at %d", offset)
		}
	}
}

func TestRecoveryAssessment(t *testing.T) {
	before, after := "http://172.17.0.1:43210/page/first", "http://172.17.0.1:43211/page/second"
	good := [3]recoveryPhase{
		{Phase: "baseline", UID: 10054, PID: 900, Elapsed: 1000, Done: true, Active: "100", Interface: "eth0", Resolvers: []string{"172.17.0.1"}, URL: before, Host: "royd-probe.test", DNS: []string{"172.17.0.1"}, Literal: "pass", Named: "pass", Events: []string{"available:100"}},
		{Phase: "lost", UID: 10054, PID: 900, Elapsed: 2000, Done: true, Active: "null", URL: before, Literal: "failed", LiteralError: "java.net.ConnectException", Events: []string{"available:100", "lost:100"}},
		{Phase: "recovered", UID: 10054, PID: 900, Elapsed: 3000, Done: true, Active: "101", Interface: "eth0", Resolvers: []string{"172.17.0.1"}, URL: after, Host: "recovery.royd-probe.test", DNS: []string{"172.17.0.1"}, Literal: "pass", Named: "pass", Events: []string{"available:100", "lost:100", "available:101"}},
	}
	check := func(p [3]recoveryPhase, resolver string) bool {
		_, pass := assessRecovery(p, net.ParseIP("172.17.0.1"), net.ParseIP(resolver), before, after, 10054, 900)
		return pass
	}
	if !check(good, "172.17.0.1") {
		t.Fatal("rejected complete same-process recovery")
	}
	cases := map[string]func(*[3]recoveryPhase){
		"root":                  func(p *[3]recoveryPhase) { p[0].UID = 0 },
		"changed-uid":           func(p *[3]recoveryPhase) { p[2].UID++ },
		"changed-pid":           func(p *[3]recoveryPhase) { p[1].PID++ },
		"wrong-phase":           func(p *[3]recoveryPhase) { p[2].Phase = "baseline" },
		"incomplete":            func(p *[3]recoveryPhase) { p[1].Done = false },
		"unordered":             func(p *[3]recoveryPhase) { p[2].Elapsed = p[0].Elapsed },
		"baseline-dns":          func(p *[3]recoveryPhase) { p[0].DNS = nil },
		"recovery-dns":          func(p *[3]recoveryPhase) { p[2].DNS = []string{"172.17.0.9"} },
		"cached-name":           func(p *[3]recoveryPhase) { p[2].Host = p[0].Host },
		"stale-nonce":           func(p *[3]recoveryPhase) { p[2].URL = before },
		"wrong-resolver":        func(p *[3]recoveryPhase) { p[2].Resolvers = []string{"172.17.0.2"} },
		"wrong-interface":       func(p *[3]recoveryPhase) { p[2].Interface = "eth1" },
		"no-baseline-callback":  func(p *[3]recoveryPhase) { p[0].Events = nil },
		"no-loss-callback":      func(p *[3]recoveryPhase) { p[1].Events = []string{"available:100"} },
		"no-recovery-callback":  func(p *[3]recoveryPhase) { p[2].Events = p[1].Events },
		"callback-order":        func(p *[3]recoveryPhase) { p[2].Events = []string{"lost:100", "available:100", "available:101"} },
		"loss-network-remains":  func(p *[3]recoveryPhase) { p[1].Active = "100" },
		"loss-resolver-remains": func(p *[3]recoveryPhase) { p[1].Resolvers = []string{"172.17.0.1"} },
		"loss-http-succeeds":    func(p *[3]recoveryPhase) { p[1].Literal = "pass" },
		"loss-error-missing":    func(p *[3]recoveryPhase) { p[1].LiteralError = "" },
		"same-network-id":       func(p *[3]recoveryPhase) { p[2].Active = "100" },
		"recovery-http":         func(p *[3]recoveryPhase) { p[2].Literal = "failed" },
		"recovery-named-http":   func(p *[3]recoveryPhase) { p[2].Named = "failed" },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			var p [3]recoveryPhase
			raw, _ := json.Marshal(good)
			if err := json.Unmarshal(raw, &p); err != nil {
				t.Fatal(err)
			}
			change(&p)
			if check(p, "172.17.0.1") {
				t.Fatal("accepted invalid recovery")
			}
		})
	}
	for i := range good {
		good[i].Resolvers = nil
		if i != 1 {
			good[i].Resolvers = []string{"127.0.0.11"}
		}
	}
	if !check(good, "127.0.0.11") {
		t.Fatal("rejected Docker embedded resolver")
	}
	if check(good, "172.17.0.1") {
		t.Fatal("accepted mismatched resolver")
	}
	if _, pass := assessRecovery(good, net.ParseIP("172.17.0.1"), net.ParseIP("127.0.0.11"), before, before, 10054, 900); pass {
		t.Fatal("accepted reused nonce URL")
	}
}

func TestAssessment(t *testing.T) {
	good := `{"uid":10054,"done":true,"direct_udp_dns":"pass","literal_http":"pass","hostname_http":"pass","active_interface":"eth0","configured_dns":["172.17.0.1"],"active_network":"100","network_count":1,"default_callback_available":1,"system_dns_addresses":["172.17.0.1"]}`
	cases := []struct{ name, from, to string }{
		{"root", "10054", "0"}, {"incomplete", "true", "false"},
		{"control", `"direct_udp_dns":"pass"`, `"direct_udp_dns":"fail"`},
		{"http", `"literal_http":"pass"`, `"literal_http":"fail"`},
		{"hostname-http", `"hostname_http":"pass"`, `"hostname_http":"fail"`},
		{"wrong-interface", "eth0", "eth1"},
		{"wrong-resolver", `"configured_dns":["172.17.0.1"]`, `"configured_dns":["172.17.0.2"]`},
		{"no-network", `"100"`, `"null"`}, {"no-networks", `"network_count":1`, `"network_count":0`},
		{"no-callback", `"default_callback_available":1`, `"default_callback_available":0`},
		{"wrong-answer", `"system_dns_addresses":["172.17.0.1"]`, `"system_dns_addresses":["172.17.0.2"]`},
	}
	if _, pass := assess([]byte(good), net.ParseIP("172.17.0.1")); !pass {
		t.Fatal("rejected complete positive evidence")
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, pass := assess([]byte(strings.Replace(good, tc.from, tc.to, 1)), net.ParseIP("172.17.0.1")); pass {
				t.Fatal("accepted invalid observation")
			}
		})
	}
	for _, raw := range []string{"", "{}", "not-json"} {
		if _, pass := assess([]byte(raw), net.ParseIP("172.17.0.1")); pass {
			t.Fatal("accepted missing results")
		}
	}
}

func TestEmbeddedResolver(t *testing.T) {
	raw := []byte(`{"uid":10054,"done":true,"direct_udp_dns":"pass","literal_http":"pass","hostname_http":"pass","active_interface":"eth0","configured_dns":["127.0.0.11"],"active_network":"100","network_count":1,"default_callback_available":1,"system_dns_addresses":["172.18.0.1"]}`)
	if _, pass := assessResolver(raw, net.ParseIP("172.18.0.1"), net.ParseIP("127.0.0.11")); !pass {
		t.Fatal("embedded resolver and returned address have different roles")
	}
	if _, pass := assess(raw, net.ParseIP("172.18.0.1")); pass {
		t.Fatal("accepted a different published resolver")
	}
	if _, pass := assessResolver(raw, net.ParseIP("172.18.0.1"), nil); pass {
		t.Fatal("accepted an invalid expected resolver")
	}
}
