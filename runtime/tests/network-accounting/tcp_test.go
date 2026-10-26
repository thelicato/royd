package main

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestTCPStreamIdentity(t *testing.T) {
	nonce := []byte("1234567890abcdef")
	p := tcpPayload(nonce, 6, 1000, false)
	if len(p) != 1<<20 || !bytes.Equal(p[:16], nonce) || binary.BigEndian.Uint32(p[16:]) != 6 ||
		binary.BigEndian.Uint32(p[20:]) != 1000 || binary.BigEndian.Uint32(p[24:]) != 1<<20 || p[28] != 0 {
		t.Fatal("TCP stream identity/length changed")
	}
	for name, changed := range map[string][]byte{
		"nonce": tcpPayload([]byte("different nonce!"), 6, 1000, false),
		"phase": tcpPayload(nonce, 7, 1000, false),
		"UID":   tcpPayload(nonce, 6, 0, false),
		"reply": tcpPayload(nonce, 6, 1000, true),
	} {
		t.Run(name, func(t *testing.T) {
			if bytes.Equal(p, changed) || digest(p) == digest(changed) {
				t.Fatal("different flow/direction accepted as the original stream")
			}
		})
	}
	changed := append([]byte{}, p...)
	changed[len(changed)-1] ^= 1
	if digest(changed) == digest(p) {
		t.Fatal("payload corruption was not detected")
	}
}
