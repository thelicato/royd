package main

import "testing"

func TestQuotaProbePacketContract(t *testing.T) {
	nonce := make([]byte, 16)
	var joined []byte
	for i := 0; i < batch; i++ {
		joined = append(joined, packet(nonce, 9, 1000, i, 16, true)...)
	}
	if digest(joined) != "1e2c36c3fefccfff6e5e8196c15cdd8ebe1b9aef82b19e59f3bbf889a6ee18bc" {
		t.Fatal("segmented batch differs from the independent receiver contract")
	}
	if digest(packet(nonce, 10, 0, 0, 2, false)) != "27e3cc253debaf2ea8150c1978aa0e0ba266125ae432bee47fd203935f105c5a" {
		t.Fatal("raw packet payload differs from the independent receiver contract")
	}
}

func TestQuotaProbeRejectsInvalidScopeBeforeOpeningSocket(t *testing.T) {
	for _, c := range []struct {
		phase, uid, count int
		segmented, raw    bool
	}{
		{0, 1000, 16, true, false},
		{9, 0, 16, true, false},
		{9, 1000, 15, true, false},
		{9, 1000, 16, true, true},
		{9, 1000, 16, false, false},
		{10, 1000, 2, false, true},
		{10, 0, 3, false, true},
	} {
		reject(t, func() { quotaDatagramProbe("invalid", "", c.phase, c.uid, c.count, c.segmented, c.raw) })
	}
}
