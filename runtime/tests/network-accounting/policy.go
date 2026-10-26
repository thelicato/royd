package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"time"
)

type policyFixture struct {
	mu     sync.Mutex
	peers  map[int]net.UDPAddr
	roles  [2]int
	seen   map[int]map[int]bool
	pushed bool
	socket *net.UDPConn
	nonce  []byte
}

func policyFields(data, nonce []byte) (phase, uid, sequence int) {
	require(len(data) == size && len(nonce) == 16, "policy datagram length")
	phase = int(binary.BigEndian.Uint32(data[16:]))
	uid = int(binary.BigEndian.Uint32(data[20:]))
	sequence = int(binary.BigEndian.Uint32(data[24:]))
	require(phase >= 8 && phase <= 13 && uid >= 10000 && uid < 20000 && sequence < 64, "policy datagram identity")
	require(bytes.Equal(data, packet(nonce, phase, uid, sequence, 64, false)), "policy nonce/payload mismatch")
	return
}
func (p *policyFixture) receive(data []byte, peer *net.UDPAddr) {
	phase, uid, sequence := policyFields(data, p.nonce)
	p.mu.Lock()
	role := (phase - 8) % 2
	if phase == 8 || phase == 9 {
		require(p.roles[role] == 0 || p.roles[role] == uid, "changed policy role UID")
		p.roles[role] = uid
	}
	require(p.roles[role] == uid && p.roles[1-role] != uid, "unregistered or shared policy UID")
	previous, exists := p.peers[uid]
	require(!exists || previous.String() == peer.String(), "policy socket changed")
	p.peers[uid] = *peer
	if p.seen[phase] == nil {
		p.seen[phase] = map[int]bool{}
	}
	require(!p.seen[phase][sequence], "duplicate policy datagram")
	p.seen[phase][sequence] = true
	complete := len(p.seen[phase]) == 64
	p.mu.Unlock()
	emit(map[string]any{"event": "policy-receive", "phase": phase, "uid": uid, "sequence": sequence, "peer": peer.String(), "payload_bytes": size})
	require(send(p.socket, data, peer, false) == nil, "policy echo")
	if complete {
		emit(map[string]any{"event": "policy-complete", "phase": phase, "uid": uid, "peer": peer.String(), "packets": 64, "payload_bytes": 64 * size})
	}
}
func (p *policyFixture) push(line string) {
	var command struct {
		Phase int `json:"phase"`
		UID   int `json:"uid"`
		Count int `json:"count"`
	}
	decoder := json.NewDecoder(strings.NewReader(line))
	decoder.DisallowUnknownFields()
	require(decoder.Decode(&command) == nil, "policy push command")
	var extra any
	require(decoder.Decode(&extra) == io.EOF, "excess policy push command")
	p.mu.Lock()
	peer, exists := p.peers[command.UID]
	require(!p.pushed && exists && p.roles[0] == command.UID && command.Phase == 10 && command.Count == 64, "unowned or repeated policy push")
	p.pushed = true
	p.mu.Unlock()
	for sequence := 0; sequence < 64; sequence++ {
		require(send(p.socket, packet(p.nonce, 10, command.UID, sequence, 64, false), &peer, false) == nil, "policy push send")
		time.Sleep(time.Millisecond)
	}
	emit(map[string]any{"event": "policy-push", "phase": 10, "uid": command.UID, "peer": peer.String(), "packets": 64, "payload_bytes": 64 * size})
}
func startPolicyFixture(socket *net.UDPConn, nonce []byte) *policyFixture {
	p := &policyFixture{peers: map[int]net.UDPAddr{}, seen: map[int]map[int]bool{}, socket: socket, nonce: nonce}
	go func() {
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 4096), 4096)
		for scanner.Scan() {
			p.push(scanner.Text())
		}
		require(scanner.Err() == nil, "policy input: "+fmt.Sprint(scanner.Err()))
	}()
	return p
}
