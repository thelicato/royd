"""Bounded receive-only eth0 header diagnostics in a verified private namespace."""
import ipaddress
import json
import os
from pathlib import Path
import socket
import struct
import sys
import time
import traceback

PREFIX_BYTES, MAX_FRAMES, LIFETIME_SECONDS = 128, 4096, 600
SOL_PACKET, PACKET_STATISTICS, SO_TIMESTAMPNS = 263, 6, 35


def need(value, reason):
    if not value: raise ValueError(reason)


def metadata(data, frame_bytes):
    """Persist selected Ethernet/IP/transport/DNS-header fields only, never payload."""
    need(len(data) >= 14 and frame_bytes >= len(data), 'short Ethernet frame')
    ether = struct.unpack_from('!H', data, 12)[0]
    result = dict(frame_bytes=frame_bytes, ether_type=ether)
    if ether == 0x0800:
        need(len(data) >= 34 and data[14] >> 4 == 4, 'short/invalid IPv4 header')
        size = (data[14] & 15)*4
        total, fragment = struct.unpack_from('!H2xH', data, 16)
        need(20 <= size <= 60 and len(data) >= 14+size and size <= total <= frame_bytes-14,
             'invalid IPv4 lengths')
        result.update(family=4, ip_bytes=total, protocol=data[23],
                      source=str(ipaddress.ip_address(data[26:30])),
                      destination=str(ipaddress.ip_address(data[30:34])), fragmented=bool(fragment & 0x3fff))
        offset = 14+size
    elif ether == 0x86dd:
        need(len(data) >= 54 and data[14] >> 4 == 6, 'short/invalid IPv6 header')
        size = struct.unpack_from('!H', data, 18)[0]
        need(size+40 <= frame_bytes-14, 'invalid IPv6 length')
        result.update(family=6, ip_bytes=size+40 if size else None, protocol=data[20],
                      source=str(ipaddress.ip_address(data[22:38])),
                      destination=str(ipaddress.ip_address(data[38:54])), fragmented=None)
        offset = 54
    else:
        return result
    # Fragment/extension/jumbogram metadata is retained without invented ports/cost.
    if result['fragmented'] or result['ip_bytes'] is None: return result
    protocol = result['protocol']
    if protocol not in (6, 17): return result
    required = 20 if protocol == 6 else 8
    need(len(data) >= offset+required and result['ip_bytes'] >= offset-14+required,
         'short transport header')
    source, destination = struct.unpack_from('!HH', data, offset)
    result.update(source_port=source, destination_port=destination)
    if protocol == 6:
        result['tcp_flags'] = data[offset+13]
    else:
        length = struct.unpack_from('!H', data, offset+4)[0]
        need(length >= 8, 'invalid UDP length')
        result['udp_bytes'] = length
        if 53 in (source, destination) and length >= 20:
            need(len(data) >= offset+20, 'short DNS header prefix')
            fields = struct.unpack_from('!6H', data, offset+8)
            result['dns_header'] = dict(zip(('id', 'flags', 'questions', 'answers', 'authority', 'additional'), fields))
    return result


def timestamp(ancillary, flags):
    need(not flags & socket.MSG_CTRUNC, 'truncated packet timestamp')
    values = [data for level, kind, data in ancillary if level == socket.SOL_SOCKET and kind == SO_TIMESTAMPNS]
    need(len(values) == 1 and len(values[0]) == struct.calcsize('@ll'), 'missing/ambiguous packet timestamp')
    seconds, nanos = struct.unpack('@ll', values[0])
    need(seconds > 0 and 0 <= nanos < 1000000000, 'invalid packet timestamp')
    return seconds*1000000000+nanos


def publish(directory, name, value):
    temporary = directory/(name+'.tmp')
    with temporary.open('x') as output: json.dump(value, output, indent=2);output.write('\n')
    os.link(temporary, directory/(name+'.json'))
    temporary.unlink()


def observe(directory, expected_namespace, expected_ifindex, parent_pid):
    need(os.readlink('/proc/self/ns/net') == expected_namespace
         and expected_namespace != os.readlink('/proc/'+str(parent_pid)+'/ns/net'), 'private network namespace required')
    need(socket.if_nametoindex('eth0') == expected_ifindex and expected_ifindex > 1, 'eth0 identity changed')
    need(sys.platform == 'linux' and struct.calcsize('@ll') == 16, 'Linux 64-bit timestamp ABI required')
    frames, errors, packets, drops = 0, [], None, None
    opened = time.monotonic_ns()
    # Protocol zero registers no receive hook. Arm only the selected private eth0.
    with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, 0) as receiver, (directory/'headers.jsonl').open('x') as output:
        receiver.setsockopt(socket.SOL_SOCKET, SO_TIMESTAMPNS, 1)
        receiver.settimeout(.1)
        receiver.bind(('eth0', 3))  # ETH_P_ALL, host order in Python's address tuple.
        try:
            publish(directory, 'ready', dict(namespace=expected_namespace, ifindex=expected_ifindex,
                    pid=os.getpid(), prefix_bytes=PREFIX_BYTES, max_frames=MAX_FRAMES,
                    lifetime_seconds=LIFETIME_SECONDS, monotonic_ns=opened))
            while True:
                need(time.monotonic_ns()-opened < LIFETIME_SECONDS*1000000000, 'header observer lifetime exceeded')
                if (directory/'stop').exists(): receiver.setblocking(False)
                prefix = bytearray(PREFIX_BYTES)
                try:
                    count, ancillary, flags, address = receiver.recvmsg_into(
                        [prefix], socket.CMSG_SPACE(16), socket.MSG_TRUNC)
                except (BlockingIOError, socket.timeout):
                    if (directory/'stop').exists(): break
                    continue
                frames += 1
                need(frames <= MAX_FRAMES and address[0] == 'eth0', 'header frame bound/interface')
                row = metadata(bytes(prefix[:min(count, PREFIX_BYTES)]), count)
                row.update(sequence=frames, packet_type=address[2],
                           direction='egress' if address[2] == socket.PACKET_OUTGOING else 'ingress',
                           kernel_realtime_ns=timestamp(ancillary, flags), received_monotonic_ns=time.monotonic_ns())
                output.write(json.dumps(row)+'\n');output.flush()
        except BaseException:
            errors.append(traceback.format_exc())
        finally:
            # One read only: PACKET_STATISTICS resets these owned-socket counters.
            packets, drops = struct.unpack('=II', receiver.getsockopt(SOL_PACKET, PACKET_STATISTICS, 8))
    if packets != frames or drops != 0: errors.append('packet socket loss/pending frames: '+repr((packets, frames, drops)))
    result = dict(status='fail' if errors else 'pass', frames=frames, packets=packets, drops=drops,
                  errors=errors, namespace=expected_namespace, ifindex=expected_ifindex,
                  closed_monotonic_ns=time.monotonic_ns())
    publish(directory, 'result', result)
    return 0 if not errors else 1


if __name__ == '__main__':
    need(len(sys.argv) == 5, 'usage: packet_headers.py OUTPUT_DIRECTORY NETNS IFINDEX PARENT_PID')
    sys.exit(observe(Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]), int(sys.argv[4])))
