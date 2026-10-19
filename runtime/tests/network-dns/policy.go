package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// The OEM deny chain is cgroup BPF, not qualification of legacy metered/iptables chains.
func assessPolicyDirectory(dir string, expected, resolver net.IP, target string) (string, bool) {
	read := func(name string) []byte { raw, _ := os.ReadFile(filepath.Join(dir, name)); return raw }
	u, err := url.Parse(target)
	if u == nil {
		u = &url.URL{}
	}
	port, portErr := strconv.Atoi(u.Port())
	valid := err == nil && portErr == nil && port > 0 && port <= 65535 && u.Scheme == "http" && u.User == nil && u.RawQuery == "" && !u.ForceQuery && u.Fragment == "" && expected.To4() != nil && expected.IsPrivate() && expected.Equal(net.ParseIP(u.Hostname())) && strings.HasPrefix(u.Path, "/page/")
	identity, denial, control, restoration := valid, true, true, true
	uids := make(map[string]int)
	server := string(read("http-server.log"))
	serverOK := true
	for _, phase := range []string{"baseline", "blocked", "restored"} {
		for _, role := range []string{"target", "control"} {
			name := phase + "-" + role
			raw := read(name + ".json")
			var result observation
			var pid, uid int
			_, scanErr := fmt.Sscanf(string(read(name+".identity")), "%d %d", &pid, &uid)
			parsed := json.Unmarshal(raw, &result) == nil && scanErr == nil && result.Done && uid >= 10000 && pid > 0 && result.UID == uid && result.PID == pid && result.URL == target+"?policy="+name
			if phase == "baseline" {
				uids[role] = uid
			}
			identity = identity && parsed && uid == uids[role]
			packageName := "org.royd.networkprobe"
			if role == "control" {
				packageName = "org.royd.networkcontrol"
			}
			blocked := phase == "blocked" && role == "target"
			rule := "allow"
			if blocked {
				rule = "deny"
			}
			identity = identity && strings.TrimSpace(string(read("rule-"+name+".log"))) == packageName+":"+rule
			requests := strings.Count(server, fmt.Sprintf("request method=%q path=%q query=%q ", "GET", u.Path, "policy="+name))
			if blocked {
				// Require the actual UDP permission failure, not a generic timeout alone.
				denial = parsed && strings.HasPrefix(result.Direct, "java.io.IOException: sendto failed: EPERM") && strings.HasPrefix(result.HTTP, "java.net.") && strings.HasPrefix(result.NamedHTTP, "java.net.") && result.Active == "null"
				serverOK = serverOK && requests == 0
			} else {
				_, pass := assessResolver(raw, expected, resolver)
				if role == "control" {
					control = control && pass
				} else {
					restoration = restoration && pass
				}
				serverOK = serverOK && requests == 2
			}
		}
	}
	identity = identity && uids["target"] != uids["control"]
	mapOK := true
	for _, phase := range []string{"baseline", "blocked", "restored"} {
		state := "disabled"
		if phase == "blocked" {
			state = "enabled"
		}
		mapOK = mapOK && strings.TrimSpace(string(read("chain-"+phase+".log"))) == "chain:"+state
		maps := string(read("bpf-" + phase + ".log"))
		configuration := regexp.MustCompile(`(?m)^\s*current ownerMatch configuration: ([0-9]+)([^\n]*)`).FindStringSubmatch(maps)
		configRead := false
		if len(configuration) == 3 {
			bits, err := strconv.ParseUint(configuration[1], 10, 32)
			configRead = err == nil && (bits&2048 != 0) == (phase == "blocked")
		}
		config := regexp.MustCompile(`(?m)^\s*current ownerMatch configuration: [0-9]+[^\n]*\bOEM_DENY_3_MATCH\b`).MatchString(maps)
		owner := func(uid int) bool {
			return regexp.MustCompile(`(?m)^\s*` + strconv.Itoa(uid) + `\s+[^\n]*\bOEM_DENY_3_MATCH\b`).MatchString(maps)
		}
		mapOK = mapOK && configRead && strings.Contains(maps, "sUidOwnerMap") && !strings.Contains(maps, "Failed to") && config == (phase == "blocked") && owner(uids["target"]) == (phase == "blocked") && !owner(uids["control"])
	}
	status := func(ok bool) string {
		if ok {
			return "pass"
		}
		return "fail"
	}
	return fmt.Sprintf("POLICY_OBSERVATION_STATUS=%s\nPOLICY_DENIAL_STATUS=%s\nPOLICY_CONTROL_STATUS=%s\nPOLICY_RESTORATION_STATUS=%s\nPOLICY_MAP_STATUS=%s\nPOLICY_SERVER_STATUS=%s\n", status(identity), status(denial), status(control), status(restoration), status(mapOK), status(serverOK)), identity && denial && control && restoration && mapOK && serverOK
}
