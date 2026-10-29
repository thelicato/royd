"""Bounded request/reply channel to the owned native Java test controller."""
import json
import os
import select
import time
from assess import need

LIMIT = 16384


class Channel:
    def __init__(self, process, nonce, directory, *, prefix='controller', uid=0):
        self.process, self.nonce = process, nonce
        self.sequence, self.broken = 0, False
        self.closed = False
        self.buffer = bytearray()
        self.raw = (directory/(prefix+'-stdout.bin')).open('xb')
        self.events = (directory/(prefix+'-events.jsonl')).open('x')
        os.set_blocking(process.stdin.fileno(), False)
        try:
            self.hello = self.receive(20)
            need(self.hello.get('nonce') == nonce and self.hello.get('seq') == 0
                 and self.hello.get('status') == 'ready' and self.hello.get('uid') == uid
                 and self.hello.get('pid', 0) > 1, 'controller greeting identity')
            need(uid == 0 or int(self.hello['cap_eff'], 16) == 0, 'controller gained capabilities')
        except BaseException:
            self.raw.close();self.events.close()
            raise

    def event(self, kind, value):
        self.events.write(json.dumps(dict(kind=kind, monotonic_ns=time.monotonic_ns(), value=value))+'\n')
        self.events.flush()

    def receive(self, seconds):
        deadline = time.monotonic()+seconds
        while b'\n' not in self.buffer:
            need(len(self.buffer) <= LIMIT, 'controller reply exceeds bound')
            remaining = deadline-time.monotonic()
            if remaining <= 0: raise TimeoutError('controller reply timed out')
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            if not ready: raise TimeoutError('controller reply timed out')
            data = os.read(self.process.stdout.fileno(), 4096)
            if not data: raise EOFError('controller closed without a reply')
            self.raw.write(data);self.raw.flush()
            self.buffer.extend(data)
        line, _, rest = self.buffer.partition(b'\n')
        need(len(line) <= LIMIT and not rest, 'controller reply bound/unsolicited output')
        self.buffer = bytearray(rest)
        value = json.loads(line)
        self.event('reply', value)
        return value

    def request(self, op, *, timeout=25, **args):
        if self.process.poll() is not None: self.broken = True
        need(not self.broken, 'controller unavailable')
        request = dict(args, nonce=self.nonce, seq=self.sequence+1, op=op)
        encoded = json.dumps(request, separators=(',', ':')).encode()+b'\n'
        need(len(encoded) <= LIMIT and self.sequence < 512, 'controller request bound')
        self.sequence += 1
        self.event('request', request)
        try:
            deadline, offset = time.monotonic()+timeout, 0
            while offset < len(encoded):
                remaining = deadline-time.monotonic()
                if remaining <= 0: raise TimeoutError('controller write timed out')
                _, writable, _ = select.select([], [self.process.stdin], [], remaining)
                if not writable: raise TimeoutError('controller write timed out')
                try: count = os.write(self.process.stdin.fileno(), encoded[offset:])
                except BlockingIOError: continue
                need(count > 0, 'controller write failed')
                offset += count
            reply = self.receive(max(0, deadline-time.monotonic()))
            need(reply.get('nonce') == self.nonce and reply.get('seq') == self.sequence
                 and reply.get('status') == 'pass' and isinstance(reply.get('value'), dict), 'controller reply identity/status')
            return reply['value']
        except BaseException:
            self.broken = True
            raise

    def close(self):
        try:
            need(not self.broken, 'controller channel failed')
            need(self.request('stop', timeout=10) == dict(stopped=True), 'controller stop receipt')
            self.process.stdin.close()
            need(self.process.wait(timeout=10) == 0, 'controller exit failed')
        except BaseException:
            self.broken = True
            raise
        finally:
            self.closed = True
            if not self.process.stdin.closed: self.process.stdin.close()
            self.raw.close();self.events.close()
