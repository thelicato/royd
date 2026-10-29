"""Real associated-alert receipts over the existing owned quota packet fixture."""
import errno
import json
from pathlib import Path
import re
import sys
import time
from assess import assess_flow, assess_packets, need
from fixture import IP_BYTES
from run import Trial, MAXIMUM, main


MATRIX = [(f'baseline-{role}-{op}', role, op, 1, 1) for role in ('a', 'b', 'system') for op in ('send', 'receive')]
MATRIX += [
    ('first-a-below', 'a', 'send', 1, 1), ('first-system-below', 'system', 'receive', 1, 1),
    ('first-b-cross', 'b', 'send', 1, 1), ('old-a-use', 'a', 'send', 1, 1),
    ('replacement-b-below', 'b', 'receive', 2, 2), ('replacement-system-cross', 'system', 'send', 1, 1),
    ('finite-a-send', 'a', 'send', 1, 1), ('finite-system-receive', 'system', 'receive', 1, 1),
    ('finite-b-dropped', 'b', 'send', 1, 0), ('cancelled-system-dropped', 'system', 'send', 1, 0),
    ('removed-a-send', 'a', 'send', 1, 1), ('sentinel-b-send', 'b', 'send', 1, 1),
    ('sentinel-system-receive', 'system', 'receive', 1, 1),
]
CROSSINGS = ('first-b-cross', 'replacement-system-cross')


def receipts(value, nonce):
    rows = value['callbacks']
    need(len(rows) <= 32 and value['sampled_ns'] > 0, 'callback bounds')
    previous = 0
    for index, row in enumerate(rows, 1):
        need(row['nonce'] == nonce and row['sequence'] == index and row['caller_uid'] == 0
             and row['caller_pid'] == 0 and row['interface'] == 'eth0'
             and row['name'] in ('globalAlert', 'eth0Alert'), 'callback identity')
        need(previous <= row['time_ns'] <= value['sampled_ns'] and row['time_ns'] > 0, 'callback timing')
        previous = row['time_ns']
    return [r for r in rows if r['name'] == 'eth0Alert']


def assess_alert_flow(item):
    a, b = item['before']['post'], item['after']['post']
    if item['label'] in CROSSINGS:
        # Stock NetworkPolicyManager handles this event by removing/replaying the
        # metered interface's MAX quota. Only these unlimited callback windows
        # allow an observed replacement. This does not prove the writer's identity
        # or relax finite-quota continuity in the original packet gate.
        result = assess_packets(item)
        qa, qb = a['quota'], b['quota']
        for q in (qa, qb):
            need(q['present'] and q['limit'] == MAXIMUM and q['generation'] > 0
                 and 0 <= q['remaining'] <= MAXIMUM and q['invalid'] == q['contention'] == 0,
                 'callback window must retain healthy unlimited policy')
        for key in ('map_id', 'drops_map_id'):
            need(qa[key] == qb[key] and qa[key] > 0, 'callback quota source changed')
        need(qb['generation'] >= qa['generation'], 'quota generation regressed')
        if qa['generation'] == qb['generation']:
            need(qb['remaining'] == qa['remaining'] - item['count']*IP_BYTES, 'unlimited debit mismatch')
        else:
            need(qb['remaining'] in (MAXIMUM,MAXIMUM-item['count']*IP_BYTES), 'unexpected replayed MAX debit')
        result.update(remaining=qb['remaining'], generation=qb['generation'])
    else:
        result = assess_flow(item)
    ua, ub = a['quota_admitted'], b['quota_admitted']
    need(ua['map_id'] == ub['map_id'] and ua['map_id'] > 0, 'admitted map changed')
    need(0 <= ua['bytes'] <= ub['bytes'] < 1 << 64, 'admitted counter regressed')
    expected = item['passed'] * IP_BYTES if a['quota']['present'] else 0
    need(ub['bytes'] - ua['bytes'] == expected, 'admitted counter includes wrong traffic/tail')
    return result


def no_traffic(before, after):
    for side in ('pre', 'post'):
        for key in ('ifindex', 'map_id', 'production_links', 'query', 'counters', 'observed'):
            need(before['packets'][side][key] == after['packets'][side][key], 'traffic/source changed during control/quiet')
    need(before['packets']['post']['quota_admitted'] == after['packets']['post']['quota_admitted'],
         'admitted traffic during control/quiet')


def ordered_usage(windows, map_id):
    previous = 0
    for before, after in windows:
        for sample in (before,after):
            need(sample['map_id'] == map_id and previous <= sample['bytes'] < 1 << 64,
                 'admitted source regressed between observations')
            previous = sample['bytes']


def replay_alerts(directory):
    directory = Path(directory)
    load = lambda name: json.loads((directory/name).read_text())
    scope = load('scope.json');plan = load('plan.json');events = load('alert-actions.json')
    from preparation import replay_for_scope
    replay_for_scope(directory,scope)
    need(len({w['ready']['uid'] for w in scope['workers'].values()}) == 3, 'distinct worker identities')
    for role, worker in scope['workers'].items():
        r = worker['ready']
        need(r['gid'] == r['uid'] and int(r['cap_eff'],16) == 0, 'worker privilege changed')
        need((r['uid'] == 1000 and r['importance'] == -1 and r['cgroup'].strip() == '0::/royd/init')
             if role == 'system' else (10000 <= r['uid'] < 20000 and r['importance'] == 300
                                       and '/uid_'+str(r['uid'])+'/' in r['cgroup']), 'worker scope changed')
    need([p['label'] for p in plan] == [r[0] for r in MATRIX], 'incomplete/reordered alert packet matrix')
    fixture = [json.loads(l) for l in (directory/'fixture.jsonl').read_text().splitlines()]
    identities = {(p['uid'], p['step']) for p in plan}
    need(all((r['uid'], r['step']) in identities for r in fixture), 'unplanned final fixture receipt')
    output = []
    for row, (label, role, op, count, passed) in zip(plan, MATRIX):
        item = load(label+'.json');item['fixture'] = fixture
        need(item['ready'] == scope['workers'][role]['ready'] and item['label'] == label
             and item['op'] == op and item['count'] == count and item['passed'] == passed, 'alert matrix identity')
        for snap in (item['before'], item['after']):
            need(snap['post']['quota_admitted']['map_id'] == load('initial-quota.json')['quota_admitted']['map_id'],
                 'admitted source differs from initial identity')
            need(snap['pre']['query'] == snap['post']['query'] == scope['chains'], 'frozen chain changed')
        result = assess_alert_flow(item)
        need(row == dict(label=label, role=role, **result), 'saved alert packet assessment differs')
        output.append(dict(label=label, **result))
    expected_labels = ['invalid-alert-zero', 'invalid-alert-negative', 'denied-alert-set', 'denied-alert-remove',
                       'remove-alert-absent', 'first-arm', 'quota-update', 'first-below', 'first-received',
                       'old-arm', 'replacement-arm', 'replacement-below', 'replacement-received', 'finite-arm',
                       'dropped-not-usage', 'explicit-alert-cancel', 'cancelled-still-enforced', 'exhausted-arm',
                       'exhausted-no-notification', 'explicit-quota-remove', 'missing-quota-alert', 'sentinel-arm',
                       'sentinel-quota-remove', 'final-quiet']
    need([e['label'] for e in events] == expected_labels, 'incomplete/reordered alert controls')
    previous_callbacks = []
    generation = 0
    for event in events:
        kind = event['type']
        need(kind in ('arm','reject','quiet','cancel','remove','quota-update'), 'unknown alert event')
        label = event['label']
        expected_kind = ('arm' if label in ('first-arm','old-arm','replacement-arm','finite-arm','exhausted-arm','sentinel-arm')
                         else 'reject' if label.startswith(('invalid-','denied-')) or label in ('remove-alert-absent','missing-quota-alert')
                         else 'cancel' if label == 'explicit-alert-cancel'
                         else 'remove' if label in ('explicit-quota-remove','sentinel-quota-remove')
                         else 'quota-update' if label == 'quota-update' else 'quiet')
        need(kind == expected_kind, 'wrong alert event type')
        need(event['after']['state']['error'] == event['before']['state']['error'] == 0, 'alert backend error')
        need(event['before']['state']['generation'] == generation, 'unplanned registration generation')
        generation += kind == 'arm'
        need(event['after']['state']['generation'] == generation, 'registration generation mismatch')
        no_traffic(event['before'], event['after'])
        for obs in (event['before'], event['after']):
            need(obs['packets']['post']['quota_admitted']['map_id'] == load('initial-quota.json')['quota_admitted']['map_id'],
                 'control admitted source changed')
            for side in ('pre','post'):
                need(obs['packets'][side]['query'] == scope['chains'], 'control chain changed')
            rows = obs['callbacks']['callbacks']
            need(rows[:len(previous_callbacks)] == previous_callbacks, 'callback ledger changed')
            receipts(obs['callbacks'], scope['nonce']);previous_callbacks = rows
        if event['type'] == 'arm':
            a, b = event['before']['state'], event['after']['state']
            need(b['generation'] == a['generation']+1 and b['bytes'] == event['receipt']['bytes']
                 and b['armed'] and b['committed'] == a['committed'], 'alert registration mismatch')
            need(event['after']['packets']['post']['quota'] == event['before']['packets']['post']['quota'],
                 'alert registration changed quota')
        elif event['type'] == 'reject':
            need(event['before']['state'] == event['after']['state']
                 and event['before']['packets']['post']['quota'] == event['after']['packets']['post']['quota'],
                 'rejected operation changed state')
            r = event['receipt']
            need(r['denied'] if event['label'].startswith('denied-') else r['error'] == event['expected'],
                 'rejected operation cause')
        elif event['type'] == 'quiet':
            need(event['end_ns']-event['start_ns'] >= 1_000_000_000, 'quiet interval too short')
            need(len(receipts(event['before']['callbacks'], scope['nonce']))
                 == len(receipts(event['after']['callbacks'], scope['nonce'])) == event['expected_callbacks'],
                 'premature/duplicate/missing callback')
            armed = event['label'] in ('first-below','replacement-below','dropped-not-usage','exhausted-no-notification')
            expected_callbacks = 0 if event['label'] == 'first-below' else 1 if event['label'] in (
                'first-received','replacement-below') else 2
            need(event['expected_callbacks'] == expected_callbacks and event['after']['state']['armed'] == armed
                 and event['after']['state']['committed'] == expected_callbacks, 'quiet sampler result')
        elif event['type'] in ('cancel', 'remove'):
            need(event['after']['state']['bytes'] == 0 and not event['after']['state']['armed'], 'cancellation failed')
            need(event['after']['state']['generation'] == event['before']['state']['generation'], 'cancel generation changed')
        elif kind == 'quota-update':
            need(event['before']['state'] == event['after']['state'], 'quota update reset alert')
            q = event['after']['packets']['post']['quota']
            need(q['present'] and q['limit'] == q['remaining'] == MAXIMUM
                 and q['generation'] > event['before']['packets']['post']['quota']['generation'], 'MAX quota update not installed')
        if 'receipt' in event:
            r = event['receipt'];ordinary = event['label'].startswith('denied-')
            expected_uid = scope['workers']['a']['ready']['uid'] if ordinary else 0
            need(r['nonce'] == scope['nonce'] and r['uid'] == expected_uid and r['pid'] > 1
                 and re.fullmatch('[0-9a-fA-F]{1,16}',r['cap_eff'])
                 and (not ordinary or int(r['cap_eff'],16) == 0), 'control caller identity')
            need(0 < r['started_ns'] <= r['finished_ns'], 'control timing')
            need(r['denied'] == ordinary and r['error'] == (0 if ordinary or kind != 'reject' else event['expected']),
                 'control error receipt')
            operation, bytes = {
                'invalid-alert-zero':('set-alert',0),'invalid-alert-negative':('set-alert',-1),
                'denied-alert-set':('set-alert',1),'denied-alert-remove':('remove-alert',0),
                'remove-alert-absent':('remove-alert',0),'explicit-alert-cancel':('remove-alert',0),
                'explicit-quota-remove':('remove',0),'missing-quota-alert':('set-alert',1),
                'sentinel-quota-remove':('set',-1),'quota-update':('set',MAXIMUM),
            }.get(event['label'],('set-alert',event['receipt']['bytes']))
            need(r['operation'] == operation and r['bytes'] == bytes, 'wrong control operation')
    final = load('final-callbacks.json');target = receipts(final, scope['nonce'])
    need(final['callbacks'][:len(previous_callbacks)] == previous_callbacks and len(target) == 2, 'late callback changed result')
    for callback, label, arm in zip(target, CROSSINGS, ('first-arm', 'replacement-arm')):
        phase = load(label+'.json');registration = next(e for e in events if e['label'] == arm)
        need(callback['time_ns'] >= phase['app']['ready_ns'] >= registration['receipt']['finished_ns'],
             'callback preceded its actual crossing')
    by_label = {e['label']:e for e in events}
    expected_thresholds = {'first-arm':2*IP_BYTES+1,'old-arm':4*IP_BYTES+1,
                           'replacement-arm':2*IP_BYTES+1,'finite-arm':3*IP_BYTES,
                           'exhausted-arm':1,'sentinel-arm':3*IP_BYTES}
    for label, threshold in expected_thresholds.items():
        event = by_label[label]
        need(event['type'] == 'arm' and event['receipt']['operation'] == 'set-alert'
             and event['receipt']['bytes'] == threshold, 'wrong requested alert threshold')
    for quiet, arm in [('first-below','first-arm'),('replacement-below','replacement-arm')]:
        used = by_label[quiet]['after']['packets']['post']['quota_admitted']['bytes']
        base = by_label[arm]['after']['packets']['post']['quota_admitted']['bytes']
        need(used-base == 2*IP_BYTES, 'below-threshold window must stop exactly one IP byte short')
    need(by_label['replacement-arm']['before']['packets']['post']['quota_admitted']['bytes']
         - by_label['old-arm']['after']['packets']['post']['quota_admitted']['bytes'] == IP_BYTES,
         'old alert must be partly consumed before replacement')
    def control_quota(name):
        paths = list((directory/'observer-post').glob('s*-'+name+'.json'))
        need(len(paths) == 1, 'missing/ambiguous quota transition')
        return json.loads(paths[0].read_text())['quota']
    expected = control_quota('finite-budget-after')
    need(expected['limit'] == expected['remaining'] == 2*IP_BYTES+100, 'finite allowance mismatch')
    for label in ('finite-a-send','finite-system-receive','finite-b-dropped','cancelled-system-dropped'):
        item = load(label+'.json')
        need(item['before']['post']['quota'] == expected,'finite budget changed between packet windows')
        expected = item['after']['post']['quota']
    need(expected['remaining'] == 0, 'finite quota not exhausted')
    sentinel = control_quota('sentinel-budget-after')
    need(sentinel['limit'] == sentinel['remaining'] == 2*IP_BYTES
         and load('sentinel-b-send.json')['before']['post']['quota'] == sentinel, 'sentinel allowance mismatch')
    for phase, control in [('removed-a-send','explicit-quota-remove'),('sentinel-system-receive','sentinel-quota-remove')]:
        q = by_label[control]['after']['packets']['post']['quota']
        need(by_label[control]['type'] == 'remove' and not q['present']
             and load(phase+'.json')['before']['post']['quota'] == q, 'quota removal not continuous')
    insert_before = {
        'baseline-a-send':expected_labels[:5], 'first-a-below':['first-arm'],
        'first-system-below':['quota-update'], 'first-b-cross':['first-below'],
        'old-a-use':['first-received','old-arm'], 'replacement-b-below':['replacement-arm'],
        'replacement-system-cross':['replacement-below'], 'finite-a-send':['replacement-received','finite-arm'],
        'cancelled-system-dropped':['dropped-not-usage','explicit-alert-cancel'],
        'removed-a-send':['cancelled-still-enforced','exhausted-arm','exhausted-no-notification','explicit-quota-remove'],
        'sentinel-b-send':['missing-quota-alert','sentinel-arm'],
        'sentinel-system-receive':['sentinel-quota-remove'],
    }
    windows = []
    def event_window(label):
        e = by_label[label]
        return tuple(e[side]['packets']['post']['quota_admitted'] for side in ('before','after'))
    for label,*_ in MATRIX:
        windows.extend(event_window(e) for e in insert_before.get(label,[]))
        item = load(label+'.json')
        windows.append(tuple(item[side]['post']['quota_admitted'] for side in ('before','after')))
    windows.append(event_window('final-quiet'))
    ordered_usage(windows,load('initial-quota.json')['quota_admitted']['map_id'])
    return dict(status='pass',scope='associated-interface-alerts-sequential-ipv4-udp',callbacks=target,phases=output,
                attempted=sum(p['attempted'] for p in output),admitted=sum(p['admitted'] for p in output),
                denied=sum(p['denied'] for p in output))


class AlertTrial(Trial):
    quota_inspect_mode = 'inspect-quota-alert'
    quota_observe_mode = 'observe-quota-alert'
    extra_required = ('ALERT_STATUS','ALERT_RESTORE_STATUS')

    def __init__(self):
        super().__init__()
        self.manifest.update(ROYD_INTERFACE_ALERT_EVIDENCE_FORMAT=1, ALERT_STATUS='not-tested',ALERT_RESTORE_STATUS='not-tested')
        self.actions = [];self.alert_owned = False;self.listening = False

    def callbacks(self):
        self.owner()
        value = self.channels[0].request('callbacks')
        receipts(value, self.nonce)
        return value

    def state(self, label):
        text = self.dx(['timeout', '10', 'dumpsys', 'netd'], label+'.log')
        rows = re.findall(r'^royd interface alert: generation=(\d+) bytes=(\d+) armed=(yes|no) committed=(\d+) error=(\d+) sample_ms=250$', text, re.M)
        need(len(rows) == 1, 'missing/ambiguous interface-alert state')
        g,b,a,c,e = rows[0]
        return dict(generation=int(g), bytes=int(b), armed=a == 'yes', committed=int(c), error=int(e))

    def observe(self, label):
        return dict(packets=self.snapshot(label),state=self.state(label),callbacks=self.callbacks())

    def event(self, kind, label, before, **fields):
        after = self.observe(label+'-after')
        value = dict(type=kind,label=label,before=before,after=after,**fields)
        self.save(label+'-event.json',value)
        with (self.out/'alert-actions.jsonl').open('a') as f:f.write(json.dumps(value)+'\n')
        no_traffic(before,after);need(after['state']['error'] == 0,'interface-alert fault')
        self.actions.append(value)
        return after

    def assess_item(self, item):
        return assess_alert_flow(item)

    def reject(self,label,operation,bytes,expected,uid=0):
        before = self.observe(label+'-before')
        receipt = self.control(label,operation,bytes,expected,uid)
        after = self.event('reject',label,before,receipt=receipt,expected=expected)
        need(before['state'] == after['state'] and before['packets']['post']['quota'] == after['packets']['post']['quota'],
             'rejected operation changed backend')

    def arm(self,label,bytes):
        before = self.observe(label+'-before');self.alert_owned = True;self.restore_needed = True
        receipt = self.control(label,'set-alert',bytes)
        after = self.event('arm',label,before,receipt=receipt)
        need(after['state'] == dict(before['state'],generation=before['state']['generation']+1,bytes=bytes,armed=True),
             'alert registration mismatch')

    def quiet(self,label,count,armed,received=False):
        if received:
            self.wait(lambda:len(receipts(self.callbacks(),self.nonce)) >= count,5,'actual interface callback')
        before = self.observe(label+'-before');start = time.monotonic_ns();time.sleep(1)
        after = self.event('quiet',label,before,start_ns=start,end_ns=time.monotonic_ns(),expected_callbacks=count)
        need(len(receipts(before['callbacks'],self.nonce)) == len(receipts(after['callbacks'],self.nonce)) == count,
             'premature/duplicate/missing interface notification')
        need(after['state']['armed'] == armed and after['state']['committed'] == count, 'alert sampler state mismatch')
        if received:
            for obs in (before,after):
                q = obs['packets']['post']['quota']
                need(q['present'] and q['limit'] == MAXIMUM,'callback policy did not retain MAX allowance')
            self.expected_quota = None
        else:
            need(before['state'] == after['state'] and before['packets']['post']['quota'] == after['packets']['post']['quota'],
                 'quiet backend changed')

    def cancel(self,label,operation='remove-alert',bytes=0):
        before = self.observe(label+'-before');self.restore_needed = True
        receipt = self.control(label,operation,bytes)
        after = self.event('cancel' if operation == 'remove-alert' else 'remove',label,before,receipt=receipt)
        need(after['state']['bytes'] == 0 and not after['state']['armed'],'associated alert not cancelled')
        if operation != 'remove-alert':
            need(not after['packets']['post']['quota']['present'],'quota not removed')
            self.expected_quota = after['packets']['post']['quota']

    def workload(self):
        self.manifest['ALERT_STATUS'] = 'fail'
        need(self.channels[0].request('listen') == dict(listening=True),'listener registration receipt')
        self.listening = True
        initial = self.state('initial-alert-state')
        need(initial == dict(generation=0,bytes=0,armed=False,committed=0,error=0),'pre-existing alert state')
        self.alert_owned = True
        uid = self.workers['a']['ready']['uid']
        for args in [('invalid-alert-zero','set-alert',0,errno.ERANGE,0),('invalid-alert-negative','set-alert',-1,errno.ERANGE,0),
                     ('denied-alert-set','set-alert',1,-1,uid),('denied-alert-remove','remove-alert',0,-1,uid),
                     ('remove-alert-absent','remove-alert',0,errno.ENOENT,0)]:self.reject(*args)
        self.channels[uid].close()
        for role in self.workers:
            for op in ('send','receive'):self.flow('baseline-'+role+'-'+op,role,op,1,1,None)
        self.arm('first-arm',2*IP_BYTES+1)
        self.flow('first-a-below','a','send',1,1,None)
        before = self.observe('quota-update-before');self.set_quota('quota-update-max',MAXIMUM)
        receipt = json.loads((self.out/'quota-update-max.log').read_text())
        after = self.event('quota-update','quota-update',before,receipt=receipt)
        need(before['state'] == after['state'],'quota replacement reset alert window')
        self.expected_quota = None
        self.flow('first-system-below','system','receive',1,1,None)
        self.quiet('first-below',0,True)
        self.flow('first-b-cross','b','send',1,1,None);self.quiet('first-received',1,False,True)
        self.arm('old-arm',4*IP_BYTES+1);self.flow('old-a-use','a','send',1,1,None)
        self.arm('replacement-arm',2*IP_BYTES+1)
        self.flow('replacement-b-below','b','receive',2,2,None);self.quiet('replacement-below',1,True)
        self.flow('replacement-system-cross','system','send',1,1,None);self.quiet('replacement-received',2,False,True)
        self.set_quota('finite-budget',2*IP_BYTES+100);self.arm('finite-arm',3*IP_BYTES)
        self.flow('finite-a-send','a','send',1,1,IP_BYTES+100)
        self.flow('finite-system-receive','system','receive',1,1,100)
        self.flow('finite-b-dropped','b','send',1,0,0);self.quiet('dropped-not-usage',2,True)
        self.cancel('explicit-alert-cancel');self.flow('cancelled-system-dropped','system','send',1,0,0)
        self.quiet('cancelled-still-enforced',2,False)
        self.arm('exhausted-arm',1);self.quiet('exhausted-no-notification',2,True)
        self.cancel('explicit-quota-remove','remove');self.flow('removed-a-send','a','send',1,1,0)
        self.reject('missing-quota-alert','set-alert',1,errno.ENOENT)
        self.set_quota('sentinel-budget',2*IP_BYTES);self.arm('sentinel-arm',3*IP_BYTES)
        self.flow('sentinel-b-send','b','send',1,1,IP_BYTES)
        self.cancel('sentinel-quota-remove','set',-1);self.flow('sentinel-system-receive','system','receive',1,1,0)
        self.quiet('final-quiet',2,False)
        self.save('alert-actions.json',self.actions);self.save('plan.json',self.plan)
        self.manifest['WORKLOAD_STATUS'] = 'pass'

    def before_close_controllers(self):
        if self.listening:
            value = self.callbacks();self.save('final-callbacks.json',value)
            need(len(receipts(value,self.nonce)) == 2 if self.manifest['WORKLOAD_STATUS'] == 'pass' else True,
                 'late interface callback')

    def replay_packets(self):
        self.manifest['ALERT_STATUS'] = 'fail'
        result = replay_alerts(self.out)
        self.manifest['ALERT_STATUS'] = 'pass'
        return result

    def finish(self):
        if self.alert_owned:
            self.finishing = True;self.refresh_enabled = False
            self.manifest['ALERT_RESTORE_STATUS'] = 'fail'
            def restore_alert():
                state = self.state('restore-alert-before')
                self.control('restore-alert','remove-alert',expected=0 if state['bytes'] else errno.ENOENT)
                after = self.state('restore-alert-after')
                need(after['bytes'] == 0 and not after['armed'],'alert restoration failed')
                self.manifest['ALERT_RESTORE_STATUS'] = 'pass'
            self.attempt('restore owned absent alert',restore_alert)
        super().finish()


if __name__ == '__main__':sys.exit(main(AlertTrial))
