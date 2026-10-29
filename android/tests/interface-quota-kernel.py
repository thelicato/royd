"""Load exact Android ELF instructions into unpinned maps; synthetic packets only."""
import concurrent.futures
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import struct
import sys
import threading
import traceback


class Kernel:
    def __init__(self, output):
        assert platform.machine() == 'x86_64', 'x86_64 diagnostic only'
        self.output, self.fds = output, []
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.libc.syscall.restype = ctypes.c_long

    def call(self, operation, fields):
        attr = ctypes.create_string_buffer(256)
        for offset, encoding, value in fields:
            struct.pack_into('<'+encoding, attr, offset, value)
        result = self.libc.syscall(ctypes.c_long(321), ctypes.c_int(operation),
                                   ctypes.byref(attr), ctypes.c_uint(len(attr)))
        if result < 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        return result, attr.raw

    def map(self, name, layout):
        kind, key, value, count, flags = layout
        fd, _ = self.call(0, [(n*4, 'I', v) for n, v in enumerate(layout)]
                         + [(28, '16s', name.encode()[:15])])
        self.fds.append(fd)
        return fd

    def lookup(self, fd, key, size):
        k, value = ctypes.c_uint(key), ctypes.create_string_buffer(size)
        self.call(1, [(0,'I',fd),(8,'Q',ctypes.addressof(k)),(16,'Q',ctypes.addressof(value))])
        return value.raw

    def update(self, fd, key, value):
        k, v = ctypes.c_uint(key), ctypes.create_string_buffer(value)
        self.call(2, [(0,'I',fd),(8,'Q',ctypes.addressof(k)),(16,'Q',ctypes.addressof(v))])

    def delete(self, fd, key):
        k = ctypes.c_uint(key)
        self.call(3, [(0,'I',fd),(8,'Q',ctypes.addressof(k))])

    def load(self, name, code):
        insns, license = ctypes.create_string_buffer(code), ctypes.create_string_buffer(b'Apache 2.0')
        log = ctypes.create_string_buffer(1024*1024)
        try:
            fd, _ = self.call(5, [(0,'I',3),(4,'I',len(code)//8),(8,'Q',ctypes.addressof(insns)),
                (16,'Q',ctypes.addressof(license)),(24,'I',1),(28,'I',len(log)),
                (32,'Q',ctypes.addressof(log)),(48,'16s',name.encode()[:15])])
        finally:
            (self.output/(name+'-verifier.log')).write_bytes(log.value)
        self.fds.append(fd)
        return fd

    def packet(self, fd, data):
        source, target = ctypes.create_string_buffer(bytes(data)), ctypes.create_string_buffer(65536)
        context = ctypes.create_string_buffer(256)
        _, result = self.call(10, [(0,'I',fd),(8,'I',len(data)),(12,'I',len(target)),
             (16,'Q',ctypes.addressof(source)),(24,'Q',ctypes.addressof(target)),(32,'I',1),
             (44,'I',len(context)),(56,'Q',ctypes.addressof(context))])
        assert struct.unpack_from('<I',result,12)[0] == len(data) and target.raw[:len(data)] == data
        return struct.unpack_from('<I',result,4)[0], struct.unpack_from('<I',context,40)[0]

    def close(self):
        for fd in reversed(self.fds): os.close(fd)


def load_elf(kernel, path):
    data = path.read_bytes()
    header = struct.unpack_from('<16sHHIQQQIHHHHHH',data)
    assert data[:6] == b'\x7fELF\x02\x01' and header[2] == 247, 'little-endian ELF64 BPF required'
    offset, size, count, names_index = header[6], header[11], header[12], header[13]
    sections = [struct.unpack_from('<IIQQQQIIQQ',data,offset+n*size) for n in range(count)]
    def contents(section): return data[section[4]:section[4]+section[5]]
    def string(table, index): return table[index:table.index(b'\0',index)].decode()
    names = contents(sections[names_index])
    by_name = {string(names,s[0]):(i,s) for i,s in enumerate(sections)}
    symbols = {}
    _, symtab = by_name['.symtab']; strings = contents(sections[symtab[6]])
    for n in range(symtab[5]//symtab[9]):
        entry = struct.unpack_from('<IBBHQQ',contents(symtab),n*symtab[9])
        symbols[n] = (string(strings,entry[0]),entry[3],entry[4],entry[5])
    maps_index, map_section = by_name['maps']
    maps, layouts = {}, {}
    for name, section, start, length in symbols.values():
        if section == maps_index and name:
            layout = struct.unpack_from('<5I',contents(map_section),start)
            assert (name,layout) in [('quota_budget',(1,4,24,1,1)),('quota_drops',(2,4,16,1,0)),
                                   ('quota_admitted',(2,4,8,1,0))]
            metadata = struct.unpack_from('<12I',contents(map_section),start)
            assert metadata[5] == 0 and metadata[7] == 0o660
            assert 0 < metadata[8] < metadata[9] and metadata[10:12] == (0,0xffffffff)
            maps[name], layouts[name] = kernel.map(name,layout), list(layout)
    assert set(maps) == {'quota_budget','quota_drops','quota_admitted'}
    programs = []
    for name in ['schedcls/ingress','schedcls/egress']:
        index, section = by_name[name]; code = bytearray(contents(section)); relocations = 0
        for relocation in sections:
            if relocation[1] != 9 or relocation[7] != index: continue
            for n in range(relocation[5]//relocation[9]):
                position, reference = struct.unpack_from('<QQ',contents(relocation),n*relocation[9])
                symbol, target, _, _ = symbols[reference >> 32]
                assert reference & 0xffffffff == 1 and target == maps_index and code[position] == 0x18
                code[position+1] = (code[position+1] & 15) | 0x10
                struct.pack_into('<i',code,position+4,maps[symbol]); relocations += 1
        assert relocations > 0
        programs.append(kernel.load(name.rsplit('/',1)[1],bytes(code)))
    return maps, programs, layouts


def exercise(kernel, maps, programs):
    # Ethernet + IPv4 + UDP + payload, exactly 100 IP bytes, no actual network I/O.
    frame = bytearray(114); struct.pack_into('!H',frame,12,0x0800)
    frame[14] = 0x45; struct.pack_into('!H',frame,16,100); frame[23] = 17
    allowed, key = kernel.packet(programs[0],frame)
    assert allowed == 0xffffffff and key > 0
    budget = maps['quota_budget']
    def arm(amount, generation):kernel.update(budget,key,struct.pack('<3Q',amount,amount,generation))
    def remaining():return struct.unpack('<3Q',kernel.lookup(budget,key,24))
    arm(350,1)
    assert [kernel.packet(programs[n%2],frame)[0] for n in range(6)] == [0xffffffff]*3+[2]*3
    assert remaining() == (0,350,1)
    assert struct.unpack('<Q',kernel.lookup(maps['quota_admitted'],0,8))[0] == 300
    arm(100,2); assert kernel.packet(programs[0],frame)[0] == 0xffffffff
    assert remaining() == (0,100,2) and kernel.packet(programs[1],frame)[0] == 2
    assert struct.unpack('<Q',kernel.lookup(maps['quota_admitted'],0,8))[0] == 400
    arm(100,3)
    arp = bytearray(frame);struct.pack_into('!H',arp,12,0x0806)
    assert kernel.packet(programs[0],arp)[0] == 0xffffffff and remaining()[0] == 100
    malformed = bytearray(frame);malformed[14] = 0x44
    assert kernel.packet(programs[1],malformed)[0] == 2 and remaining()[0] == 100
    assert struct.unpack('<2Q',kernel.lookup(maps['quota_drops'],0,16))[0] == 1
    cpus = sorted(os.sched_getaffinity(0))[:4]
    assert len(cpus) >= 2, 'concurrency gate needs at least two permitted CPUs'
    def run_concurrent(replace):
        barrier = threading.Barrier(len(cpus)+1)
        cutover = threading.Barrier(len(cpus)+1)
        resume = threading.Barrier(len(cpus)+1)
        arm(100000,4)
        usage_before = struct.unpack('<Q',kernel.lookup(maps['quota_admitted'],0,8))[0]
        def worker(number, cpu):
            os.sched_setaffinity(0,{cpu});barrier.wait(timeout=10)
            accepted = 0
            for n in range(1200):
                if replace and n == 10:
                    cutover.wait(timeout=10);resume.wait(timeout=10)
                accepted += kernel.packet(programs[number%2],frame)[0] == 0xffffffff
            return accepted
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(cpus)) as pool:
            futures = [pool.submit(worker,n,cpu) for n,cpu in enumerate(cpus)]
            barrier.wait(timeout=10)
            if replace:
                cutover.wait(timeout=10);arm(100000,5);resume.wait(timeout=10)
            accepted = sum(f.result(timeout=30) for f in futures)
        assert remaining()[0] == 0
        assert accepted <= (2000 if replace else 1000)
        if not replace: assert accepted == 1000
        else: assert accepted == 1000+10*len(cpus)
        usage_after = struct.unpack('<Q',kernel.lookup(maps['quota_admitted'],0,8))[0]
        assert usage_after - usage_before == accepted * 100
        return dict(replacement=replace,accepted=accepted,upper_bound=2000 if replace else 1000)
    concurrency = [run_concurrent(False),run_concurrent(True)]
    kernel.delete(budget,key)
    assert all(kernel.packet(p,frame)[0] == 0xffffffff for p in programs)
    return dict(status='pass',synthetic_ifindex=key,cpus=cpus,concurrency=concurrency,
                scope='exact production Android ELF and private unpinned maps; synthetic test-run, no live interface attachment or Android image qualification')


def main():
    object_file, output = map(Path,sys.argv[1:])
    output.mkdir(exist_ok=False)
    kernel = Kernel(output)
    result = dict(status='fail',object_sha256=hashlib.sha256(object_file.read_bytes()).hexdigest())
    try:
        maps, programs, layouts = load_elf(kernel,object_file)
        result = exercise(kernel,maps,programs)
        result.update(object_sha256=hashlib.sha256(object_file.read_bytes()).hexdigest(),maps=layouts)
        print(json.dumps(result))
    except Exception:
        result['failure'] = traceback.format_exc()
        raise
    finally:
        kernel.close()
        (output/'result.json').write_text(json.dumps(result,indent=2)+'\n')


if __name__ == '__main__':main()
