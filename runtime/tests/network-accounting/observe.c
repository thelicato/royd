#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/bpf.h>
#include <net/if.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>
#include "observe.h"
// Stable libbpf object-loader API. TCX attachment uses the kernel UAPI directly.
struct bpf_object; struct bpf_program; struct bpf_map;
extern struct bpf_object* bpf_object__open_file(const char*, const void*);
extern int bpf_object__load(struct bpf_object*);
extern void bpf_object__close(struct bpf_object*);
extern struct bpf_program* bpf_object__find_program_by_name(const struct bpf_object*, const char*);
extern int bpf_program__fd(const struct bpf_program*);
extern int bpf_program__set_expected_attach_type(struct bpf_program*, enum bpf_attach_type);
extern struct bpf_map* bpf_object__find_map_by_name(const struct bpf_object*, const char*);
extern int bpf_map__fd(const struct bpf_map*);
struct counters { uint64_t rx_packets, rx_bytes, tx_packets, tx_bytes; };
static int call(enum bpf_cmd cmd, union bpf_attr* attr) { return syscall(__NR_bpf, cmd, attr, sizeof(*attr)); }
static void check(int good, const char* what) { if (!good) { perror(what); exit(1); } }
static int object(const char* root, const char* name, int flags) {
    char path[512]; check(snprintf(path, sizeof(path), "%s/%s", root, name) < (int)sizeof(path), "path length");
    union bpf_attr a = {}; a.pathname = (uintptr_t)path; a.file_flags = flags;
    int fd = call(BPF_OBJ_GET, &a); check(fd >= 0, path); return fd;
}
static void info(int fd, void* output, unsigned size, unsigned minimum) {
    union bpf_attr a = {}; a.info.bpf_fd = fd; a.info.info = (uintptr_t)output; a.info.info_len = size;
    check(!call(BPF_OBJ_GET_INFO_BY_FD, &a) && a.info.info_len >= minimum, "object information");
}
static void read_map(int fd, uint32_t key, void* value) {
    union bpf_attr a = {}; a.map_fd = fd; a.key = (uintptr_t)&key; a.value = (uintptr_t)value;
    check(!call(BPF_MAP_LOOKUP_ELEM, &a), "map lookup");
}
static void layout(int fd, unsigned type, unsigned size) {
    struct bpf_map_info i = {}; info(fd, &i, sizeof(i), offsetof(struct bpf_map_info,max_entries)+sizeof(i.max_entries));
    check(i.type == type && i.key_size == 4 && i.value_size == size && i.max_entries, "map layout");
}
static void query(unsigned index, unsigned direction, unsigned link, unsigned program,
                  unsigned* ids, unsigned* count) {
    unsigned programs[64] = {}; *count = 64;
    union bpf_attr a = {}; a.query.target_ifindex = index; a.query.attach_type = direction;
    a.query.prog_cnt = 64; a.query.prog_ids = (uintptr_t)programs; a.query.link_ids = (uintptr_t)ids;
    check(!call(BPF_PROG_QUERY, &a) && a.query.prog_cnt <= 64, "TCX query"); *count = a.query.prog_cnt;
    int found = 0;
    for (unsigned n = 0; n < *count; n++) if (ids[n] == link && programs[n] == program) found++;
    check(found == 1, "production link absent from current namespace");
}
static void stats_json(FILE* f, const struct observe_stats* s) {
    fprintf(f, "{\"skbs\":%llu,\"segments\":%llu,\"gso_skbs\":%llu,\"raw_bytes\":%llu,\"other_ip_skbs\":%llu,\"errors\":%llu}",
        s->skbs,s->segments,s->gso_skbs,s->raw_bytes,s->other_ip_skbs,s->errors);
}
static void tcp_json(FILE* f, int records, unsigned direction, uint64_t count) {
    check(count <= TCP_RECORD_LIMIT, "TCP header ledger overflow");
    fprintf(f,"[");
    for (uint64_t n = 0; n < count; n++) {
        struct tcp_record r; read_map(records,direction * TCP_RECORD_LIMIT + n,&r);
        fprintf(f,"%s{\"skb_len\":%u,\"ip_len\":%u,\"ip_total\":%u,\"tcp_len\":%u,\"sequence\":%u,\"gso_size\":%u,\"gso_segs\":%u,\"flags\":%u,\"source\":%u,\"destination\":%u,\"source_port\":%u,\"destination_port\":%u}",
            n ? "," : "",r.skb_len,r.ip_len,r.ip_total,r.tcp_len,r.sequence,r.gso_size,r.gso_segs,r.flags,r.source,r.destination,r.source_port,r.destination_port);
    }
    fprintf(f,"]");
}
static void snapshot(FILE* f, unsigned index, int stats, int selector, int errors,
                     struct bpf_link_info* links, int observed, int tcp_counts, int tcp_records) {
    struct counters c; struct observe_stats before[2] = {}, after[2] = {};
    unsigned state[2], error; uint64_t tcp_before[2] = {}, tcp_after[2] = {};
    int stable = 0;
    for (unsigned attempt = 0; attempt < 50; attempt++) {
        if (observed >= 0) for (unsigned n = 0; n < 2; n++) read_map(observed,n,&before[n]);
        if (tcp_counts >= 0) for (unsigned n = 0; n < 2; n++) read_map(tcp_counts,n,&tcp_before[n]);
        read_map(stats,index,&c);
        if (observed >= 0) for (unsigned n = 0; n < 2; n++) read_map(observed,n,&after[n]);
        if (tcp_counts >= 0) for (unsigned n = 0; n < 2; n++) read_map(tcp_counts,n,&tcp_after[n]);
        if (!memcmp(before,after,sizeof(before)) && !memcmp(tcp_before,tcp_after,sizeof(tcp_before))) { stable = 1; break; }
        usleep(1000);
    }
    check(stable, "observer snapshot remained busy");
    read_map(selector,0,state); read_map(errors,0,&error);
    check(state[0] == index && state[1] == 0 && error == 0, "production selector/error state");
    struct bpf_map_info mi = {}; info(stats,&mi,sizeof(mi),offsetof(struct bpf_map_info,max_entries)+sizeof(mi.max_entries));
    fprintf(f,"{\"ifindex\":%u,\"map_id\":%u,\"counters\":[%"PRIu64",%"PRIu64",%"PRIu64",%"PRIu64"],\"production_links\":[%u,%u],\"query\":[",index,mi.id,c.rx_packets,c.rx_bytes,c.tx_packets,c.tx_bytes,links[0].id,links[1].id);
    for (unsigned n = 0; n < 2; n++) {
        unsigned ids[64] = {}, count; query(index,n ? BPF_TCX_EGRESS : BPF_TCX_INGRESS,links[n].id,links[n].prog_id,ids,&count);
        fprintf(f,"%s[",n ? "," : ""); for (unsigned i=0;i<count;i++) fprintf(f,"%s%u",i ? "," : "",ids[i]); fprintf(f,"]");
    }
    fprintf(f,"],\"observed\":["); stats_json(f,&after[0]);fprintf(f,",");stats_json(f,&after[1]);fprintf(f,"],\"tcp\":[");
    tcp_json(f,tcp_records,0,tcp_after[0]);fprintf(f,",");tcp_json(f,tcp_records,1,tcp_after[1]);fprintf(f,"]}\n");
    check(!ferror(f),"snapshot write");
}
static void publish(const char* dir, const char* name, unsigned index, int stats, int selector,
                    int errors, struct bpf_link_info* links, int observed, int tcp_counts, int tcp_records) {
    char temporary[512], final[512];
    check(strlen(name) > 0 && strlen(name) < 64 && strspn(name,"abcdefghijklmnopqrstuvwxyz0123456789-") == strlen(name),"snapshot name");
    check(snprintf(temporary,sizeof(temporary),"%s/%s.tmp",dir,name)<(int)sizeof(temporary),"snapshot path");
    check(snprintf(final,sizeof(final),"%s/%s.json",dir,name)<(int)sizeof(final),"snapshot path");
    int fd=open(temporary,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);check(fd>=0,"new snapshot");
    FILE* f=fdopen(fd,"w");check(f!=NULL,"snapshot stream");snapshot(f,index,stats,selector,errors,links,observed,tcp_counts,tcp_records);
    check(!fclose(f),"snapshot close");check(!link(temporary,final),"non-overwriting publication");check(!unlink(temporary),"temporary cleanup");
}
int main(int argc, char** argv) {
    // inspect ROOT EXPECTED_NETNS, or observe ROOT EXPECTED_NETNS OBJECT OUTPUT UDP_PORT [TCP_PORT].
    check((argc==4 && !strcmp(argv[1],"inspect")) || ((argc==7 || argc==8) && !strcmp(argv[1],"observe")),"arguments");
    char ns[128]={}; ssize_t size=readlink("/proc/self/ns/net",ns,sizeof(ns)-1);
    check(size>0 && !strcmp(ns,argv[3]),"owned network namespace");
    unsigned index=if_nametoindex("eth0");check(index>1,"eth0");
    int stats=object(argv[2],"map_netd_iface_stats_map",BPF_F_RDONLY);
    int selector=object(argv[2],"map_netd_royd_iface_accounting_map",BPF_F_RDONLY);
    int errors=object(argv[2],"map_netd_royd_iface_error_map",BPF_F_RDONLY);
    layout(stats,BPF_MAP_TYPE_HASH,sizeof(struct counters));layout(selector,BPF_MAP_TYPE_ARRAY,8);layout(errors,BPF_MAP_TYPE_ARRAY,4);
    struct bpf_link_info links[2] = {};
    for(unsigned n=0;n<2;n++) { int fd=object(argv[2],n ? "link_royd_iface_egress":"link_royd_iface_ingress",0);info(fd,&links[n],sizeof(links[n]),offsetof(struct bpf_link_info,tcx)+sizeof(links[n].tcx));close(fd);
        check(links[n].type==BPF_LINK_TYPE_TCX && links[n].tcx.ifindex==index && links[n].tcx.attach_type==(n ? BPF_TCX_EGRESS:BPF_TCX_INGRESS),"production link identity"); }
    if(argc==4) { snapshot(stdout,index,stats,selector,errors,links,-1,-1,-1);return 0; }
    char* end; unsigned long port=strtoul(argv[6],&end,10);check(*argv[6] && !*end && port>0 && port<=65535,"UDP port");
    unsigned long tcp_port=0;
    if(argc==8) { tcp_port=strtoul(argv[7],&end,10);check(*argv[7] && !*end && tcp_port>0 && tcp_port<=65535,"TCP port"); }
    struct bpf_object* obj=bpf_object__open_file(argv[4],NULL);check(obj!=NULL && (intptr_t)obj>0,"open observer");
    const char* names[]={"observe_ingress","observe_egress"}; struct bpf_program* programs[2];
    for(unsigned n=0;n<2;n++) { programs[n]=bpf_object__find_program_by_name(obj,names[n]);check(programs[n]!=NULL,"observer program");check(!bpf_program__set_expected_attach_type(programs[n],n ? BPF_TCX_EGRESS:BPF_TCX_INGRESS),"observer attach type"); }
    check(!bpf_object__load(obj),"load observer");
    int cfg=bpf_map__fd(bpf_object__find_map_by_name(obj,"observe_config"));
    int observed=bpf_map__fd(bpf_object__find_map_by_name(obj,"observe_records"));check(cfg>=0 && observed>=0,"observer maps");
    int tcp_counts=bpf_map__fd(bpf_object__find_map_by_name(obj,"tcp_counts"));
    int tcp_records=bpf_map__fd(bpf_object__find_map_by_name(obj,"tcp_records"));check(tcp_counts>=0 && tcp_records>=0,"TCP ledger maps");
    struct observe_config configuration={index,port,tcp_port};uint32_t zero=0;
    union bpf_attr a={};a.map_fd=cfg;a.key=(uintptr_t)&zero;a.value=(uintptr_t)&configuration;check(!call(BPF_MAP_UPDATE_ELEM,&a),"private observer configuration");
    int attached[2];
    for(unsigned n=0;n<2;n++) { a=(union bpf_attr){};a.link_create.prog_fd=bpf_program__fd(programs[n]);a.link_create.target_ifindex=index;a.link_create.attach_type=n ? BPF_TCX_EGRESS:BPF_TCX_INGRESS;
        a.link_create.flags=BPF_F_AFTER|BPF_F_LINK|BPF_F_ID;a.link_create.tcx.relative_id=links[n].id;
        attached[n]=call(BPF_LINK_CREATE,&a);check(attached[n]>=0,"attach after owned production link"); }
    publish(argv[5],"ready",index,stats,selector,errors,links,observed,tcp_counts,tcp_records);
    char stop[512], request[512];snprintf(stop,sizeof(stop),"%s/stop",argv[5]);snprintf(request,sizeof(request),"%s/request",argv[5]);
    for(unsigned tick=0;tick<18000;tick++) {
        if(!access(stop,F_OK)) { publish(argv[5],"final",index,stats,selector,errors,links,observed,tcp_counts,tcp_records);close(attached[0]);close(attached[1]);bpf_object__close(obj);return 0; }
        FILE* f=fopen(request,"r");if(f) { char name[64]={};check(fgets(name,sizeof(name),f)!=NULL,"snapshot request");check(!fclose(f),"request close");name[strcspn(name,"\n")]=0;check(!unlink(request),"request consumed");publish(argv[5],name,index,stats,selector,errors,links,observed,tcp_counts,tcp_records); }
        usleep(10000);
    }
    fprintf(stderr,"error: observer lifetime exceeded three minutes\n");return 1;
}
