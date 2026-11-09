#include "quota-event-mock.inc"
#include "RoydQuotaEventSource.h"
int main() {
    using namespace android::net::royd;
    reset();assert(initialiseQuota());QuotaEventSample sample;
    assert(readQuotaEvent(sample)==0&&!sample.present&&!sample.generation&&!sample.limit&&!sample.remaining);
    assert((sample.identity==std::array<uint32_t,8>{2,110,111,113,30,31,40,41}));
    uint64_t generation=123;
    assert(setQuota(0,&generation)==-ERANGE&&generation==123);
    assert(setQuota(1000,&generation)==0&&generation==saved.generation&&generation>0);
    assert(readQuotaEvent(sample)==0&&sample.present&&sample.generation==generation&&sample.remaining==1000);
    const auto old=saved;fault=17;generation=999;
    assert(setQuota(500,&generation)==-ENOMEM&&generation==999&&!memcmp(&saved,&old,sizeof(old)));
    fault=0;saved.remaining=0;
    assert(readQuotaEvent(sample)==0&&sample.present&&!sample.remaining);
    for(int failure:{1,2,3,4,5,6,7,8,9,10,13,14,16,18,20,21,22,23,24}) {
        fault=failure;assert(readQuotaEvent(sample)==-EIO);
    }
    fault=0;saved.generation=0;assert(readQuotaEvent(sample)==-EIO);
    saved.generation=1;saved.limit=0;assert(readQuotaEvent(sample)==-EIO);
    saved.limit=1000;saved.remaining=1001;assert(readQuotaEvent(sample)==-EIO);
    saved.remaining=0;assert(removeQuota()==0&&readQuotaEvent(sample)==0&&!sample.present);
    assert(!sample.generation&&!sample.limit&&!sample.remaining);
    puts("Actual quota-event source identity, absence, faults and post-write generation passed");
}
