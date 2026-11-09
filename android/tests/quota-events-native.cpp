#include <cassert>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>
#include "RoydQuotaEvents.h"
using namespace android::net::royd;
using namespace std::chrono_literals;
template<class F> void until(F fn) {
    const auto end=std::chrono::steady_clock::now()+2s;
    while(!fn()) { assert(std::chrono::steady_clock::now()<end);std::this_thread::sleep_for(1ms); }
}
struct Backend {
    std::mutex lock;
    QuotaEventSample sample;
    int readError=0,setError=0,removeError=0,reads=0,writes=0;
    uint64_t next=1;
    bool fixed=false;
    Backend() { sample.identity={2,10,11,12,20,21,22,23}; }
    int read(QuotaEventSample& value) { std::lock_guard guard(lock);value=sample;++reads;return readError; }
    int set(int64_t bytes,uint64_t& generation) {
        std::lock_guard guard(lock);if(setError)return setError;
        ++writes;sample.present=true;sample.limit=sample.remaining=bytes;sample.generation=next;
        generation=next;if(!fixed)++next;return 0;
    }
    int remove() {
        std::lock_guard guard(lock);if(removeError)return removeError;
        if(!sample.present)return -ENODEV;
        sample.present=false;sample.generation=sample.limit=sample.remaining=0;return 0;
    }
    template<class F> void change(F fn) { std::lock_guard guard(lock);fn(*this); }
    int count() { std::lock_guard guard(lock);return reads; }
    QuotaEventSample get() { std::lock_guard guard(lock);return sample; }
};
struct StartGate {
    static StartGate* current;
    std::mutex lock;std::condition_variable changed;bool released=false;
    void*(*work)(void*)=nullptr;void* argument=nullptr;
    static void* run(void* data) {
        auto* self=static_cast<StartGate*>(data);
        { std::unique_lock guard(self->lock);self->changed.wait(guard,[&]{return self->released;}); }
        return self->work(self->argument);
    }
    static int start(pthread_t* thread,const pthread_attr_t* attr,void*(*work)(void*),void* arg) {
        current->work=work;current->argument=arg;return pthread_create(thread,attr,run,current);
    }
    void release() { std::lock_guard guard(lock);released=true;changed.notify_all(); }
};
StartGate* StartGate::current=nullptr;
int failStart(pthread_t*,const pthread_attr_t*,void*(*)(void*),void*) { return EAGAIN; }
#define READ(b) [&](QuotaEventSample& s){return (b).read(s);}
#define SET(b) [&](int64_t bytes,uint64_t& g){return (b).set(bytes,g);}
#define REMOVE(b) [&]{return (b).remove();}
int main() {
    {
        Backend b;QuotaEvents q(READ(b),SET(b),REMOVE(b),[](uint64_t){assert(false);return false;},2ms,failStart);
        assert(q.set(0)==-ERANGE&&q.set(-1)==-ERANGE&&b.count()==0);
        assert(q.set(100)==-EAGAIN&&!q.status().started&&!b.get().present&&b.writes==0);
        b.change([](auto& v){v.readError=-EIO;});assert(q.set(100)==-EIO&&!b.get().present);
    }
    for(unsigned mutation=0;mutation<6;++mutation) {
        Backend b;
        b.change([&](auto& v){
            switch(mutation) {
                case 0:v.sample.identity[0]=1;break;
                case 1:v.sample.identity[2]=v.sample.identity[1];break;
                case 2:v.sample.identity[7]=v.sample.identity[4];break;
                case 3:v.sample.present=true;break;
                case 4:v.sample.generation=1;break;
                case 5:v.sample.identity[1]=0;break;
            }
        });
        QuotaEvents q(READ(b),SET(b),REMOVE(b),[](uint64_t){assert(false);return false;});
        assert(q.set(100)==-ENODATA&&!q.status().started&&b.writes==0);
    }
    {
        Backend b;std::atomic<int> delivered=0;
        QuotaEvents q(READ(b),SET(b),REMOVE(b),[&](uint64_t gen){assert(gen==1);++delivered;return true;},2ms);
        assert(q.set(100)==0);const auto reads=b.count();until([&]{return b.count()>reads+2;});
        assert(delivered==0&&q.status().armed);
        b.change([](auto& v){v.sample.remaining=1;});const auto before=b.count();until([&]{return b.count()>before+1;});assert(delivered==0);
        b.change([](auto& v){v.sample.remaining=0;});until([&]{return delivered==1;});
        assert(!q.status().armed&&q.status().committed==1&&!q.status().error);
        std::this_thread::sleep_for(10ms);assert(delivered==1);
    }
    {
        Backend b;std::atomic<int> delivered=0;StartGate gate;StartGate::current=&gate;
        QuotaEvents q(READ(b),SET(b),REMOVE(b),[&](uint64_t){++delivered;return true;},2ms,StartGate::start);
        assert(q.set(100)==0);b.change([](auto& v){v.sample.remaining=0;});
        assert(q.set(200)==0);gate.release();const int reads=b.count();until([&]{return b.count()>reads+2;});
        assert(delivered==0&&q.status().generation==2&&q.status().bytes==200);
    }
    {
        Backend b;std::atomic<int> delivered=0;StartGate gate;StartGate::current=&gate;
        QuotaEvents q(READ(b),SET(b),REMOVE(b),[&](uint64_t){++delivered;return true;},2ms,StartGate::start);
        assert(q.set(100)==0);b.change([](auto& v){v.sample.remaining=0;});assert(q.remove()==0);
        gate.release();assert(!q.status().armed&&!q.status().bytes&&!b.get().present);
        std::this_thread::sleep_for(10ms);assert(delivered==0);
    }
    for(bool removal:{false,true}) {
        Backend b;std::atomic<int> delivered=0;StartGate gate;StartGate::current=&gate;
        QuotaEvents q(READ(b),SET(b),REMOVE(b),[&](uint64_t gen){assert(gen==1);++delivered;return true;},2ms,StartGate::start);
        assert(q.set(100)==0);
        b.change([](auto& v){v.setError=-ENOMEM;v.removeError=-EBUSY;});
        assert((removal?q.remove():q.set(50))==(removal?-EBUSY:-ENOMEM));
        assert(q.status().armed&&q.status().generation==1&&q.status().bytes==100&&b.get().limit==100);
        b.change([](auto& v){v.setError=v.removeError=0;v.sample.remaining=0;});
        gate.release();until([&]{return delivered==1;});
    }
    for(unsigned mutation=0;mutation<5;++mutation) {
        Backend b;std::atomic<int> delivered=0;StartGate gate;StartGate::current=&gate;
        QuotaEvents q(READ(b),SET(b),REMOVE(b),[&](uint64_t){++delivered;return true;},2ms,StartGate::start);
        assert(q.set(100)==0);
        b.change([&](auto& v){
            switch(mutation) {
                case 0:v.readError=-EIO;break;
                case 1:v.sample.identity[1]=90;break;
                case 2:++v.sample.generation;break;
                case 3:v.sample.present=false;v.sample.generation=v.sample.limit=v.sample.remaining=0;break;
                case 4:v.sample.remaining=101;break;
            }
        });
        gate.release();until([&]{return q.status().error!=0;});
        assert(delivered==0&&!q.status().armed&&q.set(200)==-q.status().error);
    }
    {
        Backend b;std::atomic<int> delivered=0;
        QuotaEvents q(READ(b),SET(b),REMOVE(b),[&](uint64_t){++delivered;return true;},2ms);
        assert(q.set(200)==0);b.change([](auto& v){v.sample.remaining=100;});
        const auto reads=b.count();until([&]{return b.count()>reads+1;});
        b.change([](auto& v){v.sample.remaining=150;});until([&]{return q.status().error!=0;});
        assert(q.status().error==ESTALE&&delivered==0);
    }
    {
        Backend b;std::atomic<int> delivered=0;
        QuotaEvents q(READ(b),SET(b),REMOVE(b),[&](uint64_t){++delivered;return false;},2ms);
        assert(q.set(100)==0);b.change([](auto& v){v.sample.remaining=0;});
        until([&]{return q.status().error!=0;});assert(q.status().error==EIO&&delivered==1);
    }
    {
        Backend b;b.fixed=true;b.next=42;
        std::mutex lock;std::condition_variable changed;bool entered=false,release=false;
        std::atomic<int> delivered=0;
        QuotaEvents q(READ(b),SET(b),REMOVE(b),[&](uint64_t gen){
            assert(gen==42);const int number=++delivered;
            if(number==1) {std::unique_lock guard(lock);entered=true;changed.notify_all();changed.wait(guard,[&]{return release;});return false;}
            return true;
        },2ms);
        assert(q.set(100)==0);b.change([](auto& v){v.sample.remaining=0;});
        {std::unique_lock guard(lock);assert(changed.wait_for(guard,2s,[&]{return entered;}));}
        assert(q.remove()==0&&q.set(200)==0); // Same backend generation, fresh lifecycle epoch.
        const auto reads=b.count();{std::lock_guard guard(lock);release=true;changed.notify_all();}
        until([&]{return b.count()>reads+1;});assert(q.status().error==0&&q.status().armed);
        b.change([](auto& v){v.sample.remaining=0;});until([&]{return delivered==2;});
        assert(q.status().committed==2&&!q.status().error);
    }
    {
        Backend b;QuotaEvents* live=nullptr;std::atomic<int> delivered=0;
        QuotaEvents q(READ(b),SET(b),REMOVE(b),[&](uint64_t){
            assert(live->status().committed==1);assert(live->set(300)==0);++delivered;return true;
        },2ms);live=&q;
        assert(q.set(100)==0);b.change([](auto& v){v.sample.remaining=0;});until([&]{return delivered==1;});
        assert(q.status().bytes==300&&q.status().armed&&!q.status().error);
    }
}
