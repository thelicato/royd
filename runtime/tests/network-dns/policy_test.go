package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPolicyAssessment(t *testing.T) {
	const target = "http://172.17.0.1:43210/page/nonce"
	fixture := func(t *testing.T, resolver string) string {
		t.Helper()
		dir := t.TempDir()
		write := func(name, text string) {
			t.Helper()
			if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0600); err != nil {
				t.Fatal(err)
			}
		}
		server := ""
		for _, phase := range []string{"baseline", "blocked", "restored"} {
			state, config, owners := "disabled", "0", ""
			if phase == "blocked" {
				state, config, owners = "enabled", "2048 OEM_DENY_3_MATCH", "10096 OEM_DENY_3_MATCH\n"
			}
			write("chain-"+phase+".log", "chain:"+state+"\n")
			write("bpf-"+phase+".log", "current ownerMatch configuration: "+config+"\nsUidOwnerMap:\n"+owners)
			for i, role := range []string{"target", "control"} {
				name := phase + "-" + role
				uid, pid := 10096+i, 3000+i
				r := observation{UID: uid, PID: pid, URL: target + "?policy=" + name, Done: true, Direct: "pass", HTTP: "pass", NamedHTTP: "pass", Active: "100", Networks: 1, Callback: 1, DNS: []string{"172.17.0.1"}, Interface: "eth0", ConfiguredDNS: []string{resolver}}
				blocked := phase == "blocked" && role == "target"
				pkg, rule := "org.royd.networkprobe", "allow"
				if role == "control" {
					pkg = "org.royd.networkcontrol"
				}
				if blocked {
					rule = "deny"
					r.Direct, r.HTTP, r.NamedHTTP, r.Active = "java.io.IOException: sendto failed: EPERM", "java.net.SocketTimeoutException: connect", "java.net.UnknownHostException: denied", "null"
				} else {
					line := fmt.Sprintf("request method=%q path=%q query=%q remote=%q\n", "GET", "/page/nonce", "policy="+name, "172.17.0.2:40000")
					server += line + line
				}
				raw, _ := json.Marshal(r)
				write(name+".json", string(raw))
				write(name+".identity", fmt.Sprintf("%d %d\n", pid, uid))
				write("rule-"+name+".log", pkg+":"+rule+"\n")
			}
		}
		write("http-server.log", server)
		return dir
	}
	check := func(dir, resolver string) bool {
		_, pass := assessPolicyDirectory(dir, net.ParseIP("172.17.0.1"), net.ParseIP(resolver), target)
		return pass
	}
	for _, resolver := range []string{"172.17.0.1", "127.0.0.11"} {
		if !check(fixture(t, resolver), resolver) {
			t.Fatal("rejected complete two-UID policy evidence")
		}
	}
	cases := []struct{ name, file, from, to string }{
		{"bad-json", "blocked-target.json", "{", "bad{"},
		{"root", "baseline-target.json", `"uid":10096`, `"uid":0`},
		{"uid-drift", "restored-target.identity", "10096", "10098"},
		{"pid-mismatch", "blocked-target.identity", "3000", "3001"},
		{"stale-url", "blocked-target.json", "blocked-target", "baseline-target"},
		{"missing-done", "blocked-target.json", `"done":true`, `"done":false`},
		{"no-udp-denial", "blocked-target.json", "EPERM", "timeout"},
		{"denial-http-success", "blocked-target.json", "java.net.SocketTimeoutException: connect", "pass"},
		{"control-http-failure", "blocked-control.json", `"literal_http":"pass"`, `"literal_http":"failed"`},
		{"restoration-failure", "restored-target.json", `"hostname_http":"pass"`, `"hostname_http":"failed"`},
		{"missing-baseline-dns", "baseline-target.json", `"system_dns_addresses":["172.17.0.1"]`, `"system_dns_addresses":[]`},
		{"rule-not-denied", "rule-blocked-target.log", ":deny", ":allow"},
		{"chain-not-enabled", "chain-blocked.log", "enabled", "disabled"},
		{"chain-not-restored", "chain-restored.log", "disabled", "enabled"},
		{"missing-target-map", "bpf-blocked.log", "10096 OEM_DENY_3_MATCH", "10098 OEM_DENY_3_MATCH"},
		{"control-also-blocked", "bpf-blocked.log", "10096 OEM_DENY_3_MATCH", "10096 OEM_DENY_3_MATCH\n10097 OEM_DENY_3_MATCH"},
		{"map-read-failed", "bpf-blocked.log", "sUidOwnerMap:", "sUidOwnerMap: Failed to read"},
		{"missing-map-config", "bpf-restored.log", "current ownerMatch configuration:", "missing configuration:"},
		{"server-saw-blocked-target", "http-server.log", "policy=baseline-target", "policy=blocked-target"},
		{"server-missed-control", "http-server.log", "policy=blocked-control", "policy=other"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := fixture(t, "172.17.0.1")
			path := filepath.Join(dir, tc.file)
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			changed := strings.Replace(string(raw), tc.from, tc.to, 1)
			if changed == string(raw) {
				t.Fatal("negative mutation missed its target")
			}
			if err := os.WriteFile(path, []byte(changed), 0600); err != nil {
				t.Fatal(err)
			}
			if check(dir, "172.17.0.1") {
				t.Fatal("accepted invalid policy evidence")
			}
		})
	}
	if check(t.TempDir(), "172.17.0.1") {
		t.Fatal("accepted missing evidence")
	}
	dir := fixture(t, "172.17.0.1")
	for _, phase := range []string{"baseline", "blocked", "restored"} {
		for _, suffix := range []string{".json", ".identity"} {
			path := filepath.Join(dir, phase+"-control"+suffix)
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, []byte(strings.ReplaceAll(string(raw), "10097", "10096")), 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	if check(dir, "172.17.0.1") {
		t.Fatal("a second package sharing the same UID is not an independent control")
	}
	if _, pass := assessPolicyDirectory(t.TempDir(), nil, nil, ":invalid"); pass {
		t.Fatal("accepted invalid configuration")
	}
}
