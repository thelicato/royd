"""Bounded read-only conntrack dump in the owned IPv4 gateway namespace."""
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import sys
import time
from packet_headers import need

MAX_ENTRIES, MAX_BYTES = 256, 262144


def attributes(data):
    result = {};offset = 0
    while offset < len(data):
        need(len(data)-offset >= 4, 'short conntrack attribute')
        size,kind = struct.unpack_from('=HH',data,offset);kind &= 0x3fff
        need(4 <= size <= len(data)-offset and kind not in result, 'invalid/duplicate conntrack attribute')
        result[kind] = data[offset+4:offset+size];offset += (size+3)&~3
    need(offset == len(data), 'truncated conntrack attribute padding')
    return result


def integer(data, size):
    need(len(data) == size, 'invalid conntrack integer')
    return int.from_bytes(data,'big')


def tuple_value(data):
    a = attributes(data);ip = attributes(a[1]);proto = attributes(a[2])
    need(len(ip[1]) == len(ip[2]) == 4, 'conntrack IPv4 tuple required')
    value = dict(source=str(ipaddress.ip_address(ip[1])),destination=str(ipaddress.ip_address(ip[2])),
                 protocol=integer(proto[1],1))
    if value['protocol'] == 6:
        value.update(source_port=integer(proto[2],2),destination_port=integer(proto[3],2))
    return value


def entry(data):
    need(len(data) >= 4 and data[:4] == b'\x02\0\0\0', 'invalid conntrack family/header')
    a = attributes(data[4:]);original = tuple_value(a[1]);reply = tuple_value(a[2])
    need(original['protocol'] == reply['protocol'], 'conntrack protocol changed')
    if original['protocol'] != 6: return None
    state = integer(attributes(attributes(a[4])[1])[1],1)
    need(0 <= state <= 9, 'unknown conntrack TCP state')
    return dict(original=original,reply=reply,state=state,timeout_seconds=integer(a[7],4),
                status=integer(a[3],4),id=integer(a[12],4))


def messages(data, sequence, port, seen_flags=None):
    offset = 0;rows = [];done = False
    while offset < len(data):
        need(not done and len(data)-offset >= 16, 'short/trailing conntrack message')
        size,kind,flags,seq,pid = struct.unpack_from('=IHHII',data,offset)
        need(16 <= size <= len(data)-offset and seq == sequence and pid in (0,port),
             'invalid conntrack message identity/size')
        payload = data[offset+16:offset+size]
        if kind == 2:
            need(len(payload) >= 20 and struct.unpack_from('=IHHII',payload,4) == (20,0x101,0x301,sequence,port),
                 'unmatched conntrack kernel error')
            error = struct.unpack_from('=i',payload)[0]
            need(error < 0, 'unexpected conntrack acknowledgement')
            raise ValueError('conntrack kernel GET failed errno '+str(-error))
        # The requested IPv4 family creates the kernel's intentional dump filter.
        # Preserve MULTI/FILTERED, reject DUMP_INTR and every other flag.
        need(flags in (2,34), 'incomplete/interrupted conntrack dump: '+str(flags))
        if seen_flags is not None: seen_flags.add(flags)
        if kind == 3:
            need(len(payload) == 4 and struct.unpack('=i',payload)[0] == 0, 'conntrack dump completion error')
            done = True
        else:
            need(kind == 0x100, 'conntrack dump error/unknown message type: '+str(kind))
            value = entry(payload)
            if value is not None: rows.append(value)
        offset += (size+3)&~3
    need(offset == len(data), 'truncated conntrack message padding')
    return rows,done


def dump(namespace, forbidden):
    need(os.readlink('/proc/self/ns/net') == namespace and namespace not in forbidden,
         'owned gateway namespace required')
    # Require the already available handler, never ask the host to load it.
    need(Path('/sys/module/nf_conntrack_netlink').is_dir(), 'existing conntrack netlink handler required')
    sequence = secrets.randbits(32) or 1;rows = [];total = 0;count = 0;deadline = time.monotonic()+2;seen_flags = set()
    with socket.socket(socket.AF_NETLINK,socket.SOCK_RAW,12) as reader:
        reader.bind((0,0));port = reader.getsockname()[0];reader.settimeout(1)
        # Only IPCTNL_MSG_CT_GET + NLM_F_REQUEST|NLM_F_DUMP. No mutation or counter reset.
        request = struct.pack('=IHHII',20,0x101,0x301,sequence,port)+b'\x02\0\0\0'
        need(reader.sendto(request,(0,0)) == len(request), 'short conntrack GET')
        while True:
            need(time.monotonic() < deadline and count < 64, 'conntrack dump deadline/message bound exceeded')
            raw,ancillary,flags,sender = reader.recvmsg(65536,0);total += len(raw);count += 1
            need(sender == (0,0) and not flags and not ancillary and total <= MAX_BYTES,
                 'conntrack sender/truncation/size failure')
            batch,done = messages(raw,sequence,port,seen_flags);rows.extend(batch)
            need(len(rows) <= MAX_ENTRIES, 'conntrack entry bound exceeded')
            if done: break
    selected = [r for r in rows if any(t[k] == '10.254.0.2' for t in (r['original'],r['reply'])
                                     for k in ('source','destination'))]
    return dict(namespace=namespace,entries=selected,datagrams=count,bytes=total,reply_flags=sorted(seen_flags))


if __name__ == '__main__':
    need(len(sys.argv) == 4, 'usage: conntrack.py GATEWAY_NETNS ANDROID_NETNS HOST_NETNS')
    print(json.dumps(dump(sys.argv[1],sys.argv[2:])))
