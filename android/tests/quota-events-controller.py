"""Compile the real controller wiring and preserve every stock gated body."""
from pathlib import Path
import subprocess
import sys

root, output = map(Path, sys.argv[1:])
before = (output/'before-controller.cpp').read_text()
after = (output/'BandwidthController.cpp').read_text()


def block(text, marker):
    start = text.index(marker)
    start = text.rfind('\n',0,start)+1
    opening = text.index('{',start)
    depth = 1
    for end in range(opening+1,len(text)):
        depth += (text[end]=='{')-(text[end]=='}')
        if not depth:
            return text[start:end+1]
    raise AssertionError(marker)


names = ['setInterfaceQuota','getInterfaceQuota','removeInterfaceQuota']
methods = []
for name in names:
    old, new = [block(text,'BandwidthController::'+name+'(') for text in (before,after)]
    marker = '    if (android::net::royd::enabled() && iface == "eth0")'
    a,b = block(old,marker),block(new,marker)
    assert old.replace(a+'\n','',1)==new.replace(b+'\n','',1),name
    methods.append(new[:new.index('{')+1]+'\n'+b+'\n ++legacy;return 77;\n}')
for name in ['enableBandwidthControl','setInterfaceAlert','removeInterfaceAlert']:
    assert block(before,'BandwidthController::'+name+'(')==block(after,'BandwidthController::'+name+'(')
old,new = [block(text,'BandwidthController::BandwidthController(') for text in (before,after)]
assert old.replace(block(old,'    if (royd::enabled())')+'\n','',1)==new.replace(block(new,'    if (royd::enabled())')+'\n','',1)
constructor = new
dump = block(after,'BandwidthController::dumpRoydGlobalAlert(')
assert dump.replace(block(dump,'    if (mRoydQuotaEvents)')+'\n','',1)==block(before,'BandwidthController::dumpRoydGlobalAlert(')
program = r'''
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <inttypes.h>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#include "RoydGlobalAlert.h"
#include "RoydInterfaceAlert.h"
#include "RoydQuotaEvents.h"
std::atomic<int> infoLogs{0},errorLogs{0};
void countLog(std::atomic<int>& count,const char*,...){++count;}
#define ALOGI(...) countLog(infoLogs,__VA_ARGS__)
#define ALOGE(...) countLog(errorLogs,__VA_ARGS__)
struct Result { bool isOk() const {return true;} };
struct Listener {
 std::mutex lock;std::vector<std::pair<std::string,std::string>> seen;
 Result onQuotaLimitReached(const char* name,const char* iface) {
  std::lock_guard guard(lock);seen.emplace_back(name,iface);return {};
 }
 size_t count(){std::lock_guard guard(lock);return seen.size();}
};
auto listener=std::make_shared<Listener>();
struct Reporter {
 auto getNetdUnsolicitedEventListenerMap(){return std::vector<std::pair<std::shared_ptr<Listener>,int>>{{listener,0}};}
};
struct Controllers {Reporter eventReporter;};Controllers world;auto* gCtls=&world;
struct Entry {
 Entry function(const char*){return *this;}
 Entry args(const char*,const char*){return *this;}
 Entry withAutomaticDuration(){return *this;}
};
struct Log {Entry newEntry(){return {};}void log(Entry){}} gUnsolicitedLog;
namespace android::netdutils {struct DumpWriter {template<class... Args>void println(const char*,Args...) {}};}
namespace android::net::royd {
bool gate=true;std::mutex dataLock;QuotaEventSample sample;
int readError=0,writeError=0,removeError=0,writes=0,removes=0;uint64_t next=1;
struct QuotaValue {uint64_t remaining=0,limit=0,generation=0;};struct QuotaDrops {};
bool enabled(){return gate;}
int readGlobalAlert(AlertSample&){return -EOPNOTSUPP;}
int readInterfaceAlert(InterfaceAlertSample&){return -EOPNOTSUPP;}
int readQuotaEvent(QuotaEventSample& value){std::lock_guard guard(dataLock);value=sample;return readError;}
int setQuota(int64_t bytes,uint64_t* generation){
 std::lock_guard guard(dataLock);if(writeError)return writeError;
 assert(generation);++writes;sample.present=true;sample.limit=sample.remaining=bytes;sample.generation=next++;
 *generation=sample.generation;return 0;
}
int removeQuota(){
 std::lock_guard guard(dataLock);++removes;if(removeError)return removeError;
 if(!sample.present)return -ENODEV;
 sample.present=false;sample.limit=sample.remaining=sample.generation=0;return 0;
}
int readQuota(QuotaValue& value,QuotaDrops&,bool& present){
 std::lock_guard guard(dataLock);present=sample.present;
 value.remaining=sample.remaining;value.limit=sample.limit;value.generation=sample.generation;return readError;
}
}
class BandwidthController {
public:
 int legacy=0;
 std::unique_ptr<android::net::royd::GlobalAlert> mRoydGlobalAlert;
 std::unique_ptr<android::net::royd::QuotaEvents> mRoydQuotaEvents;
 std::unique_ptr<android::net::royd::InterfaceAlert> mRoydInterfaceAlert;
 BandwidthController();
 void dumpRoydGlobalAlert(android::netdutils::DumpWriter&);
 int setInterfaceQuota(const std::string&,int64_t);
 int getInterfaceQuota(const std::string&,int64_t*);
 int removeInterfaceQuota(const std::string&);
};
''' + constructor+'\n'+dump+'\n'+'\n'.join(methods) + r'''
int main() {
 using namespace android::net::royd;using namespace std::chrono_literals;
 sample.identity={2,10,11,12,20,21,22,23};
 {
  gate=false;BandwidthController c;int64_t bytes=0;
  assert(!c.mRoydQuotaEvents&&c.setInterfaceQuota("eth0",100)==77);
  assert(c.getInterfaceQuota("eth0",&bytes)==77&&c.removeInterfaceQuota("eth0")==77);
  assert(c.legacy==3&&!writes&&!removes&&!infoLogs);
 }
 gate=true;
 {
  BandwidthController c;int64_t bytes=0;
  assert(c.setInterfaceQuota("eth1",100)==77&&c.legacy==1&&!writes&&!infoLogs);
  assert(c.setInterfaceQuota("eth0",0)==-ERANGE&&!writes&&!infoLogs);
  writeError=-ENOMEM;assert(c.setInterfaceQuota("eth0",100)==-ENOMEM&&!writes&&!infoLogs);
  writeError=0;assert(c.setInterfaceQuota("eth0",100)==0&&writes==1&&infoLogs==1);
  assert(c.setInterfaceQuota("eth0",200)==0&&writes==2&&infoLogs==1);
  assert(c.getInterfaceQuota("eth0",&bytes)==0&&bytes==200);
  {std::lock_guard guard(dataLock);sample.remaining=0;}
  const auto deadline=std::chrono::steady_clock::now()+2s;
  while(listener->count()!=1){assert(std::chrono::steady_clock::now()<deadline);std::this_thread::sleep_for(1ms);}
  {std::lock_guard guard(listener->lock);assert((listener->seen[0]==std::pair<std::string,std::string>{"eth0","eth0"}));}
  assert(c.mRoydQuotaEvents->status().committed==1);
  removeError=-EBUSY;assert(c.removeInterfaceQuota("eth0")==-EBUSY&&c.mRoydQuotaEvents->status().bytes==200);
  removeError=0;assert(c.removeInterfaceQuota("eth0")==0&&!c.mRoydQuotaEvents->status().bytes);
  assert(c.getInterfaceQuota("eth0",&bytes)==-ENODEV);
  assert(c.setInterfaceQuota("eth0",100)==0&&infoLogs==1);
  assert(c.setInterfaceQuota("eth0",-1)==0&&!c.mRoydQuotaEvents->status().armed);
  assert(removes==3&&!errorLogs);
 }
}
'''
(output/'controller.cpp').write_text(program)
subprocess.run(['c++','-std=c++17','-O2','-Wall','-Wextra','-Werror','-fno-exceptions','-fno-rtti','-pthread',
                '-I'+str(output),str(output/'controller.cpp'),'-o',str(output/'controller')],check=True)
subprocess.run([str(output/'controller')],check=True,timeout=10)
print('Actual controller notification/removal wiring, successful-only marker and stock preservation passed')
