"""Execute the patched controller entry points with explicit backend/legacy mocks."""
from pathlib import Path
import subprocess
import sys
root, output = map(Path, sys.argv[1:])
source = output/'controller'
(source/'system/netd/server').mkdir(parents=True)
fixtures=root/'android/tests/fixtures/android15'
for origin, target in [('global-alert-bandwidth.cpp', 'BandwidthController.cpp'),
                       ('global-alert-bandwidth.h', 'BandwidthController.h')]:
    (source/'system/netd/server'/target).write_bytes((fixtures/origin).read_bytes())
patch=(root/'android/patches/android-15.0.0_r36/0070-netd-sample-container-global-byte-alert.patch').read_text()
parts=patch.split('diff --git ')
selected=''.join('diff --git '+p for p in parts[1:] if p.startswith('a/system/netd/server/BandwidthController.'))
subprocess.run(['patch','-s','--fuzz=0','-p1','-d',str(source)],input=selected,text=True,check=True)
text=(source/'system/netd/server/BandwidthController.cpp').read_text()
def method(name):
    start=text.index('int BandwidthController::'+name+'(')
    opening=text.index('{',start)
    depth=1
    for i in range(opening+1,len(text)):
        depth += (text[i]=='{')-(text[i]=='}')
        if depth == 0: return text[start:i+1]
    raise AssertionError('incomplete method')
program=r'''
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <inttypes.h>
#include <memory>
#include <mutex>
#define ALOGE(...) ((void)0)
#define ALOGI(...) ((void)0)
static constexpr const char* ALERT_GLOBAL_NAME="globalAlert";
struct MockAlert {
 int result=0, cancels=0, arms=0; int64_t last=0;
 int arm(int64_t bytes) { ++arms; last=bytes; return result; }
 int cancel() { ++cancels; return result; }
};
class BandwidthController {
 public:
 std::unique_ptr<MockAlert> mRoydGlobalAlert;
 int64_t mGlobalAlertBytes=0;
 int legacy=0, legacyResult=0;
 enum { IptOpInsert, IptOpDelete };
 int updateQuota(const char*,int64_t) { ++legacy; return legacyResult; }
 int runIptablesAlertCmd(int,const char*,int64_t) { ++legacy; return legacyResult; }
 int setGlobalAlert(int64_t);
 int removeGlobalAlert();
};
'''+method('setGlobalAlert')+'\n'+method('removeGlobalAlert')+r'''
int main() {
 BandwidthController stock;
 assert(stock.setGlobalAlert(0)==-ERANGE && stock.legacy==0);
 assert(stock.removeGlobalAlert()==-1);
 stock.legacyResult=-EACCES;
 assert(stock.setGlobalAlert(20)==-EREMOTEIO && stock.mGlobalAlertBytes==20);
 assert(stock.setGlobalAlert(30)==-EACCES && stock.mGlobalAlertBytes==30);
 assert(stock.removeGlobalAlert()==-EACCES && stock.mGlobalAlertBytes==0);
 // Preserve the stock negative-value branch outside the explicit container gate.
 stock.legacyResult=0;
 assert(stock.setGlobalAlert(-1)==0 && stock.mGlobalAlertBytes==-1);
 BandwidthController owned;
 owned.mRoydGlobalAlert=std::make_unique<MockAlert>();
 auto& backend=*owned.mRoydGlobalAlert;
 backend.result=-EIO;
 assert(owned.setGlobalAlert(40)==-EIO && owned.mGlobalAlertBytes==0);
 assert(backend.arms==1 && backend.last==40 && owned.legacy==0);
 backend.result=0;
 assert(owned.setGlobalAlert(50)==0 && backend.last==50);
 assert(owned.mGlobalAlertBytes==0 && owned.legacy==0);
 assert(owned.removeGlobalAlert()==0 && backend.cancels==1 && owned.legacy==0);
 backend.result=-ENOENT;
 assert(owned.removeGlobalAlert()==-1 && backend.cancels==2);
}
'''
(output/'entry-points.cpp').write_text(program)
