package main

import (
	"strings"
	"testing"
)

func dump(uid, set, tag, counters string) string {
	return "UID stats:\n  Complete history:\n  ident=[{type=9, metered=true}] uid=" + uid + " set=" + set + " tag=" + tag + "\n    NetworkStatsHistory: bucketDuration=3600\n      " + counters + "\nUID tag stats:\n  Complete history:\nmAppUidStatsMap:\n  10096 50000 100 70000 100\n"
}

func TestParser(t *testing.T) {
	const row = "st=123 rb=1024 rp=4 tb=2048 tp=5 op=0"
	good := dump("10096", "FOREGROUND", "0x0", row)
	want := usage{RX: 1024, TX: 2048, RXPackets: 4, TXPackets: 5, Buckets: 1}
	got, err := parseHistory([]byte(good), 10096)
	if err != nil || got != want {
		t.Fatalf("%+v %v", got, err)
	}
	for name, raw := range map[string]string{
		"other UID":    dump("1000", "FOREGROUND", "0x0", row),
		"tagged":       dump("10096", "FOREGROUND", "0x7", row),
		"raw map only": "UID stats:\n Complete history:\nUID tag stats:\n 2 eth0 0x0 10096 1 100000 1 100000 1\n",
		"non-Ethernet": strings.Replace(good, "type=9,", "type=1,", 1),
		"empty":        "UID stats:\n Complete history:\nUID tag stats:\n",
	} {
		t.Run(name, func(t *testing.T) {
			got, err := parseHistory([]byte(raw), 10096)
			if err != nil || got != (usage{}) {
				t.Fatalf("unexpected history: %+v %v", got, err)
			}
		})
	}
	for name, raw := range map[string]string{
		"missing section":      "mStatsMapA: OK\n",
		"missing end":          strings.Replace(good, "UID tag stats:", "", 1),
		"missing completeness": strings.Replace(good, "Complete history:", "", 1),
		"negative":             strings.Replace(good, "rb=1024", "rb=-1", 1),
		"overflow":             strings.Replace(good, "rb=1024", "rb=9223372036854775808", 1),
		"truncated bucket":     strings.Replace(good, " tp=5 op=0", "", 1),
		"duplicate section":    good + good,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parseHistory([]byte(raw), 10096); err == nil {
				t.Fatal("invalid dump accepted")
			}
		})
	}
}

func TestAssessment(t *testing.T) {
	good := usage{RX: 1000, TX: 2000, RXPackets: 8, TXPackets: 9, Buckets: 1}
	denied := access{Label: "other", UID: 10096, QueryUID: 1000, NetworkType: 1, End: 12345, Status: "denied", Exception: "java.lang.SecurityException", Done: true}
	if _, ok := assess(good, good, denied, 10096, 12345); !ok {
		t.Fatal("valid history rejected")
	}
	for name, mutate := range map[string]func(*usage, *usage, *access){
		"flat history":       func(a, b *usage, d *access) { *a = usage{}; *b = usage{} },
		"regression":         func(a, b *usage, d *access) { b.RX-- },
		"zero TX":            func(a, b *usage, d *access) { a.TX = 0 },
		"wrong UID":          func(a, b *usage, d *access) { d.UID = 1000 },
		"wrong query":        func(a, b *usage, d *access) { d.QueryUID = 10096 },
		"wrong template":     func(a, b *usage, d *access) { d.NetworkType = 9 },
		"wrong range":        func(a, b *usage, d *access) { d.End++ },
		"not done":           func(a, b *usage, d *access) { d.Done = false },
		"permission granted": func(a, b *usage, d *access) { d.Status = "complete" },
		"wrong exception":    func(a, b *usage, d *access) { d.Exception = "java.lang.IllegalArgumentException" },
		"query failure":      func(a, b *usage, d *access) { d.Error = "failed" },
	} {
		t.Run(name, func(t *testing.T) {
			a, b, d := good, good, denied
			mutate(&a, &b, &d)
			if _, ok := assess(a, b, d, 10096, 12345); ok {
				t.Fatal("invalid observation accepted")
			}
		})
	}
}
