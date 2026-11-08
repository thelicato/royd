package main

import (
	"encoding/hex"
	"fmt"
	"net"
	"syscall"
	"time"
)

// quotaDatagramProbe reports one complete round trip followed by a deliberately
// unanswered aggregate. Independent hook/counter evidence must establish quota
// rejection; a socket timeout alone never establishes packet enforcement.
func quotaDatagramProbe(address, nonceText string, phase, uid, count int, segmented, rawMode bool) {
	step := batch
	if rawMode {
		step = 1
	}
	require(phase > 0 && count == 2*step && (segmented && !rawMode && uid == 1000 || rawMode && !segmented && uid == 0), "quota datagram options")
	nonce, err := hex.DecodeString(nonceText)
	require(err == nil && len(nonce) == 16, "quota datagram nonce")
	workerReady(uid)
	c, err := net.DialUDP("udp4", nil, endpoint(address))
	require(err == nil, "quota datagram socket")
	defer c.Close()
	rawFD := -1
	if rawMode {
		rawFD, err = syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.IPPROTO_UDP)
		require(err == nil, "quota raw socket")
		defer syscall.Close(rawFD)
		require(syscall.SetsockoptInt(rawFD, syscall.IPPROTO_IP, syscall.IP_HDRINCL, 1) == nil, "quota IP_HDRINCL")
	}
	start := mono()
	seen := map[int]bool{}
	for base := 0; base < count; base += step {
		var data []byte
		for seq := base; seq < base+step; seq++ {
			data = append(data, packet(nonce, phase, uid, seq, count, segmented)...)
		}
		require(c.SetDeadline(time.Now().Add(3*time.Second)) == nil, "quota datagram deadline")
		if rawMode {
			destination := endpoint(address)
			peer := &syscall.SockaddrInet4{Port: destination.Port}
			copy(peer.Addr[:], destination.IP.To4())
			require(syscall.Sendto(rawFD, rawPacket(c, destination, data, base), 0, peer) == nil, "quota raw send")
		} else {
			require(send(c, data, nil, segmented) == nil, "quota segmented send")
		}
		for reply := 0; reply < step; reply++ {
			buffer := make([]byte, size+1)
			n, err := c.Read(buffer)
			if err != nil {
				timeout, ok := err.(net.Error)
				require(ok && timeout.Timeout() && base == step && reply == 0 && len(seen) == step,
					"unexpected quota datagram read failure: "+fmt.Sprint(err))
				emit(map[string]any{"event": "quota-datagram-blocked", "uid": uid, "phase": phase,
					"attempted": count, "received": len(seen), "payload_bytes": len(seen) * size,
					"segmented": segmented, "raw": rawMode, "local": c.LocalAddr().String(), "remote": c.RemoteAddr().String(),
					"start_ns": start, "end_ns": mono(), "udp_socket": udpDiagnostics(c)})
				return
			}
			p, u, seq, total, segmented := fields(buffer[:n], nonce)
			require(p == phase && u == uid && total == count && segmented == (step == batch) && !seen[seq] && seq >= base && seq < base+step,
				"quota datagram reply identity")
			seen[seq] = true
		}
	}
	panic("quota datagram crossing aggregate received replies")
}
