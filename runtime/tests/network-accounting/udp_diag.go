package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
)

// Read only this owned socket's row. Never publish the host's socket table.
func udpDiagnostics(c *net.UDPConn) map[string]any {
	result := map[string]any{"local": c.LocalAddr().String()}
	raw, err := c.SyscallConn()
	if err != nil {
		result["error"] = err.Error()
		return result
	}
	var inode uint64
	err = raw.Control(func(fd uintptr) {
		buffer, e := syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_RCVBUF)
		if e != nil {
			result["error"] = e.Error()
			return
		}
		result["receive_buffer_bytes"] = buffer
		var stat syscall.Stat_t
		if e = syscall.Fstat(int(fd), &stat); e != nil {
			result["error"] = e.Error()
			return
		}
		inode = stat.Ino
	})
	if err != nil {
		result["error"] = err.Error()
		return result
	}
	data, err := os.ReadFile("/proc/net/udp")
	if err != nil {
		result["error"] = err.Error()
		return result
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 13 && fields[9] == strconv.FormatUint(inode, 10) {
			drops, e := strconv.ParseUint(fields[len(fields)-1], 10, 64)
			if e != nil {
				result["error"] = e.Error()
				return result
			}
			result["socket_drops"] = drops
			result["queue_bytes_hex"] = fields[4]
			return result
		}
	}
	result["error"] = "owned UDP socket absent from its namespace table"
	return result
}
func udpError(c *net.UDPConn, err error) string {
	data, encode := json.Marshal(udpDiagnostics(c))
	return fmt.Sprintf("%v; owned socket=%s; diagnostic encoding=%v", err, data, encode)
}
func udpStopEvidence(c *net.UDPConn) {
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM)
	go func() {
		<-stop
		emit(map[string]any{"event": "udp-fixture-stop", "socket": udpDiagnostics(c)})
		os.Exit(143)
	}()
}
