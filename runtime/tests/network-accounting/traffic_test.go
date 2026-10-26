package main

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"
)

func reject(t *testing.T, action func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatal("invalid input was accepted")
		}
	}()
	action()
}

func TestDatagramIntegrity(t *testing.T) {
	nonce := []byte("1234567890abcdef")
	for _, segmented := range []bool{false, true} {
		for _, uid := range []int{0, 1000} {
			p := packet(nonce, 4, uid, 7, 64, segmented)
			phase, gotUID, seq, count, seg := fields(p, nonce)
			if phase != 4 || gotUID != uid || seq != 7 || count != 64 || seg != segmented {
				t.Fatal("datagram identity changed")
			}
		}
	}
	for name, mutate := range map[string]func([]byte) []byte{
		"short":         func(p []byte) []byte { return p[:15] },
		"oversize":      func(p []byte) []byte { return append(p, 0) },
		"nonce":         func(p []byte) []byte { p[0] ^= 1; return p },
		"payload":       func(p []byte) []byte { p[111] ^= 1; return p },
		"sequence":      func(p []byte) []byte { binary.BigEndian.PutUint32(p[24:], 64); return p },
		"UID":           func(p []byte) []byte { binary.BigEndian.PutUint32(p[20:], 10096); return p },
		"segment-flag":  func(p []byte) []byte { p[32] = 2; return p },
		"partial-batch": func(p []byte) []byte { binary.BigEndian.PutUint32(p[28:], 63); return p },
	} {
		t.Run(name, func(t *testing.T) {
			reject(t, func() { fields(mutate(packet(nonce, 4, 1000, 7, 64, true)), nonce) })
		})
	}
}

func TestPrivateEndpointBoundary(t *testing.T) {
	for _, address := range []string{"127.0.0.1:9", "0.0.0.0:9", "8.8.8.8:53", "[::1]:9", "example.test:9", "172.17.0.1:0", "172.17.0.1:65536"} {
		t.Run(address, func(t *testing.T) { reject(t, func() { endpoint(address) }) })
	}
	if endpoint("172.17.0.1:9000").Port != 9000 {
		t.Fatal("private fixture endpoint changed")
	}
}

func TestRawIPv4Envelope(t *testing.T) {
	// Dial chooses a local address without sending a packet.
	destination := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 9000}
	c, err := net.DialUDP("udp4", nil, destination)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	data := packet([]byte("1234567890abcdef"), 1, 0, 3, 64, false)
	p := rawPacket(c, destination, data, 3)
	if len(p) != 1228 || p[0] != 0x45 || p[9] != 17 || p[8] != 64 ||
		binary.BigEndian.Uint16(p[2:]) != 1228 || binary.BigEndian.Uint16(p[6:]) != 0x4000 ||
		binary.BigEndian.Uint16(p[20:]) != uint16(c.LocalAddr().(*net.UDPAddr).Port) ||
		binary.BigEndian.Uint16(p[22:]) != 9000 || binary.BigEndian.Uint16(p[24:]) != 1208 ||
		!bytes.Equal(p[28:], data) || !net.IP(p[12:16]).Equal(net.IPv4(127, 0, 0, 1)) ||
		!net.IP(p[16:20]).Equal(destination.IP) {
		t.Fatal("raw packet envelope does not match the independently expected IPv4/UDP lengths and addresses")
	}
}
