#include <ifaddrs.h>
#include "accounting-mock.inc"
static int address_mode, frees;
static struct ifaddrs address_list[2];
static sockaddr ip_address;
static int fake_addresses(struct ifaddrs** value) {
    if (address_mode == 1) { errno = EIO; return -1; }
    address_list[0] = {}; address_list[1] = {}; ip_address = {};
    ip_address.sa_family = AF_INET;
    address_list[0].ifa_name = const_cast<char*>("eth0");
    address_list[0].ifa_flags = IFF_UP;
    address_list[0].ifa_addr = &ip_address;
    if (address_mode >= 2) {
        address_list[0].ifa_next = &address_list[1];
        address_list[1].ifa_name = const_cast<char*>("tun0");
        address_list[1].ifa_flags = address_mode == 2 ? IFF_UP : address_mode == 3 ? 0 : IFF_UP|IFF_LOOPBACK;
        address_list[1].ifa_addr = &ip_address;
    }
    if (address_mode == 5) { address_list[1].ifa_name = nullptr; address_list[1].ifa_flags = IFF_UP; }
    *value = address_list;
    return 0;
}
static void fake_free(struct ifaddrs* value) { assert(value == address_list); frees++; }
#define getifaddrs fake_addresses
#define freeifaddrs fake_free
#include "RoydGlobalAlertSource.h"
#undef getifaddrs
#undef freeifaddrs
int main() {
    using namespace android::net::royd;
    for (int mode = 0; mode != 6; ++mode) {
        reset(); address_mode = mode;
        selected = iface; pins[0] = pins[1] = stats_present = true;
        stats_bytes = 12345;
        AlertSample sample;
        const int result = readGlobalAlert(sample);
        assert(result == (mode == 1 ? -EIO : mode == 2 || mode == 5 ? -EOPNOTSUPP : 0));
        if (!result) {
            assert(sample.ifindex == 2 && sample.map == 1101
                   && sample.ingress == 300 && sample.egress == 301);
            assert(sample.rx == 12345 && sample.tx == 0);
        }
        assert(creates == 0 && stats_writes == 0 && config_writes == 0);
    }
    address_mode = 0;
    for (int bad = 1; bad <= 16; ++bad) {
        if (bad >= 7 && bad <= 11) continue; // Installation-only failures.
        reset(); selected = iface; pins[0] = pins[1] = stats_present = true;
        failure = bad;
        AlertSample sample;
        assert((readGlobalAlert(sample) == 0) == (bad == 15));
        assert(creates == 0 && stats_writes == 0 && config_writes == 0);
    }
    reset(); selected = iface; pins[0] = pins[1] = stats_present = true;
    errors = 1;
    AlertSample sample;
    assert(readGlobalAlert(sample) == -ENODATA);
    assert(creates == 0 && stats_writes == 0 && config_writes == 0 && frees > 0);
    puts("Global alert source uses verified counters, rejects extra IP interfaces and propagates failures");
}
