package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"testing"
	"time"
)

func TestUDPWaitsForTheCurrentReply(t *testing.T) {
	server, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	client, err := net.DialUDP("udp4", nil, server.LocalAddr().(*net.UDPAddr))
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	client.SetDeadline(time.Now().Add(3 * time.Second))
	nonce := []byte("1234567890abcdef")
	result := make(chan error, 1)
	go func() {
		data := make([]byte, size+1)
		server.SetReadDeadline(time.Now().Add(3 * time.Second))
		n, peer, e := server.ReadFromUDP(data)
		if e != nil {
			result <- e
			return
		}
		first := append([]byte{}, data[:n]...)
		server.SetReadDeadline(time.Now().Add(80 * time.Millisecond))
		_, _, e = server.ReadFromUDP(data)
		if !errors.Is(e, os.ErrDeadlineExceeded) {
			result <- fmt.Errorf("next request arrived before first reply: %v", e)
			return
		}
		if _, e = server.WriteToUDP(first, peer); e != nil {
			result <- e
			return
		}
		server.SetReadDeadline(time.Now().Add(3 * time.Second))
		n, nextPeer, e := server.ReadFromUDP(data)
		if e != nil {
			result <- e
			return
		}
		if nextPeer.String() != peer.String() {
			result <- fmt.Errorf("socket changed")
			return
		}
		_, e = server.WriteToUDP(data[:n], peer)
		result <- e
	}()
	if e := udpExchange(client, nonce, 2, 1000, 2, false, -1, server.LocalAddr().(*net.UDPAddr)); e != nil {
		t.Fatal(e)
	}
	if e := <-result; e != nil {
		t.Fatal(e)
	}
	state := udpDiagnostics(client)
	if state["error"] != nil || state["socket_drops"] != uint64(0) || state["local"] != client.LocalAddr().String() {
		t.Fatalf("wrong owned-socket diagnostics: %v", state)
	}
}
