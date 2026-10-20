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

func TestMeteredAssessment(t *testing.T) {
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
		write("metered-initial-policy.log", "Restrict background blacklisted UIDs: none\n")
		write("metered-restored-policy.log", "Restrict background blacklisted UIDs: none\n")
		server := ""
		for _, phase := range []string{"baseline", "blocked", "restored"} {
			list := "none"
			if phase == "blocked" {
				list = "10096"
			}
			write("metered-policy-"+phase+".log", "Restrict background blacklisted UIDs: "+list+"\n")
			for i, role := range []string{"target", "control"} {
				name := phase + "-" + role
				uid, pid := 10096+i, 3000+i
				r := observation{UID: uid, PID: pid, URL: target + "?metered=" + name, Done: true, Direct: "pass", HTTP: "pass", NamedHTTP: "pass", Active: "100", Networks: 1, Callback: 1, DNS: []string{"172.17.0.1"}, Interface: "eth0", ConfiguredDNS: []string{resolver}, Metered: true, Importance: 300, ImportanceAfter: 300}
				row := "BACKGROUND_MATCH"
				if phase == "blocked" && role == "target" {
					row += " PENALTY_BOX_USER_MATCH"
					r.Direct = "java.io.IOException: sendto failed: EPERM"
					r.HTTP = "java.net.SocketTimeoutException: connect"
					r.NamedHTTP = "java.net.UnknownHostException: denied"
					r.Active = "null"
				} else {
					line := fmt.Sprintf("request method=%q path=%q query=%q remote=%q\n", "GET", "/page/nonce", "metered="+name, "172.17.0.2:40000")
					server += line + line
				}
				raw, _ := json.Marshal(r)
				write(name+".json", string(raw))
				write(name+".identity", fmt.Sprintf("%d %d\n", pid, uid))
				write("ready-"+name+".json", fmt.Sprintf(`{"uid":%d,"pid":%d}`, uid, pid))
				write("uid-state-"+name+".log", "10 (SERVICE)\n")
				write("uid-state-after-"+name+".log", "10 (SERVICE)\n")
				write("netpolicy-"+name+".log", "Metered ifaces: {eth0}\n")
				write("bpf-"+name+".log", fmt.Sprintf("current ownerMatch configuration: 4096 BACKGROUND_MATCH\nsUidOwnerMap:\n%d %s\nsUidPermissionMap:\nsDataSaverEnabledMap: false\n", uid, row))
			}
		}
		write("http-server.log", server)
		return dir
	}
	check := func(dir, resolver string) bool {
		_, pass := assessMeteredDirectory(dir, net.ParseIP("172.17.0.1"), net.ParseIP(resolver), target)
		return pass
	}
	for _, resolver := range []string{"172.17.0.1", "127.0.0.11"} {
		if !check(fixture(t, resolver), resolver) {
			t.Fatal("rejected complete background metered evidence")
		}
	}
	cases := []struct{ name, file, from, to string }{
		{"bad-json", "blocked-target.json", "{", "bad{"},
		{"root-uid", "baseline-target.json", `"uid":10096`, `"uid":0`},
		{"pid-drift", "blocked-target.identity", "3000", "3001"},
		{"ready-pid-drift", "ready-blocked-target.json", "3000", "3001"},
		{"stale-phase", "blocked-target.json", "blocked-target", "baseline-target"},
		{"not-done", "blocked-target.json", `"done":true`, `"done":false`},
		{"foreground", "blocked-target.json", `"importance":300`, `"importance":100`},
		{"became-foreground", "blocked-target.json", `"importance_after":300`, `"importance_after":100`},
		{"foreground-uid-state", "uid-state-blocked-target.log", "10 (SERVICE)", "2 (TOP)"},
		{"cached-uid-state", "uid-state-after-blocked-target.log", "10 (SERVICE)", "16 (CACHED_ACTIVITY)"},
		{"no-real-udp-denial", "blocked-target.json", "EPERM", "timeout"},
		{"raw-http-leak", "blocked-target.json", "java.net.SocketTimeoutException: connect", "pass"},
		{"control-network-failed", "blocked-control.json", `"literal_http":"pass"`, `"literal_http":"failed"`},
		{"restoration-network-failed", "restored-target.json", `"hostname_http":"pass"`, `"hostname_http":"failed"`},
		{"unmetered-control", "blocked-control.json", `"network_metered":true`, `"network_metered":false`},
		{"missing-penalty-bit", "bpf-blocked-target.log", " PENALTY_BOX_USER_MATCH", ""},
		{"cached-app-gate", "bpf-blocked-target.log", "10096 BACKGROUND_MATCH", "10096"},
		{"foreground-allow-bit", "bpf-blocked-target.log", "10096 BACKGROUND_MATCH", "10096 BACKGROUND_MATCH HAPPY_BOX_MATCH"},
		{"admin-policy-confound", "bpf-blocked-target.log", "10096 BACKGROUND_MATCH", "10096 BACKGROUND_MATCH PENALTY_BOX_ADMIN_MATCH"},
		{"map-read-failure", "bpf-blocked-target.log", "sUidOwnerMap:", "sUidOwnerMap: Failed to read"},
		{"configuration-drift", "bpf-blocked-target.log", "4096 BACKGROUND_MATCH", "6144 BACKGROUND_MATCH OEM_DENY_3_MATCH"},
		{"enabled-datasaver", "bpf-blocked-target.log", "sDataSaverEnabledMap: false", "sDataSaverEnabledMap: true"},
		{"wrong-metered-interface", "netpolicy-blocked-control.log", "eth0", "wlan0"},
		{"policy-not-set", "metered-policy-blocked.log", "10096", "none"},
		{"policy-not-restored", "metered-restored-policy.log", "none", "10096"},
		{"server-saw-blocked", "http-server.log", "metered=baseline-target", "metered=blocked-target"},
		{"server-missed-control", "http-server.log", "metered=blocked-control", "metered=other"},
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
				t.Fatal("mutation missed target")
			}
			if err := os.WriteFile(path, []byte(changed), 0600); err != nil {
				t.Fatal(err)
			}
			if check(dir, "172.17.0.1") {
				t.Fatal("accepted invalid metered evidence")
			}
		})
	}
	if check(t.TempDir(), "172.17.0.1") {
		t.Fatal("accepted missing evidence")
	}
	dir := fixture(t, "172.17.0.1")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		path := filepath.Join(dir, entry.Name())
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(strings.ReplaceAll(string(raw), "10097", "10096")), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if check(dir, "172.17.0.1") {
		t.Fatal("shared UID is not an independent metered control")
	}
}

func TestDataSaverAssessment(t *testing.T) {
	const target = "http://172.17.0.1:43210/page/nonce"
	fixture := func(t *testing.T, resolver string) string {
		dir := t.TempDir()
		write := func(name, text string) {
			t.Helper()
			if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0600); err != nil {
				t.Fatal(err)
			}
		}
		for _, name := range []string{"metered-initial-policy.log", "metered-restored-policy.log"} {
			write(name, "Restrict background blacklisted UIDs: none\n")
		}
		for _, name := range []string{"saver-initial-allowlist.log", "saver-restored-allowlist.log"} {
			write(name, "Restrict background whitelisted UIDs: none\n")
		}
		write("saver-restored.log", "Restrict background status: disabled\n")
		server := ""
		for _, phase := range []string{"baseline", "blocked", "exempt", "revoked", "foreground", "restored"} {
			enabled := phase != "baseline" && phase != "restored"
			state, allow := "disabled", "none"
			if enabled {
				state, allow = "enabled", "10097"
			}
			if phase == "exempt" {
				allow = "10096 10097"
			}
			write("saver-state-"+phase+".log", "Restrict background status: "+state+"\n")
			write("saver-allowlist-"+phase+".log", "Restrict background whitelisted UIDs: "+allow+"\n")
			write("metered-policy-"+phase+".log", "Restrict background blacklisted UIDs: none\n")
			for i, role := range []string{"target", "control"} {
				name := phase + "-" + role
				uid, pid := 10096+i, 3000+i
				foreground := phase == "foreground" && role == "target"
				r := observation{UID: uid, PID: pid, URL: target + "?metered=" + name, Done: true, Direct: "pass", HTTP: "pass", NamedHTTP: "pass", Active: "100", Networks: 1, Callback: 1, DNS: []string{"172.17.0.1"}, Interface: "eth0", ConfiguredDNS: []string{resolver}, Metered: true, Importance: 300, ImportanceAfter: 300}
				row, uidState := "BACKGROUND_MATCH", "10 (SERVICE)"
				if foreground {
					r.Importance = 100
					r.ImportanceAfter = 100
					uidState = "2 (TOP)"
					row = ""
				}
				if enabled && (role == "control" || phase == "exempt" || foreground) {
					row += " HAPPY_BOX_MATCH"
				}
				blocked := (phase == "blocked" || phase == "revoked") && role == "target"
				if blocked {
					r.Direct = "java.io.IOException: sendto failed: EPERM"
					r.HTTP = "java.net.SocketTimeoutException: connect"
					r.NamedHTTP = "java.net.UnknownHostException: denied"
					r.Active = "null"
				} else {
					line := fmt.Sprintf("request method=%q path=%q query=%q remote=%q\n", "GET", "/page/nonce", "metered="+name, "172.17.0.2:40000")
					server += line + line
				}
				raw, _ := json.Marshal(r)
				write(name+".json", string(raw))
				write(name+".identity", fmt.Sprintf("%d %d\n", pid, uid))
				write("ready-"+name+".json", fmt.Sprintf(`{"uid":%d,"pid":%d}`, uid, pid))
				write("uid-state-"+name+".log", uidState+"\n")
				write("uid-state-after-"+name+".log", uidState+"\n")
				write("netpolicy-"+name+".log", "Metered ifaces: {eth0}\n")
				write("bpf-"+name+".log", fmt.Sprintf("current ownerMatch configuration: 4096 BACKGROUND_MATCH\nsUidOwnerMap:\n%d %s\nsUidPermissionMap:\nsDataSaverEnabledMap: %t\n", uid, row, enabled))
			}
		}
		write("http-server.log", server)
		return dir
	}
	check := func(dir, resolver string) bool {
		_, pass := assessMeteredPolicyDirectory(dir, net.ParseIP("172.17.0.1"), net.ParseIP(resolver), target, true)
		return pass
	}
	for _, resolver := range []string{"172.17.0.1", "127.0.0.11"} {
		if !check(fixture(t, resolver), resolver) {
			t.Fatal("rejected complete Data Saver evidence")
		}
	}
	for _, tc := range []struct{ name, file, from, to string }{
		{"rollback", "saver-state-blocked.log", "enabled", "disabled"},
		{"map-not-enabled", "bpf-blocked-target.log", "sDataSaverEnabledMap: true", "sDataSaverEnabledMap: false"},
		{"udp-leak", "blocked-target.json", "java.io.IOException: sendto failed: EPERM", "pass"},
		{"revoked-leak", "revoked-target.json", "java.io.IOException: sendto failed: EPERM", "pass"},
		{"http-leak", "blocked-target.json", "java.net.SocketTimeoutException: connect", "pass"},
		{"server-saw-denied", "http-server.log", "metered=baseline-target", "metered=blocked-target"},
		{"lost-control", "blocked-control.json", `"literal_http":"pass"`, `"literal_http":"failed"`},
		{"lost-user-exemption", "exempt-target.json", `"literal_http":"pass"`, `"literal_http":"failed"`},
		{"lost-foreground", "foreground-target.json", `"literal_http":"pass"`, `"literal_http":"failed"`},
		{"fake-foreground", "foreground-target.json", `"importance":100`, `"importance":300`},
		{"stale-foreground", "uid-state-after-foreground-target.log", "2 (TOP)", "10 (SERVICE)"},
		{"penalty-confound", "bpf-blocked-target.log", "BACKGROUND_MATCH\nsUidPermissionMap:", "BACKGROUND_MATCH PENALTY_BOX_USER_MATCH\nsUidPermissionMap:"},
		{"unexempted-control", "bpf-blocked-control.log", " HAPPY_BOX_MATCH", ""},
		{"not-revoked", "saver-allowlist-revoked.log", "10097", "10096 10097"},
		{"unrestored-mode", "saver-restored.log", "disabled", "enabled"},
		{"unrestored-exemption", "saver-restored-allowlist.log", "none", "10097"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := fixture(t, "172.17.0.1")
			path := filepath.Join(dir, tc.file)
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			changed := strings.Replace(string(raw), tc.from, tc.to, 1)
			if changed == string(raw) {
				t.Fatal("mutation missed target")
			}
			if err := os.WriteFile(path, []byte(changed), 0600); err != nil {
				t.Fatal(err)
			}
			if check(dir, "172.17.0.1") {
				t.Fatal("accepted invalid Data Saver evidence")
			}
		})
	}
	if check(t.TempDir(), "172.17.0.1") {
		t.Fatal("accepted missing evidence")
	}
}
