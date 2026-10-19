package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
)

// A deliberately non-recursive, two-name UDP fixture, not a production resolver.
func answer(query []byte, address net.IP) []byte {
	if len(query) < 17 || query[2]&0xfe != 0 || binary.BigEndian.Uint16(query[4:6]) != 1 || address.To4() == nil {
		return nil
	}
	offset := 12
	var labels []string
	for offset < len(query) && query[offset] != 0 {
		size := int(query[offset])
		offset++
		if size > 63 || offset+size >= len(query) {
			return nil
		}
		labels = append(labels, string(query[offset:offset+size]))
		offset += size
	}
	if offset+5 > len(query) {
		return nil
	}
	offset++
	qtype := binary.BigEndian.Uint16(query[offset : offset+2])
	qclass := binary.BigEndian.Uint16(query[offset+2 : offset+4])
	response := append([]byte(nil), query[:offset+4]...)
	response[2], response[3] = 0x84|(query[2]&1), 0
	for i := 6; i < 12; i++ {
		response[i] = 0
	}
	name := strings.Join(labels, ".")
	if (!strings.EqualFold(name, "royd-probe.test") && !strings.EqualFold(name, "recovery.royd-probe.test")) || qclass != 1 {
		response[3] = 3 // NXDOMAIN, never forward arbitrary queries.
	} else if qtype == 1 {
		response[7] = 1
		response = append(response, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 0, 0, 4)
		response = append(response, address.To4()...)
	}
	return response
}

type observation struct {
	UID           int      `json:"uid"`
	PID           int      `json:"pid"`
	URL           string   `json:"url"`
	Done          bool     `json:"done"`
	Direct        string   `json:"direct_udp_dns"`
	HTTP          string   `json:"literal_http"`
	Active        string   `json:"active_network"`
	Networks      int      `json:"network_count"`
	Callback      int      `json:"default_callback_available"`
	DNS           []string `json:"system_dns_addresses"`
	NamedHTTP     string   `json:"hostname_http"`
	Interface     string   `json:"active_interface"`
	ConfiguredDNS []string `json:"configured_dns"`
}

func assess(raw []byte, expected net.IP) (string, bool) {
	return assessResolver(raw, expected, expected)
}

func assessResolver(raw []byte, expected, resolver net.IP) (string, bool) {
	var result observation
	if json.Unmarshal(raw, &result) != nil || !result.Done || result.UID < 10000 || expected.To4() == nil || resolver.To4() == nil {
		return "OBSERVATION_STATUS=fail\n", false
	}
	control := result.Direct == "pass" && result.HTTP == "pass"
	dns := false
	for _, address := range result.DNS {
		if expected.Equal(net.ParseIP(address)) {
			dns = true
		}
	}
	configured := len(result.ConfiguredDNS) == 1 && resolver.Equal(net.ParseIP(result.ConfiguredDNS[0]))
	id, err := strconv.ParseUint(result.Active, 10, 32)
	framework := err == nil && id > 0 && result.Networks > 0 && result.Callback > 0 && result.Interface == "eth0" && configured
	dns = dns && result.NamedHTTP == "pass"
	status := func(pass bool) string {
		if pass {
			return "pass"
		}
		return "fail"
	}
	return fmt.Sprintf("OBSERVATION_STATUS=pass\nTRANSPORT_CONTROL_STATUS=%s\nSYSTEM_DNS_STATUS=%s\nFRAMEWORK_NETWORK_STATUS=%s\nTLS_STATUS=not-tested\n", status(control), status(dns), status(framework)), control && dns && framework
}

type recoveryPhase struct {
	Phase        string   `json:"phase"`
	UID          int      `json:"uid"`
	PID          int      `json:"pid"`
	Elapsed      int64    `json:"elapsed_ms"`
	Done         bool     `json:"done"`
	Active       string   `json:"active_network"`
	Interface    string   `json:"active_interface"`
	Resolvers    []string `json:"configured_dns"`
	URL          string   `json:"url"`
	Host         string   `json:"host"`
	DNS          []string `json:"system_dns_addresses"`
	Literal      string   `json:"literal_http"`
	LiteralError string   `json:"literal_error"`
	Named        string   `json:"hostname_http"`
	Events       []string `json:"events"`
}

func assessRecovery(phases [3]recoveryPhase, expected, resolver net.IP, before, after string, uid, pid int) (string, bool) {
	status := func(ok bool) string {
		if ok {
			return "pass"
		}
		return "fail"
	}
	b, l, r := phases[0], phases[1], phases[2]
	validURL := func(raw string) bool {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != "http" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return false
		}
		port, err := strconv.Atoi(u.Port())
		return err == nil && port > 0 && port <= 65535 && expected != nil && expected.IsPrivate() && expected.Equal(net.ParseIP(u.Hostname())) && strings.HasPrefix(u.Path, "/page/")
	}
	identity := uid >= 10000 && pid > 0 && validURL(before) && validURL(after) && before != after
	for i, p := range phases {
		identity = identity && p.UID == uid && p.PID == pid && p.Done && p.Phase == [3]string{"baseline", "lost", "recovered"}[i] && p.Elapsed > 0
	}
	identity = identity && b.Elapsed < l.Elapsed && l.Elapsed < r.Elapsed
	positive := func(p recoveryPhase, host, target string) bool {
		id, err := strconv.ParseUint(p.Active, 10, 32)
		return err == nil && id > 0 && p.Interface == "eth0" && len(p.Resolvers) == 1 && resolver != nil && resolver.Equal(net.ParseIP(p.Resolvers[0])) &&
			len(p.DNS) == 1 && expected.Equal(net.ParseIP(p.DNS[0])) && p.Host == host && p.URL == target && p.Literal == "pass" && p.Named == "pass"
	}
	baseline := positive(b, "royd-probe.test", before) && reflect.DeepEqual(b.Events, []string{"available:" + b.Active})
	loss := l.Active == "null" && l.Interface == "" && len(l.Resolvers) == 0 && l.URL == before && l.Literal == "failed" && l.LiteralError != "" && reflect.DeepEqual(l.Events, []string{"available:" + b.Active, "lost:" + b.Active})
	recovery := positive(r, "recovery.royd-probe.test", after) && r.Active != b.Active && reflect.DeepEqual(r.Events, []string{"available:" + b.Active, "lost:" + b.Active, "available:" + r.Active})
	return fmt.Sprintf("APP_PROCESS_STATUS=%s\nBASELINE_NETWORK_STATUS=%s\nNETWORK_LOSS_STATUS=%s\nNETWORK_RECOVERY_STATUS=%s\nTLS_STATUS=not-tested\n", status(identity), status(baseline), status(loss), status(recovery)), identity && baseline && loss && recovery
}

func main() {
	listen := flag.String("listen", "", "specific private Docker bridge IPv4 address, port 53")
	resultFile := flag.String("result", "", "assess an application JSON result without a listener")
	expected := flag.String("expected", "", "expected literal IPv4 answer")
	resolver := flag.String("resolver", "", "expected configured resolver, defaults to answer address")
	recovery := flag.String("recovery", "", "directory containing baseline/lost/recovered JSON observations")
	policy := flag.String("policy", "", "directory containing two-UID policy observations and fixture evidence")
	before := flag.String("url", "", "expected baseline nonce URL")
	after := flag.String("recovery-url", "", "expected fresh recovery nonce URL")
	uid := flag.Int("uid", 0, "observed ordinary app UID")
	pid := flag.Int("pid", 0, "observed unchanged app PID")
	flag.Parse()
	if *policy != "" {
		text, pass := assessPolicyDirectory(*policy, net.ParseIP(*expected), net.ParseIP(*resolver), *before)
		fmt.Print(text)
		if !pass {
			os.Exit(1)
		}
		return
	}
	if *recovery != "" {
		var phases [3]recoveryPhase
		for i, name := range []string{"baseline", "lost", "recovered"} {
			raw, err := os.ReadFile(filepath.Join(*recovery, name+".json"))
			if err != nil || json.Unmarshal(raw, &phases[i]) != nil {
				log.Fatal("missing or malformed recovery observation: ", name)
			}
		}
		text, pass := assessRecovery(phases, net.ParseIP(*expected), net.ParseIP(*resolver), *before, *after, *uid, *pid)
		fmt.Print(text)
		if !pass {
			os.Exit(1)
		}
		return
	}
	if *resultFile != "" {
		raw, err := os.ReadFile(*resultFile)
		if err != nil {
			log.Fatal(err)
		}
		if *resolver == "" {
			*resolver = *expected
		}
		text, pass := assessResolver(raw, net.ParseIP(*expected), net.ParseIP(*resolver))
		fmt.Print(text)
		if !pass {
			os.Exit(1)
		}
		return
	}
	host, port, err := net.SplitHostPort(*listen)
	ip := net.ParseIP(host)
	if err != nil || ip.To4() == nil || !ip.IsPrivate() || port != "53" {
		log.Fatal("private bridge IPv4 and port 53 required")
	}
	server, err := net.ListenPacket("udp4", *listen)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("DNS_READY=1")
	buffer := make([]byte, 1232)
	for {
		count, peer, err := server.ReadFrom(buffer)
		if err != nil {
			log.Fatal(err)
		}
		response := answer(buffer[:count], ip)
		if response == nil {
			continue
		}
		fmt.Printf("DNS_QUERY peer=%s query=%x answer=%x\n", peer, buffer[:count], response)
		if _, err := server.WriteTo(response, peer); err != nil {
			log.Print(err)
		}
	}
}
