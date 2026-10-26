// Optional native traffic fixture. Never included in the Android product.
package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const size = 1200
const batch = 8
const udpSegment = 103

func require(ok bool, text string) {
	if !ok {
		panic(text)
	}
}
func emit(v any) { require(json.NewEncoder(os.Stdout).Encode(v) == nil, "JSON output") }
func mono() int64 {
	var ts syscall.Timespec
	_, _, err := syscall.RawSyscall(syscall.SYS_CLOCK_GETTIME, 1, uintptr(unsafe.Pointer(&ts)), 0)
	require(err == 0, "monotonic clock")
	return ts.Sec*1e9 + ts.Nsec
}
func packet(nonce []byte, phase, uid, sequence, count int, segmented bool) []byte {
	p := make([]byte, size)
	copy(p, nonce)
	for i, v := range []int{phase, uid, sequence, count} {
		binary.BigEndian.PutUint32(p[16+i*4:], uint32(v))
	}
	if segmented {
		p[32] = 1
	}
	for i := 33; i < size; i++ {
		p[i] = byte(i + sequence + uid)
	}
	return p
}
func fields(p, nonce []byte) (phase, uid, sequence, count int, segmented bool) {
	require(len(p) == size && bytes.Equal(p[:16], nonce), "unexpected datagram identity/size")
	phase = int(binary.BigEndian.Uint32(p[16:]))
	uid = int(binary.BigEndian.Uint32(p[20:]))
	sequence = int(binary.BigEndian.Uint32(p[24:]))
	count = int(binary.BigEndian.Uint32(p[28:]))
	segmented = p[32] == 1
	require(phase > 0 && (uid == 0 || uid == 1000) && count > 0 && count <= 1024 && sequence < count && (!segmented || count%batch == 0), "invalid datagram fields")
	require(bytes.Equal(p, packet(nonce, phase, uid, sequence, count, segmented)), "datagram contents changed")
	return
}
func endpoint(value string) *net.UDPAddr {
	host, port, err := net.SplitHostPort(value)
	require(err == nil, "literal endpoint")
	ip := net.ParseIP(host)
	n, e := strconv.Atoi(port)
	require(ip != nil && ip.To4() != nil && ip.IsPrivate() && e == nil && n > 0 && n <= 65535, "private IPv4 endpoint required")
	return &net.UDPAddr{IP: ip.To4(), Port: n}
}
func send(c *net.UDPConn, data []byte, peer *net.UDPAddr, segmented bool) error {
	if !segmented {
		var n int
		var e error
		if peer == nil {
			n, e = c.Write(data)
		} else {
			n, e = c.WriteToUDP(data, peer)
		}
		if e == nil && n != len(data) {
			e = io.ErrShortWrite
		}
		return e
	}
	control := make([]byte, syscall.CmsgSpace(2))
	header := (*syscall.Cmsghdr)(unsafe.Pointer(&control[0]))
	header.Level = syscall.IPPROTO_UDP
	header.Type = udpSegment
	header.SetLen(syscall.CmsgLen(2))
	binary.NativeEndian.PutUint16(control[syscall.CmsgLen(0):], size)
	var address syscall.Sockaddr
	if peer != nil {
		a := &syscall.SockaddrInet4{Port: peer.Port}
		copy(a.Addr[:], peer.IP.To4())
		address = a
	}
	raw, e := c.SyscallConn()
	if e != nil {
		return e
	}
	var result error
	e = raw.Write(func(fd uintptr) bool {
		n, err := syscall.SendmsgN(int(fd), data, control, address, 0)
		if err == syscall.EAGAIN || err == syscall.EWOULDBLOCK {
			return false
		}
		result = err
		if err == nil && n != len(data) {
			result = io.ErrShortWrite
		}
		return true
	})
	if e != nil {
		return e
	}
	return result
}

type flow struct {
	peer    string
	seen    map[int]bool
	packets [][]byte
	sent    int
	first   int64
}

func server(listen string, tcpMode bool) {
	host, port, e := net.SplitHostPort(listen)
	ip := net.ParseIP(host)
	require(e == nil && ip != nil && ip.To4() != nil && ip.IsPrivate() && port == "0", "private bridge and ephemeral port required")
	var nonce [16]byte
	_, e = rand.Read(nonce[:])
	require(e == nil, "random nonce")
	c, e := net.ListenUDP("udp4", &net.UDPAddr{IP: ip.To4()})
	require(e == nil, "UDP listener")
	defer c.Close()
	require(c.SetReadBuffer(4<<20) == nil, "receive buffer")
	c.SetDeadline(time.Now().Add(90 * time.Second))
	tcpAddress := ""
	if tcpMode {
		listener := startTCPServer(ip, nonce[:])
		defer listener.Close()
		tcpAddress = listener.Addr().String()
	}
	emit(map[string]any{"event": "ready", "address": c.LocalAddr().String(), "tcp_address": tcpAddress, "nonce": hex.EncodeToString(nonce[:])})
	flows := map[string]*flow{}
	for {
		data := make([]byte, size+1)
		n, peer, e := c.ReadFromUDP(data)
		require(e == nil, "fixture receive: "+fmt.Sprint(e))
		data = data[:n]
		phase, uid, seq, count, seg := fields(data, nonce[:])
		key := fmt.Sprintf("%d-%d", phase, uid)
		f := flows[key]
		if f == nil {
			f = &flow{peer: peer.String(), seen: map[int]bool{}, packets: make([][]byte, count), first: mono()}
			flows[key] = f
		}
		require(f.peer == peer.String() && len(f.packets) == count && !f.seen[seq], "duplicate or changed flow")
		f.seen[seq] = true
		f.packets[seq] = data
		if seg {
			base := seq / batch * batch
			complete := true
			for i := base; i < base+batch; i++ {
				if f.packets[i] == nil {
					complete = false
				}
			}
			if complete {
				var joined []byte
				for i := base; i < base+batch; i++ {
					joined = append(joined, f.packets[i]...)
				}
				e = send(c, joined, peer, true)
				require(e == nil, "fixture UDP_SEGMENT: "+fmt.Sprint(e))
				f.sent += batch
			}
		} else {
			e = send(c, data, peer, false)
			require(e == nil, "fixture reply")
			f.sent++
		}
		if len(f.seen) == count && f.sent == count {
			emit(map[string]any{"event": "complete", "phase": phase, "uid": uid, "packets": count, "payload_bytes": count * size, "segmented": seg, "peer": peer.String(), "first_ns": f.first, "end_ns": mono()})
		}
	}
}
func rawPacket(c *net.UDPConn, destination *net.UDPAddr, data []byte, sequence int) []byte {
	local := c.LocalAddr().(*net.UDPAddr)
	p := make([]byte, 28+len(data))
	p[0] = 0x45
	p[8] = 64
	p[9] = 17
	binary.BigEndian.PutUint16(p[2:], uint16(len(p)))
	binary.BigEndian.PutUint16(p[4:], uint16(sequence))
	binary.BigEndian.PutUint16(p[6:], 0x4000)
	copy(p[12:], local.IP.To4())
	copy(p[16:], destination.IP.To4())
	binary.BigEndian.PutUint16(p[20:], uint16(local.Port))
	binary.BigEndian.PutUint16(p[22:], uint16(destination.Port))
	binary.BigEndian.PutUint16(p[24:], uint16(len(data)+8))
	copy(p[28:], data)
	// Linux supplies the IP checksum; UDP checksum zero is permitted for IPv4.
	return p
}
func workerReady(uid int) {
	require((uid == 0 || uid == 1000) && os.Getuid() == uid && os.Geteuid() == uid && os.Getgid() == uid, "worker UID/GID mismatch")
	status, e := os.ReadFile("/proc/self/status")
	require(e == nil, "process status")
	capabilities := ""
	for _, line := range strings.Split(string(status), "\n") {
		if strings.HasPrefix(line, "CapEff:") {
			capabilities = strings.TrimSpace(strings.TrimPrefix(line, "CapEff:"))
		}
	}
	cgroup, e := os.ReadFile("/proc/self/cgroup")
	require(e == nil, "cgroup")
	emit(map[string]any{"event": "ready", "uid": os.Getuid(), "gid": os.Getgid(), "pid": os.Getpid(), "cap_eff": capabilities, "cgroup": string(cgroup)})
	command, e := bufio.NewReader(os.Stdin).ReadString('\n')
	require(e == nil && command == "start\n", "start barrier")
}
func worker(address, nonceText string, phase, uid, count int, segmented, rawMode, loopback bool) {
	require(os.Getuid() == uid && os.Geteuid() == uid && os.Getgid() == uid, "worker UID/GID mismatch")
	require((uid == 0 || uid == 1000) && count > 0 && count <= 1024 && (!segmented || count%batch == 0) && (!rawMode || uid == 0 && !segmented), "worker options")
	nonce, e := hex.DecodeString(nonceText)
	require(e == nil && len(nonce) == 16, "nonce")
	workerReady(uid)
	destination := endpoint(address)
	if loopback {
		local, e := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		require(e == nil, "loopback listener")
		defer local.Close()
		local.SetDeadline(time.Now().Add(15 * time.Second))
		destination = local.LocalAddr().(*net.UDPAddr)
		go func() {
			for i := 0; i < count; i++ {
				b := make([]byte, size+1)
				n, p, e := local.ReadFromUDP(b)
				if e != nil {
					return
				}
				if _, e = local.WriteToUDP(b[:n], p); e != nil {
					return
				}
			}
		}()
	}
	c, e := net.DialUDP("udp4", nil, destination)
	require(e == nil, "worker socket")
	defer c.Close()
	c.SetDeadline(time.Now().Add(15 * time.Second))
	var rawFD int = -1
	if rawMode {
		rawFD, e = syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.IPPROTO_UDP)
		require(e == nil, "raw socket")
		defer syscall.Close(rawFD)
		require(syscall.SetsockoptInt(rawFD, syscall.IPPROTO_IP, syscall.IP_HDRINCL, 1) == nil, "IP_HDRINCL")
	}
	received := make(chan error, 1)
	go func() {
		seen := map[int]bool{}
		for i := 0; i < count; i++ {
			b := make([]byte, size+1)
			n, e := c.Read(b)
			if e != nil {
				received <- e
				return
			}
			p, u, seq, total, seg := fields(b[:n], nonce)
			if p != phase || u != uid || total != count || seg != segmented || seen[seq] {
				received <- fmt.Errorf("reply mismatch/duplicate")
				return
			}
			seen[seq] = true
		}
		received <- nil
	}()
	start := mono()
	step := 1
	if segmented {
		step = batch
	}
	for seq := 0; seq < count; seq += step {
		var data []byte
		for i := seq; i < seq+step; i++ {
			data = append(data, packet(nonce, phase, uid, i, count, segmented)...)
		}
		if rawMode {
			peer := &syscall.SockaddrInet4{Port: destination.Port}
			copy(peer.Addr[:], destination.IP.To4())
			e = syscall.Sendto(rawFD, rawPacket(c, destination, data, seq), 0, peer)
		} else {
			e = send(c, data, nil, segmented)
		}
		require(e == nil, "worker send: "+fmt.Sprint(e))
		time.Sleep(time.Millisecond)
	}
	receiveError := <-received
	require(receiveError == nil, "missing or invalid reply: "+fmt.Sprint(receiveError))
	emit(map[string]any{"event": "complete", "uid": uid, "phase": phase, "packets": count, "payload_bytes": count * size, "segmented": segmented, "raw": rawMode, "loopback": loopback, "start_ns": start, "end_ns": mono(), "local": c.LocalAddr().String(), "remote": c.RemoteAddr().String()})
}
func main() {
	defer func() {
		if value := recover(); value != nil {
			fmt.Fprintln(os.Stderr, "error:", value)
			os.Exit(1)
		}
	}()
	mode := flag.String("mode", "worker", "server or worker")
	listen := flag.String("listen", "", "private fixture listen address")
	address := flag.String("address", "", "literal fixture endpoint")
	nonce := flag.String("nonce", "", "fixture nonce")
	phase := flag.Int("phase", 0, "unique phase")
	uid := flag.Int("uid", 0, "expected UID")
	count := flag.Int("count", 64, "datagrams")
	seg := flag.Bool("segmented", false, "real UDP_SEGMENT")
	rawMode := flag.Bool("raw", false, "root IPv4 raw socket")
	loop := flag.Bool("loopback", false, "owned loopback echo")
	tcpMode := flag.Bool("tcp", false, "controlled bidirectional TCP stream")
	flag.Parse()
	if *mode == "server" {
		server(*listen, *tcpMode)
	} else {
		require(*mode == "worker", "mode")
		if *tcpMode {
			require(!*seg && !*rawMode && !*loop, "TCP options")
			tcpWorker(*address, *nonce, *phase, *uid)
		} else {
			worker(*address, *nonce, *phase, *uid, *count, *seg, *rawMode, *loop)
		}
	}
}
