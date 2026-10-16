package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
)

// A deliberately non-recursive, single-name UDP fixture, not a production resolver.
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
	if !strings.EqualFold(strings.Join(labels, "."), "royd-probe.test") || qclass != 1 {
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

func main() {
	listen := flag.String("listen", "", "specific private Docker bridge IPv4 address, port 53")
	resultFile := flag.String("result", "", "assess an application JSON result without a listener")
	expected := flag.String("expected", "", "expected literal IPv4 answer")
	resolver := flag.String("resolver", "", "expected configured resolver, defaults to answer address")
	flag.Parse()
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
