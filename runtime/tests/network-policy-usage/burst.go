// Optional bounded native quota-continuity probe. Never included in the Android product.
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

func need(v bool, s string) {
	if !v {
		panic(s)
	}
}
func emit(v any) { need(json.NewEncoder(os.Stdout).Encode(v) == nil, "JSON output") }
func mono() int64 {
	var ts syscall.Timespec
	_, _, e := syscall.RawSyscall(syscall.SYS_CLOCK_GETTIME, 1, uintptr(unsafe.Pointer(&ts)), 0)
	need(e == 0, "clock")
	return ts.Sec*1e9 + ts.Nsec
}
func main() {
	single := len(os.Args) == 4 && os.Args[3] == "single"
	need(len(os.Args) == 3 || single, "nonce, private IPv4 peer and optional single mode required")
	nonce, e := hex.DecodeString(os.Args[1])
	need(e == nil && len(nonce) == 16, "nonce")
	peer, e := net.ResolveUDPAddr("udp4", os.Args[2])
	need(e == nil && peer.IP.To4() != nil && peer.IP.IsPrivate(), "private IPv4 peer")
	need(os.Getuid() == 1001 && os.Getgid() == 1001, "actual UID/GID")
	status, e := os.ReadFile("/proc/self/status")
	need(e == nil, "status")
	cap := ""
	for _, l := range strings.Split(string(status), "\n") {
		if strings.HasPrefix(l, "CapEff:") {
			cap = strings.TrimSpace(strings.TrimPrefix(l, "CapEff:"))
		}
	}
	need(cap == "0000000000000000", "capability-free worker")
	c, e := net.DialUDP("udp4", nil, peer)
	need(e == nil, "UDP socket")
	defer c.Close()
	emit(map[string]any{"event": "ready", "uid": os.Getuid(), "gid": os.Getgid(), "pid": os.Getpid(), "cap_eff": cap, "local": c.LocalAddr().String(), "remote": c.RemoteAddr().String(), "nonce": os.Args[1]})
	line, e := bufio.NewReader(os.Stdin).ReadString('\n')
	need(e == nil && line == os.Args[1]+"\n", "owned start barrier")
	need(c.SetWriteDeadline(time.Now().Add(10*time.Second)) == nil, "deadline")
	start := mono()
	times := []int64{}
	successful, blocked := 0, 0
	steps, count := 24, 64
	if single {
		steps, count = 1, 1
	}
	for step := 1; step <= steps; step++ {
		for sequence := 0; sequence < count; sequence++ {
			data := make([]byte, 1200)
			copy(data, nonce)
			for i, v := range []uint32{uint32(step), 1001, uint32(sequence), uint32(count)} {
				binary.BigEndian.PutUint32(data[16+4*i:], v)
			}
			data[32] = 1
			for i := 33; i < len(data); i++ {
				data[i] = byte(i + sequence + 1001)
			}
			times = append(times, mono())
			n, err := c.Write(data)
			if err == nil {
				need(n == 1200, "short datagram")
				successful++
			} else {
				op, ok := err.(*net.OpError)
				need(ok, "UDP error")
				sc, ok := op.Err.(*os.SyscallError)
				need(ok && sc.Err == syscall.ENOBUFS, "unexpected send error: "+fmt.Sprint(err))
				blocked++
			}
			time.Sleep(2 * time.Millisecond)
		}
	}
	emit(map[string]any{"event": "finished", "uid": os.Getuid(), "gid": os.Getgid(), "pid": os.Getpid(), "nonce": os.Args[1], "local": c.LocalAddr().String(), "remote": c.RemoteAddr().String(), "attempted": steps * count, "successful": successful, "enobufs": blocked, "start_ns": start, "end_ns": mono(), "release_ns": times})
}
