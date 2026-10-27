#include <assert.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

static int contention;
static unsigned attempts;
static uint64_t compare(uint64_t* address, uint64_t old, uint64_t next) {
    if (contention) {
        attempts++;
        return old ? old - 1 : 10000;
    }
    __atomic_compare_exchange_n(address, &old, next, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return old;
}
#undef __always_inline
#define __always_inline
#define __sync_val_compare_and_swap compare
#include "royd_quota.h"

static struct RoydQuota shared;
static unsigned admitted;
static void* worker(void* ignored) {
    (void)ignored;
    for (unsigned n = 0; n < 5000; ++n) {
        int result = royd_quota_take(&shared, 20);
        assert(result >= -2 && result != -1);
        if (result == 1) __sync_fetch_and_add(&admitted, 1);
    }
    return NULL;
}
int main(void) {
    unsigned cases = 0;
    for (uint64_t amount = 1; amount <= 1000; ++amount) {
        for (uint64_t cost = 1; cost < 100; ++cost) {
            struct RoydQuota value = {amount, amount, 1};
            uint64_t accepted = 0;
            while (royd_quota_take(&value, cost) == 1) accepted += cost;
            assert(value.remaining == 0 && accepted <= amount && amount - accepted < cost);
            assert(value.limit == amount && value.generation == 1);
            assert(royd_quota_take(&value, 1) == 0); cases++;
        }
    }
    struct RoydQuota value = {INT64_MAX, INT64_MAX, 1};
    assert(royd_quota_take(&value, INT64_MAX) == 1 && !value.remaining);
    value = (struct RoydQuota){100,100,1};
    assert(royd_quota_take(&value,0) == -1 && value.remaining == 100);
    assert(royd_quota_take(&value,UINT64_MAX) == -1 && value.remaining == 100);
    value.generation = 0;assert(royd_quota_take(&value,1) == -1);
    value.generation = 1;value.limit = 0;assert(royd_quota_take(&value,1) == -1);
    value.limit = UINT64_MAX;assert(royd_quota_take(&value,1) == -1);
    value.limit = 99;assert(royd_quota_take(&value,1) == -1);
    contention = 1;attempts = 0;value = (struct RoydQuota){10000,10000,1};
    assert(royd_quota_take(&value,1) == -2 && attempts == 65 && value.remaining == 10000);
    contention = 0;
    // A packet holding an RCU-retired element can debit only that old allocation.
    struct RoydQuota old = {100,100,1}, replacement = {200,200,2};
    assert(royd_quota_take(&old,100) == 1 && replacement.remaining == 200);
    assert(royd_quota_take(&replacement,200) == 1 && !old.remaining);
    shared = (struct RoydQuota){200000,200000,3};
    pthread_t threads[8];
    for (unsigned n = 0; n < 8; ++n) assert(!pthread_create(&threads[n],NULL,worker,NULL));
    for (unsigned n = 0; n < 8; ++n) assert(!pthread_join(threads[n],NULL));
    assert(admitted == 10000 && !shared.remaining && shared.limit == 200000);
    printf("Quota boundaries, overflow, bounded contention and shared concurrency passed: %u boundary cases\n",cases);
}
