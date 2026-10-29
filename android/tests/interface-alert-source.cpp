#include "quota-mock.inc"
#include "RoydInterfaceAlertSource.h"
int main() {
    using namespace android::net::royd;
    reset();assert(initialiseQuota());
    InterfaceAlertSample sample;
    assert(readInterfaceAlert(sample) == -ENOENT);
    assert(setQuota(1000) == 0);usage = 777;
    assert(readInterfaceAlert(sample) == 0 && sample.admitted == 777);
    assert((sample.identity == std::array<uint32_t,6>{2,112,30,31,40,41}));
    assert(setQuota(500) == 0 && readInterfaceAlert(sample) == 0 && sample.admitted == 777);
    assert(removeQuota() == 0 && readInterfaceAlert(sample) == -ENOENT);
    assert(setQuota(1000) == 0 && readInterfaceAlert(sample) == 0 && sample.admitted == 777);
    for (int failure : {1,2,3,4,5,6,7,8,9,10,13,14,16,18,19}) {
        fault = failure;
        assert(readInterfaceAlert(sample) == -EIO);
    }
    fault = 0;saved.generation = 0;assert(readInterfaceAlert(sample) == -EIO);
    saved.generation = 1;saved.remaining = 1001;assert(readInterfaceAlert(sample) == -EIO);
    puts("Actual interface alert source, absence, preserved usage and syscall faults passed");
}
