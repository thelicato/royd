package main

import (
	"strings"
	"testing"
)

func dump(uid, set, tag, counters string) string {
	return "UID stats:\n  Complete history:\n  ident=[{type=9, metered=true}] uid=" + uid + " set=" + set + " tag=" + tag + "\n    NetworkStatsHistory: bucketDuration=3600\n      " + counters + "\nUID tag stats:\n  Complete history:\nmAppUidStatsMap:\n  10096 50000 100 70000 100\n"
}

func TestStatsDirectory(t *testing.T) {
	for _, directory := range []string{"/data/system/netstats", "/data/misc/apexdata/com.android.tethering/netstats"} {
		got, err := parseStatsDirectory([]byte("Directory:\n  " + directory + "\nConfigs:\n"))
		if err != nil || got != directory {
			t.Fatal(got, err)
		}
	}
	for _, raw := range []string{"", "Directory:", "Directory:\n", "Directory:\n/data/system/netstats/../other", "Directory:\n/etc", "Directory:\n/unknown", "Directory:\n/data/system/netstats\nDirectory:\n/data/system/netstats"} {
		if _, err := parseStatsDirectory([]byte(raw)); err == nil {
			t.Fatal("unsafe directory accepted", raw)
		}
	}
}

func TestParser(t *testing.T) {
	const row = "st=123 rb=1024 rp=4 tb=2048 tp=5 op=0"
	good := dump("10096", "FOREGROUND", "0x0", row)
	want := usage{RX: 1024, TX: 2048, RXPackets: 4, TXPackets: 5, Buckets: 1}
	want.Fingerprint = "ident=[{type=9, metered=true}] uid=10096 set=FOREGROUND tag=0x0\nNetworkStatsHistory: bucketDuration=3600\n" + row
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
		"missing duration":     strings.Replace(good, "NetworkStatsHistory: bucketDuration=3600", "", 1),
		"invalid duration":     strings.Replace(good, "bucketDuration=3600", "bucketDuration=0", 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parseHistory([]byte(raw), 10096); err == nil {
				t.Fatal("invalid dump accepted")
			}
		})
	}
}

func TestBucketIdentity(t *testing.T) {
	const row = "st=123 rb=1024 rp=4 tb=2048 tp=5 op=0"
	raw := dump("10096", "FOREGROUND", "0x0", row)
	before, err := parseHistory([]byte(raw), 10096)
	if err != nil {
		t.Fatal(err)
	}
	for _, pair := range [][2]string{{"st=123", "st=124"}, {"set=FOREGROUND", "set=DEFAULT"}, {"bucketDuration=3600", "bucketDuration=7200"}, {"op=0", "op=1"}} {
		after, err := parseHistory([]byte(strings.Replace(raw, pair[0], pair[1], 1)), 10096)
		if err != nil || durable(before, after, after) {
			t.Fatalf("changed bucket accepted: %v, %v", pair, err)
		}
	}
	second := strings.Replace(row, "st=123", "st=124", 1)
	a, err := parseHistory([]byte(strings.Replace(raw, row, row+"\n      "+second, 1)), 10096)
	if err != nil {
		t.Fatal(err)
	}
	b, err := parseHistory([]byte(strings.Replace(raw, row, second+"\n      "+row, 1)), 10096)
	if err != nil || !durable(a, b, b) {
		t.Fatal("canonical bucket ordering rejected", err)
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

func TestDurability(t *testing.T) {
	seed := usage{RX: 1000, TX: 2000, RXPackets: 8, TXPackets: 9, Buckets: 1, Fingerprint: "seed identity/set/time/duration/counters"}
	if !durable(seed, seed, seed) {
		t.Fatal("unchanged history rejected")
	}
	for name, mutate := range map[string]func(*usage){
		"lost RX":                         func(v *usage) { v.RX-- },
		"lost TX":                         func(v *usage) { v.TX-- },
		"lost packet":                     func(v *usage) { v.RXPackets-- },
		"duplicate traffic":               func(v *usage) { v.TX *= 2 },
		"new packet":                      func(v *usage) { v.TXPackets++ },
		"new bucket":                      func(v *usage) { v.Buckets++ },
		"changed bucket identity or time": func(v *usage) { v.Fingerprint = "changed" },
		"empty":                           func(v *usage) { *v = usage{} },
	} {
		t.Run(name, func(t *testing.T) {
			changed := seed
			mutate(&changed)
			if durable(seed, changed, seed) || durable(seed, seed, changed) {
				t.Fatal("changed history accepted")
			}
		})
	}
	if durable(usage{}, usage{}, usage{}) {
		t.Fatal("empty history accepted")
	}
	denied := access{Label: "other-restart", UID: 10096, QueryUID: 1000, NetworkType: 1, End: 12345, Status: "denied", Exception: "java.lang.SecurityException", Done: true}
	if _, ok := assessLabel(seed, seed, denied, 10096, 12345, "other-restart"); !ok {
		t.Fatal("phase identity rejected")
	}
	if _, ok := assessLabel(seed, seed, denied, 10096, 12345, "other-fresh"); ok {
		t.Fatal("stale denial observation accepted")
	}
}
