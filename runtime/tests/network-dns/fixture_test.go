package main

import (
	"bytes"
	"encoding/binary"
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
	if got := answer(question("royd-probe.test", 28), ip); len(got) != len(query) || got[7] != 0 || got[3] != 0 {
		t.Fatal("AAAA must return NODATA, not a fabricated address")
	}
	if got := answer(question("other.test", 1), ip); got[3] != 3 || got[7] != 0 {
		t.Fatal("unknown names must not be forwarded")
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

func TestAssessment(t *testing.T) {
	good := `{"uid":10054,"done":true,"direct_udp_dns":"pass","literal_http":"pass","active_network":"100","network_count":1,"default_callback_available":1,"system_dns_addresses":["172.17.0.1"]}`
	cases := []struct{ name, from, to string }{
		{"root", "10054", "0"}, {"incomplete", "true", "false"},
		{"control", `"direct_udp_dns":"pass"`, `"direct_udp_dns":"fail"`},
		{"http", `"literal_http":"pass"`, `"literal_http":"fail"`},
		{"no-network", `"100"`, `"null"`}, {"no-networks", `"network_count":1`, `"network_count":0`},
		{"no-callback", `"default_callback_available":1`, `"default_callback_available":0`},
		{"wrong-answer", "172.17.0.1", "172.17.0.2"},
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
