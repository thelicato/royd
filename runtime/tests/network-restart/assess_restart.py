"""Read-only network backend continuity across an explicit service restart."""
import re

MAXIMUM = (1 << 63) - 1


def need(value, message):
    if not value:
        raise ValueError(message)


def assess(case):
    service = case['service']
    need(service in ('netd', 'zygote'), 'Unsupported restart service')
    before, after = case['identity_before'], case['identity_after']
    for key in ('id', 'started', 'restart_count', 'oom', 'running'):
        need(before[key] == after[key], 'Docker identity/state changed: '+key)
    need(after['running'] and not after['oom'] and after['restart_count'] == 0,
         'Unhealthy Docker state')
    for value in (before['system_server'], after['system_server'], before['netd'], after['netd']):
        need(re.fullmatch('[1-9][0-9]*', value) is not None and int(value) > 1,
             'Missing/ambiguous process identity')
    need(before['system_server'] != after['system_server'], 'SystemServer did not restart')
    # The packaged zygote64_32 rules import zygote64, whose onrestart also
    # restarts netd. Both supported entry points replace these processes.
    need(before['netd'] != after['netd'], 'Netd did not restart')
    need(case['host_init_before'] == case['host_init_after'] > 1, 'OCI init changed')
    need(case['persistence_before'] == case['persistence_after'], 'Durable state changed')
    lines = case['persistence_after'].splitlines()
    need(len(lines) == 4 and re.fullmatch('[0-9a-f]{64}  /data/local/tmp/royd-service-restart', lines[0])
         and lines[1] == case['token'] and re.fullmatch('[0-9a-f]{1,16}', lines[2])
         and re.fullmatch('package:org.chromium.webview_shell uid:1[0-9]{4}', lines[3]),
         'Missing durable file/setting/identity/package')
    deltas = {}
    for role in ('accounting', 'quota'):
        a, b = case['before'][role], case['after'][role]
        for key in ('ifindex', 'map_id', 'production_links', 'query'):
            need(a[key] == b[key], 'Network backend source changed: '+role+'/'+key)
        need(len(a['counters']) == len(b['counters']) == 4, 'Interface counter shape')
        need(all(type(x) is int and type(y) is int and 0 <= x <= y < 1 << 64
                 for x, y in zip(a['counters'], b['counters'])), 'Interface counters reset')
        deltas[role] = [y-x for x, y in zip(a['counters'], b['counters'])]
    a, b = case['before']['quota'], case['after']['quota']
    for key in ('map_id', 'drops_map_id'):
        need(a['quota'][key] == b['quota'][key] > 0, 'Quota map replaced')
    for q in (a['quota'], b['quota']):
        need(q['present'] and q['limit'] == MAXIMUM and 0 <= q['remaining'] <= MAXIMUM
             and q['generation'] > 0 and q['invalid'] == q['contention'] == 0,
             'Default quota unhealthy')
    need(b['quota']['generation'] >= a['quota']['generation'], 'Quota generation regressed')
    if b['quota']['generation'] == a['quota']['generation']:
        need(b['quota']['remaining'] <= a['quota']['remaining'], 'Same quota generation reset')
    ua, ub = a['quota_admitted'], b['quota_admitted']
    need(ua['map_id'] == ub['map_id'] > 0 and 0 <= ua['bytes'] <= ub['bytes'] < 1 << 64,
         'Admitted source/counter reset')
    for observation in (case['before'], case['after']):
        acc, quota = observation['accounting'], observation['quota']
        need(acc['map_id'] == quota['map_id'] and acc['query'] == quota['query'],
             'Accounting/quota source disagreement')
        need(all(acc['query'][d] == [acc['production_links'][d], quota['production_links'][d]]
                 for d in (0, 1)), 'Unexpected production chain')
    return dict(status='pass', service=service, interface_deltas=deltas,
                admitted_delta=ub['bytes']-ua['bytes'],
                quota_reregistered=b['quota']['generation'] != a['quota']['generation'],
                scope='Default backend identity/counter recovery, not finite quota or alert continuity')
