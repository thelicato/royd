"""Apply both actual controller patches and verify the unchanged legacy bodies."""
from pathlib import Path
import subprocess
import sys

root, output = map(Path, sys.argv[1:])
source = output/'controller'
server = source/'system/netd/server'
server.mkdir(parents=True)
fixtures = root/'android/tests/fixtures/android15'
for suffix in ['cpp','h']:
    (server/('BandwidthController.'+suffix)).write_bytes((fixtures/('global-alert-bandwidth.'+suffix)).read_bytes())
for number in ['0070','0071']:
    patch = next((root/'android/patches/android-15.0.0_r36').glob(number+'-*.patch'))
    parts = patch.read_text().split('diff --git ')
    selected = ''.join('diff --git '+p for p in parts[1:] if p.startswith('a/system/netd/server/BandwidthController.'))
    subprocess.run(['patch','-s','--fuzz=0','-p1','-d',str(source)],input=selected,text=True,check=True)
    if number == '0070': before = (server/'BandwidthController.cpp').read_text()
after = (server/'BandwidthController.cpp').read_text()


def block(text, start):
    opening = text.index('{', start)
    depth = 1
    for i in range(opening+1,len(text)):
        depth += (text[i] == '{') - (text[i] == '}')
        if not depth: return text[start:i+1]
    raise AssertionError('incomplete method')


generated = []
stripped = after
for name in ['setInterfaceQuota','getInterfaceQuota','removeInterfaceQuota','setInterfaceAlert']:
    start = after.index('int BandwidthController::'+name+'(')
    method = block(after,start)
    gate_start = method.index('    if (android::net::royd::enabled() && iface == "eth0")')
    gate = block(method,gate_start)
    signature = method[:method.index('{')+1]
    generated.append(signature+'\n'+gate+'\n    ++legacy; return 77;\n}')
    stripped = stripped.replace(gate+'\n','',1)
stripped = stripped.replace('#include "RoydInterfaceQuota.h"\n','')
assert stripped == before, 'quota patch changed stock handling outside its exact gate'
program = r'''
#include <cassert>
#include <cstdint>
#include <cerrno>
#include <string>
namespace android::net::royd {
bool gate, hasQuota=true;int result, sets, reads, removes;int64_t request;
struct QuotaValue { uint64_t remaining=5,limit=10,generation=1; };
struct QuotaDrops {};
bool enabled() { return gate; }
int setQuota(int64_t bytes) { ++sets;request=bytes;return result; }
int removeQuota() { ++removes;return result; }
int readQuota(QuotaValue&,QuotaDrops&,bool& present) { ++reads;present=hasQuota;return result; }
}
class BandwidthController {
public:int legacy=0;
int setInterfaceQuota(const std::string&,int64_t);
int getInterfaceQuota(const std::string&,int64_t*);
int removeInterfaceQuota(const std::string&);
int setInterfaceAlert(const std::string&,int64_t);
};
'''+ '\n'.join(generated) + r'''
int main() {
 using namespace android::net::royd;
 for (bool active : {false,true}) for (const auto& iface : {"eth0","eth1","bad/name"}) {
  gate=active;sets=reads=removes=0;result=-EIO;BandwidthController controller;int64_t bytes=0;
  const bool selected=active && std::string(iface)=="eth0";
  assert(controller.setInterfaceQuota(iface,123)==(selected ? -EIO : 77));
  assert(controller.getInterfaceQuota(iface,&bytes)==(selected ? -EIO : 77));
  assert(controller.removeInterfaceQuota(iface)==(selected ? -EIO : 77));
  assert(controller.setInterfaceAlert(iface,10)==(selected ? -EIO : 77));
  assert(controller.legacy==(selected ? 0 : 4));
  assert(sets==int(selected) && reads==2*int(selected) && removes==int(selected));
 }
 gate=true;result=0;sets=removes=0;BandwidthController controller;int64_t bytes=0;
 assert(controller.setInterfaceAlert("eth0",0)==-ERANGE);
 assert(controller.setInterfaceAlert("eth0",10)==-EOPNOTSUPP);
 hasQuota=false;assert(controller.setInterfaceAlert("eth0",10)==-ENOENT);hasQuota=true;
 assert(controller.setInterfaceQuota("eth0",-1)==0 && removes==1 && !sets);
 assert(controller.setInterfaceQuota("eth0",0)==0 && sets==1 && request==0);
 assert(controller.setInterfaceQuota("eth0",-2)==0 && sets==2 && request==-2);
 assert(controller.getInterfaceQuota("eth0",&bytes)==0 && bytes==5 && !controller.legacy);
}
'''
(output/'controller.cpp').write_text(program)
subprocess.run(['c++','-std=c++17','-O2','-Wall','-Wextra','-Werror',str(output/'controller.cpp'),'-o',str(output/'controller-test')],check=True)
subprocess.run([str(output/'controller-test')],check=True)
print('Actual quota controller gate, sentinel, error propagation and exact stock preservation passed')
