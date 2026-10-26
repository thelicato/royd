package main

import "testing"

func TestPolicyDatagramBoundary(t *testing.T) {
	nonce := []byte("1234567890abcdef")
	for phase := 8; phase <= 13; phase++ {
		p, uid, seq := policyFields(packet(nonce, phase, 10096, 63, 64, false), nonce)
		if p != phase || uid != 10096 || seq != 63 {
			t.Fatal("policy packet identity changed")
		}
	}
	for name, data := range map[string][]byte{
		"system-exemption": packet(nonce, 8, 1000, 0, 64, false),
		"wrong-phase":      packet(nonce, 7, 10096, 0, 64, false),
		"wrong-count":      packet(nonce, 8, 10096, 0, 32, false),
		"out-of-sequence":  packet(nonce, 8, 10096, 64, 64, false),
		"wrong-nonce":      packet([]byte("different nonce!"), 8, 10096, 0, 64, false),
		"segmented":        packet(nonce, 8, 10096, 0, 64, true),
		"short":            make([]byte, 19),
	} {
		t.Run(name, func(t *testing.T) { reject(t, func() { policyFields(data, nonce) }) })
	}
}
func TestPolicyPushRefusesUnownedOrUnboundedRequests(t *testing.T) {
	for _, line := range []string{
		`{"phase":10,"uid":10096,"count":64}`,
		`{"phase":11,"uid":10096,"count":64}`,
		`{"phase":10,"uid":10096,"count":65}`,
		`{"phase":10,"uid":10096,"count":64,"other":true}`,
		`{"phase":10,"uid":10096,"count":64} {}`,
	} {
		t.Run(line, func(t *testing.T) {
			p := &policyFixture{}
			reject(t, func() { p.push(line) })
		})
	}
}
