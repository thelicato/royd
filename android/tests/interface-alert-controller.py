"""Compile the actual appended controller gates and prove stock body preservation."""
from pathlib import Path
import subprocess
import sys

root, output = map(Path, sys.argv[1:])
source = output/'applied'
server = source/'system/netd/server'
server.mkdir(parents=True)
fixtures = root/'android/tests/fixtures/android15'
for suffix in ['cpp', 'h']:
    (server/('BandwidthController.'+suffix)).write_bytes((fixtures/('global-alert-bandwidth.'+suffix)).read_bytes())
for number in ['0070', '0071', '0072', '0075']:
    patch = next((root/'android/patches/android-15.0.0_r36').glob(number+'-*.patch'))
    parts = patch.read_text().split('diff --git ')
    names = ['BandwidthController.cpp', 'BandwidthController.h', 'RoydInterfaceQuota.h',
             'RoydInterfaceAlert.h', 'RoydInterfaceAlertSource.h']
    selected = ''.join('diff --git '+p for p in parts[1:]
                       if any(p.startswith('a/system/netd/server/'+n+' ') for n in names))
    subprocess.run(['patch', '-s', '--fuzz=0', '-p1', '-d', str(source)],
                   input=selected, text=True, check=True)
    if number == '0072': before = (server/'BandwidthController.cpp').read_text()
after = (server/'BandwidthController.cpp').read_text()


def block(text, start):
    opening = text.index('{', start)
    depth = 1
    for i in range(opening+1, len(text)):
        depth += (text[i] == '{') - (text[i] == '}')
        if not depth: return text[start:i+1]
    raise AssertionError('incomplete method')


generated = []
for name in ['setInterfaceQuota', 'getInterfaceQuota', 'removeInterfaceQuota',
             'setInterfaceAlert', 'removeInterfaceAlert']:
    methods = []
    gates = []
    for text in [before, after]:
        method = block(text, text.index('int BandwidthController::'+name+'('))
        marker = '    if (android::net::royd::enabled() && iface == "eth0")'
        gate = block(method, method.index(marker)) if marker in method else ''
        methods.append(method.replace(gate+'\n', '', 1) if gate else method)
        gates.append(gate)
    assert methods[0] == methods[1], 'stock method changed: '+name
    generated.append(method[:method.index('{')+1]+'\n'+gates[1]+'\n    ++legacy;return 77;\n}')

program = r'''
#include <cassert>
#include <cstdint>
#include <cerrno>
#include <memory>
#include <mutex>
#include <string>
#define ALOGI(...) ((void)0)
namespace android::net::royd {
bool gate;int result, sets, reads;int64_t request;
struct QuotaValue { uint64_t remaining=5,limit=10,generation=1; };
struct QuotaDrops {};
bool enabled() { return gate; }
int setQuota(int64_t bytes) { ++sets;request=bytes;return result; }
int readQuota(QuotaValue&,QuotaDrops&,bool& present) { ++reads;present=true;return result; }
}
struct MockAlert {
 int result=0, arms=0, cancels=0, removes=0;int64_t bytes=0;
 int arm(int64_t value) { ++arms;bytes=value;return result; }
 int cancel() { ++cancels;return result; }
 int removeQuota() { ++removes;return result; }
};
class BandwidthController {
public:
 std::unique_ptr<MockAlert> mRoydInterfaceAlert=std::make_unique<MockAlert>();
 int legacy=0;
 int setInterfaceQuota(const std::string&,int64_t);
 int getInterfaceQuota(const std::string&,int64_t*);
 int removeInterfaceQuota(const std::string&);
 int setInterfaceAlert(const std::string&,int64_t);
 int removeInterfaceAlert(const std::string&);
};
'''+ '\n'.join(generated) + r'''
int main() {
 using namespace android::net::royd;
 for (bool active : {false,true}) for (const auto& iface : {"eth0","eth1","bad/name"}) {
  gate=active;sets=reads=0;result=-EIO;BandwidthController controller;int64_t bytes=0;
  auto& alert=*controller.mRoydInterfaceAlert;alert.result=-EACCES;
  bool selected=active && std::string(iface)=="eth0";
  assert(controller.setInterfaceQuota(iface,123)==(selected ? -EIO : 77));
  assert(controller.getInterfaceQuota(iface,&bytes)==(selected ? -EIO : 77));
  assert(controller.removeInterfaceQuota(iface)==(selected ? -EACCES : 77));
  assert(controller.setInterfaceAlert(iface,456)==(selected ? -EACCES : 77));
  assert(controller.removeInterfaceAlert(iface)==(selected ? -EACCES : 77));
  assert(controller.legacy==(selected ? 0 : 5));
  assert(sets==int(selected) && reads==int(selected));
  assert(alert.arms==int(selected) && alert.cancels==int(selected) && alert.removes==int(selected));
 }
 gate=true;result=0;BandwidthController c;auto& a=*c.mRoydInterfaceAlert;
 assert(c.setInterfaceQuota("eth0",-1)==0 && a.removes==1);
 assert(c.setInterfaceAlert("eth0",500)==0 && a.bytes==500);
 assert(c.setInterfaceAlert("eth0",100)==0 && a.bytes==100 && a.arms==2);
 assert(c.removeInterfaceAlert("eth0")==0 && a.cancels==1);
 assert(c.removeInterfaceQuota("eth0")==0 && a.removes==2 && !c.legacy);
}
'''
(output/'controller.cpp').write_text(program)
subprocess.run(['c++', '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror', '-pthread',
                str(output/'controller.cpp'), '-o', str(output/'controller')], check=True)
subprocess.run([str(output/'controller')], check=True)
# Constructor ownership and exact public Binder checks remain outside this patch.
patch = next((root/'android/patches/android-15.0.0_r36').glob('0075-*.patch')).read_text()
assert 'NetdNativeService' not in patch
assert 'onQuotaLimitReached("eth0Alert", "eth0")' in after
assert 'std::make_unique<royd::InterfaceAlert>' in after
print('Actual interface alert controller errors, sentinel, identity and stock preservation passed')
