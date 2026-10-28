"""Bounded nonce UDP fixture. No echo, files served, retries or host configuration."""
import hashlib
import ipaddress
import json
import secrets
import socket
import struct
import threading
import time

SIZE, IP_BYTES = 1200, 1228


def packet(nonce, step, uid, sequence, count, kind):
    if len(nonce) != 16 or not 1 <= step <= 128 or not 0 < uid < 20000:
        raise ValueError('packet identity')
    if not 1 <= count <= 64 or not 0 <= sequence < count or kind not in (1, 2):
        raise ValueError('packet range')
    value = bytearray(SIZE)
    value[:33] = struct.pack('!16sIIIIB', nonce, step, uid, sequence, count, kind)
    for i in range(33, SIZE):
        value[i] = (i + sequence + uid) & 255
    return bytes(value)


def decode(data, nonce):
    if len(data) != SIZE:
        raise ValueError('packet size')
    received, step, uid, sequence, count, kind = struct.unpack('!16sIIIIB', data[:33])
    if received != nonce or data != packet(nonce, step, uid, sequence, count, kind):
        raise ValueError('packet contents')
    return dict(step=step, uid=uid, sequence=sequence, count=count, kind=kind)


class Fixture:
    def __init__(self, address, log):
        if ipaddress.ip_address(address).version != 4 or not ipaddress.ip_address(address).is_private:
            raise ValueError('private IPv4 fixture required')
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind((address, 0))
        self.socket.settimeout(.1)
        self.address = '%s:%s' % self.socket.getsockname()
        self.nonce = secrets.token_bytes(16)
        self.log = log.open('x')
        self.lock = threading.Lock()
        self.rows, self.errors, self.peers, self.seen = [], [], {}, set()
        self.stop = threading.Event()
        self.initial_drops = self.drops()
        self.thread = threading.Thread(target=self.receive)
        self.thread.start()

    def drops(self):
        # Linux SOL_SOCKET/SO_MEMINFO, SK_MEMINFO_DROPS. Read this owned socket only.
        return struct.unpack('=9I', self.socket.getsockopt(socket.SOL_SOCKET, 55, 36))[8]

    def emit(self, event):
        with self.lock:
            self.rows.append(event)
            self.log.write(json.dumps(event) + '\n')
            self.log.flush()

    def register(self, uid, endpoint):
        host, port = endpoint.rsplit(':', 1)
        with self.lock:
            if uid in self.peers or endpoint in ['%s:%s' % x for x in self.peers.values()]:
                raise ValueError('duplicate endpoint/UID')
            self.peers[uid] = (host, int(port))

    def receive(self):
        try:
            while not self.stop.is_set():
                try:
                    data, peer = self.socket.recvfrom(SIZE + 1)
                except socket.timeout:
                    continue
                value = decode(data, self.nonce)
                identity = (value['uid'], value['step'], value['sequence'])
                with self.lock:
                    if value['kind'] != 1 or self.peers.get(value['uid']) != peer or identity in self.seen:
                        raise ValueError('unowned or duplicate fixture packet')
                    self.seen.add(identity)
                self.emit(dict(event='receive', peer='%s:%s' % peer, sha256=hashlib.sha256(data).hexdigest(),
                               monotonic_ns=time.monotonic_ns(), **value))
        except Exception as error:
            with self.lock:
                self.errors.append(repr(error))

    def push(self, uid, step, count):
        with self.lock:
            peer = self.peers[uid]
        for sequence in range(count):
            data = packet(self.nonce, step, uid, sequence, count, 2)
            if self.socket.sendto(data, peer) != SIZE:
                raise RuntimeError('incomplete fixture send')
            self.emit(dict(event='push', uid=uid, step=step, count=count, sequence=sequence,
                           kind=2, peer='%s:%s' % peer, sha256=hashlib.sha256(data).hexdigest(),
                           monotonic_ns=time.monotonic_ns()))
            time.sleep(.002)

    def records(self):
        with self.lock:
            if self.errors:
                raise RuntimeError('fixture failed: ' + repr(self.errors))
            return list(self.rows)

    def close(self):
        self.stop.set()
        self.thread.join(timeout=2)
        if self.thread.is_alive():
            raise RuntimeError('fixture thread did not stop')
        errors = list(self.errors)
        drops = self.drops()
        self.socket.close()
        self.log.close()
        if errors or drops != 0 or self.initial_drops != 0:
            raise RuntimeError('fixture errors/drops: ' + repr((errors, self.initial_drops, drops)))
        return dict(initial_drops=self.initial_drops, final_drops=drops, errors=errors)
