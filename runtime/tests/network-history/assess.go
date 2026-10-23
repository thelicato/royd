package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type usage struct {
	RX, TX, RXPackets, TXPackets int64
	Buckets                      int
}
type access struct {
	Label       string `json:"label"`
	UID         int    `json:"uid"`
	QueryUID    int    `json:"query_uid"`
	NetworkType int    `json:"query_network_type"`
	Start       int64  `json:"query_start"`
	End         int64  `json:"query_end"`
	Status      string `json:"status"`
	Exception   string `json:"exception"`
	Error       string `json:"error"`
	Done        bool   `json:"done"`
}

// Consume only complete untagged Ethernet UID history, never the raw BPF tables.
func parseHistory(raw []byte, uid int) (usage, error) {
	var result usage
	section, selected, complete := false, false, false
	sections, ends := 0, 0
	key := regexp.MustCompile(`^ident=\[.*\] uid=(-?[0-9]+) set=(?:ALL|DEFAULT|FOREGROUND) tag=0x0$`)
	bucket := regexp.MustCompile(`^st=([0-9]+) rb=([0-9]+) rp=([0-9]+) tb=([0-9]+) tp=([0-9]+) op=([0-9]+)$`)
	scanner := bufio.NewScanner(strings.NewReader(string(raw)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "UID stats:" {
			section = true
			sections++
			continue
		}
		if line == "UID tag stats:" {
			section = false
			ends++
			continue
		}
		if !section {
			continue
		}
		if line == "Complete history:" {
			complete = true
			continue
		}
		if strings.HasPrefix(line, "ident=") {
			match := key.FindStringSubmatch(line)
			selected = match != nil && match[1] == strconv.Itoa(uid) && strings.Contains(line, "type=9,")
			continue
		}
		if !selected || !strings.HasPrefix(line, "st=") {
			continue
		}
		match := bucket.FindStringSubmatch(line)
		if match == nil {
			return result, fmt.Errorf("malformed UID history bucket")
		}
		values := []*int64{&result.RX, &result.RXPackets, &result.TX, &result.TXPackets}
		for i, total := range values {
			value, err := strconv.ParseInt(match[i+2], 10, 64)
			if err != nil || value > math.MaxInt64-*total {
				return result, fmt.Errorf("invalid UID history counter")
			}
			*total += value
		}
		result.Buckets++
	}
	if scanner.Err() != nil || sections != 1 || ends != 1 || !complete {
		return result, fmt.Errorf("incomplete UID history dump")
	}
	return result, nil
}

func assess(first, second usage, denied access, uid int, end int64) (string, bool) {
	identity := uid >= 10000 && end > 0 && denied.Label == "other" && denied.UID == uid && denied.Start == 0 && denied.End == end && denied.Done && denied.Error == ""
	available := first.Buckets > 0 && second.Buckets > 0 && first.RX > 0 && first.TX > 0 && first.RXPackets > 0 && first.TXPackets > 0
	monotonic := second.RX >= first.RX && second.TX >= first.TX && second.RXPackets >= first.RXPackets && second.TXPackets >= first.TXPackets
	accessDenied := denied.QueryUID == 1000 && denied.NetworkType == 1 && denied.Status == "denied" && denied.Exception == "java.lang.SecurityException"
	status := func(ok bool) string {
		if ok {
			return "pass"
		}
		return "fail"
	}
	return fmt.Sprintf("HISTORY_IDENTITY_STATUS=%s\nHISTORY_USAGE_STATUS=%s\nHISTORY_MONOTONIC_STATUS=%s\nHISTORY_ACCESS_STATUS=%s\n", status(identity), status(available), status(monotonic), status(accessDenied)), identity && available && monotonic && accessDenied
}

func main() {
	directory := flag.String("evidence", "", "saved NetStats service history and ordinary-UID access control")
	uid := flag.Int("uid", 0, "observed ordinary package UID")
	end := flag.Int64("end", 0, "fixed ordinary-UID denial-query end")
	flag.Parse()
	var histories [2]usage
	for i, name := range []string{"first", "second"} {
		raw, err := os.ReadFile(filepath.Join(*directory, "native-"+name+".log"))
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		histories[i], err = parseHistory(raw, *uid)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	var denied access
	raw, err := os.ReadFile(filepath.Join(*directory, "history-other.json"))
	if err != nil || json.Unmarshal(raw, &denied) != nil {
		fmt.Fprintln(os.Stderr, "invalid access observation")
		os.Exit(1)
	}
	result, ok := assess(histories[0], histories[1], denied, *uid, *end)
	fmt.Print(result)
	if !ok {
		os.Exit(1)
	}
}
