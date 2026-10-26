package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"time"
)

const tcpBytes = 1 << 20

func tcpPayload(nonce []byte, phase, uid int, reply bool) []byte {
	p := make([]byte, tcpBytes)
	copy(p, nonce)
	binary.BigEndian.PutUint32(p[16:], uint32(phase))
	binary.BigEndian.PutUint32(p[20:], uint32(uid))
	binary.BigEndian.PutUint32(p[24:], tcpBytes)
	if reply {
		p[28] = 1
	}
	for i := 32; i < len(p); i++ {
		p[i] = byte(i ^ phase ^ uid ^ int(p[28]))
	}
	return p
}
func digest(p []byte) string {
	sum := sha256.Sum256(p)
	return hex.EncodeToString(sum[:])
}
func tcpWrite(c *net.TCPConn, p []byte) {
	for offset := 0; offset < len(p); offset += 64 << 10 {
		end := offset + 64<<10
		if end > len(p) {
			end = len(p)
		}
		n, e := c.Write(p[offset:end])
		require(e == nil && n == end-offset, "complete TCP write: "+fmt.Sprint(e))
		time.Sleep(time.Millisecond)
	}
}
func tcpEOF(c *net.TCPConn) {
	var extra [1]byte
	n, e := c.Read(extra[:])
	require(n == 0 && e == io.EOF, "TCP graceful end without excess bytes: "+fmt.Sprint(e))
}
func serveTCP(c *net.TCPConn, nonce []byte) {
	defer c.Close()
	require(c.SetDeadline(time.Now().Add(15*time.Second)) == nil, "TCP fixture deadline")
	data := make([]byte, tcpBytes)
	_, e := io.ReadFull(c, data)
	require(e == nil, "TCP fixture receive: "+fmt.Sprint(e))
	phase, uid := int(binary.BigEndian.Uint32(data[16:])), int(binary.BigEndian.Uint32(data[20:]))
	require((phase == 6 && uid == 1000 || phase == 7 && (uid == 0 || uid == 1000)) &&
		bytes.Equal(data, tcpPayload(nonce, phase, uid, false)), "TCP upload identity/contents")
	reply := tcpPayload(nonce, phase, uid, true)
	tcpWrite(c, reply)
	tcpEOF(c)
	require(c.CloseWrite() == nil, "TCP fixture half-close")
	emit(map[string]any{"event": "tcp-complete", "phase": phase, "uid": uid,
		"peer": c.RemoteAddr().String(), "payload_bytes": tcpBytes,
		"upload_sha256": digest(data), "download_sha256": digest(reply)})
}
func startTCPServer(ip net.IP, nonce []byte) *net.TCPListener {
	listener, e := net.ListenTCP("tcp4", &net.TCPAddr{IP: ip.To4()})
	require(e == nil, "TCP fixture listener")
	require(listener.SetDeadline(time.Now().Add(90*time.Second)) == nil, "TCP accept deadline")
	go func() {
		for accepted := 0; accepted < 8; accepted++ {
			c, e := listener.AcceptTCP()
			require(e == nil, "TCP accept: "+fmt.Sprint(e))
			go serveTCP(c, nonce)
		}
		panic("TCP connection bound exceeded")
	}()
	return listener
}
func tcpWorker(address, nonceText string, phase, uid int) {
	nonce, e := hex.DecodeString(nonceText)
	require(e == nil && len(nonce) == 16 && (phase == 6 || phase == 7), "TCP identity")
	workerReady(uid)
	a := endpoint(address)
	start := mono()
	connection, e := net.DialTimeout("tcp4", a.String(), 10*time.Second)
	require(e == nil, "TCP worker connect: "+fmt.Sprint(e))
	c := connection.(*net.TCPConn)
	defer c.Close()
	require(c.SetDeadline(time.Now().Add(15*time.Second)) == nil, "TCP worker deadline")
	upload := tcpPayload(nonce, phase, uid, false)
	tcpWrite(c, upload)
	reply := make([]byte, tcpBytes)
	_, e = io.ReadFull(c, reply)
	require(e == nil && bytes.Equal(reply, tcpPayload(nonce, phase, uid, true)), "TCP download identity/contents")
	require(c.CloseWrite() == nil, "TCP worker half-close")
	tcpEOF(c)
	emit(map[string]any{"event": "tcp-complete", "uid": uid, "phase": phase,
		"payload_bytes": tcpBytes, "upload_sha256": digest(upload), "download_sha256": digest(reply),
		"start_ns": start, "end_ns": mono(), "local": c.LocalAddr().String(), "remote": c.RemoteAddr().String()})
}
