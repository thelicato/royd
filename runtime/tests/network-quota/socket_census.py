"""Bounded private-namespace TCP/proc observation. No socket or policy mutation."""
import ipaddress
import json
import os
from pathlib import Path
import re
import resource
import socket
import struct
import sys
import time
import traceback
from packet_headers import need, publish

INTERVAL, LIFETIME, MAX_SAMPLES, MAX_SOCKETS, MAX_PIDS, MAX_FDS = .1, 600, 6000, 256, 4096, 8192


def endpoint(value, family):
    address, port = value.split(':')
    need(len(address) == (8 if family == 4 else 32) and len(port) == 4, 'invalid proc TCP endpoint')
    packed = b''.join(struct.pack('=I', int(address[i:i+8],16)) for i in range(0,len(address),8))
    ip = ipaddress.ip_address(packed)
    if isinstance(ip,ipaddress.IPv6Address) and ip.ipv4_mapped: ip = ip.ipv4_mapped
    return dict(address=str(ip),port=int(port,16))


def parse(text, family):
    rows = text.splitlines()
    need(rows and 'local_address' in rows[0] and 'inode' in rows[0], 'missing proc TCP header')
    result = []
    for line in rows[1:]:
        values = line.split();need(len(values) >= 10, 'short proc TCP row')
        tx,rx = values[4].split(':');timer,when = values[5].split(':')
        state = int(values[3],16);uid,inode = int(values[7]),int(values[9])
        need(0 < state <= 12 and 0 <= uid < 1 << 32 and inode >= 0, 'invalid proc TCP identity')
        result.append(dict(family=family,local=endpoint(values[1],family),remote=endpoint(values[2],family),
                           state=state,uid=uid,inode=inode,tx_queue=int(tx,16),rx_queue=int(rx,16),
                           timer=int(timer,16),timer_jiffies=int(when,16),retransmits=int(values[6],16)))
    need(len(result) <= MAX_SOCKETS, 'TCP socket bound exceeded')
    return result


def process_identity(path, namespace):
    need(os.readlink(path/'ns/net') == namespace, 'process namespace changed')
    stat = (path/'stat').read_text();pid = int(path.name)
    need(stat.startswith(str(pid)+' ('), 'process PID changed')
    ticks = int(stat.rsplit(')',1)[1].split()[19])
    status = (path/'status').read_text()
    match = re.search(r'^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$',status,re.M)
    need(match is not None, 'process UIDs missing')
    uids = [int(x) for x in match.groups()]
    nspid = re.search(r'^NSpid:\s+([0-9 \t]+)$',status,re.M)
    return dict(pid=pid,start_ticks=ticks,uids=uids,nspid=[int(x) for x in nspid[1].split()] if nspid else [])


def owners(rows, namespace, proc=Path('/proc')):
    wanted = {r['inode']:r['uid'] for r in rows if r['inode']}
    found, races = [], []
    paths = [p for p in proc.iterdir() if p.name.isdecimal()]
    need(len(paths) <= MAX_PIDS, 'process scan bound exceeded')
    for path in paths:
        verified = False
        try:
            if os.readlink(path/'ns/net') != namespace: continue
            verified = True
            before = process_identity(path,namespace)
            fds = list((path/'fd').iterdir());need(len(fds) <= MAX_FDS, 'process FD bound exceeded')
            matches = []
            for fd in fds:
                try: target = os.readlink(fd)
                except FileNotFoundError: continue  # Closing descriptors are normal; never infer absence.
                match = re.fullmatch(r'socket:\[(\d+)\]',target)
                if match and int(match[1]) in wanted: matches.append(dict(fd=int(fd.name),inode=int(match[1])))
            if matches:
                command = (path/'cmdline').open('rb')
                with command: name = command.read(256).split(b'\0',1)[0].decode(errors='replace')
                cgroup = (path/'cgroup').read_text()
                need(process_identity(path,namespace) == before, 'process identity raced during FD scan')
                found.append(dict(**before,name=name,cgroup=cgroup,sockets=matches))
        except (FileNotFoundError,ProcessLookupError):
            if verified: races.append(int(path.name))
    return dict(processes=found,vanished_pids=races)


def observe(directory, namespace, ifindex, parent_pid):
    need(os.readlink('/proc/self/ns/net') == namespace
         and namespace != os.readlink('/proc/'+str(parent_pid)+'/ns/net'), 'private network namespace required')
    need(socket.if_nametoindex('eth0') == ifindex > 1, 'eth0 identity changed')
    opened = time.monotonic_ns();samples = scans = 0;errors = [];previous = set();last_scan = 0
    try:
        with (directory/'samples.jsonl').open('x') as output:
            publish(directory,'ready',dict(pid=os.getpid(),namespace=namespace,ifindex=ifindex,
                    interval_seconds=INTERVAL,lifetime_seconds=LIFETIME,monotonic_ns=opened))
            while not (directory/'stop').exists():
                start = time.monotonic_ns()
                need(start-opened < LIFETIME*1e9 and samples < MAX_SAMPLES, 'census lifetime/sample bound exceeded')
                rows = []
                for family,name in ((4,'tcp'),(6,'tcp6')):
                    try: text = Path('/proc/thread-self/net/'+name).read_text()
                    except FileNotFoundError:
                        need(family == 6, 'IPv4 TCP table unavailable');continue
                    rows.extend(parse(text,family))
                need(len(rows) <= MAX_SOCKETS, 'combined socket bound exceeded')
                inodes = {r['inode'] for r in rows if r['inode']}
                association = None
                if inodes and (inodes-previous or start-last_scan >= 1e9):
                    association = owners(rows,namespace);scans += 1;last_scan = start
                previous = inodes
                samples += 1
                output.write(json.dumps(dict(sequence=samples,start_ns=start,end_ns=time.monotonic_ns(),
                                             sockets=rows,owners=association))+'\n');output.flush()
                time.sleep(max(0,INTERVAL-(time.monotonic_ns()-start)/1e9))
    except BaseException: errors.append(traceback.format_exc())
    publish(directory,'result',dict(status='fail' if errors else 'pass',samples=samples,owner_scans=scans,
            namespace=namespace,ifindex=ifindex,errors=errors,closed_monotonic_ns=time.monotonic_ns(),
            cpu_user_seconds=resource.getrusage(resource.RUSAGE_SELF).ru_utime,
            cpu_system_seconds=resource.getrusage(resource.RUSAGE_SELF).ru_stime))
    return 1 if errors else 0


if __name__=='__main__':
    need(len(sys.argv)==5,'usage: socket_census.py OUTPUT NETNS IFINDEX PARENT_PID')
    sys.exit(observe(Path(sys.argv[1]),sys.argv[2],int(sys.argv[3]),int(sys.argv[4])))
