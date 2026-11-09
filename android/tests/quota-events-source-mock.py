"""Extend the existing syscall mock with the source's queried map identities."""
from pathlib import Path
import sys

root, output = map(Path, sys.argv[1:])
text = (root/'android/tests/interface-quota-native.cpp').read_text().split('int main()')[0]
before = '    int direction = strstr(name,"egress") != nullptr;'
assert text.count(before) == 1
text = text.replace(before, '    if (!strcmp(name,"map_netd_iface_stats_map")) return 13;\n'+before)
before = '        value->max_entries = 1;value->map_flags = BPF_F_NO_PREALLOC;'
assert text.count(before) == 1
text = text.replace(before, before+'\n        value->id = fault == 20 ? 0 : 110;')
before = '    } else {\n        assert(fd >= 30);'
assert text.count(before) == 1
text = text.replace(before, '''    } else if (fd == 11 || fd == 13) {
        auto* value = reinterpret_cast<bpf_map_info*>(&output);
        value->id = ((fd == 11 && fault == 21) || (fd == 13 && fault == 22)) ? 0 : 100+fd;
    } else {
        assert(fd >= 30);''')
before = '    if (fd == 11) { assert(index == 0);memset(&output,0,sizeof(output));return true; }'
assert text.count(before) == 1
text = text.replace(before, '''    if (fd == 11) {
        assert(index == 0);memset(&output,0,sizeof(output));
        if (fault == 23) reinterpret_cast<uint64_t*>(&output)[0]=1;
        if (fault == 24) reinterpret_cast<uint64_t*>(&output)[1]=1;
        return true;
    }''')
(output/'quota-event-mock.inc').write_text(text)
(output/'RoydInterfaceAccounting.h').write_text('')
