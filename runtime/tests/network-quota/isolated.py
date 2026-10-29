"""Disposable routed IPv4 test link. Never configures the host network namespace."""
import json
import os
from assess import need

ADDRESS, GATEWAY = '10.254.0.2', '10.254.0.1'


class IsolatedLink:
    def __init__(self, trial):
        self.t = trial
        self.holders = {}
        self.frozen = None

    def owner(self, role):
        h = self.holders[role]
        item = json.loads(self.t.run(['docker', 'inspect', h['id']]).stdout)[0]
        need(item['Id'] == h['id'] and item['Name'] == '/'+h['name'] and item['Image'] == self.t.image
             and item['Config']['Labels'].get('org.royd.test.owner') == self.t.token
             and item['Config']['Labels'].get('org.royd.test') == 'quota-link-holder'
             and item['HostConfig']['NetworkMode'] == ('none' if role == 'android' else 'bridge'),
             'isolated holder ownership changed')
        need(item['HostConfig']['ReadonlyRootfs']
             and item['HostConfig']['Privileged'] == (role == 'android')
             and item['HostConfig']['CapDrop'] == (None if role == 'android' else ['ALL']),
             'holder privilege changed')
        if 'pid' in h:
            need(item['State']['Running'] and item['State']['Pid'] == h['pid']
                 and item['State']['StartedAt'] == h['started'] and item['RestartCount'] == 0
                 and not item['State']['OOMKilled']
                 and os.readlink('/proc/'+str(h['pid'])+'/ns/net') == h['namespace'], 'isolated namespace changed')
        return item

    def inside(self, role, argv):
        self.owner(role)
        return self.t.run(['nsenter', '--net=/proc/'+str(self.holders[role]['pid'])+'/ns/net', *argv]).stdout

    def setup(self):
        self.t.manifest['ISOLATION_STATUS'] = 'fail'
        for role in ('gateway', 'android'):
            name = self.t.container+'-'+role
            need(self.t.run(['docker', 'inspect', name], check=False).returncode != 0, 'existing link holder')
            # A shared sysfs superblock inherits its first mount's read-only mode.
            # Match the Android baseline when creating that namespace. The holder
            # runs only sleep; the separate gateway remains capability-free.
            security = ['--privileged'] if role == 'android' else ['--cap-drop', 'ALL']
            cid = self.t.run(['docker', 'create', '--name', name, '--network',
                             'none' if role == 'android' else 'bridge', '--read-only', *security,
                             '--no-healthcheck', '--label', 'org.royd.test=quota-link-holder',
                             '--label', 'org.royd.test.owner='+self.t.token,
                             '--entrypoint', '/system/bin/bootstrap/linker64', self.t.image,
                             '/system/bin/toybox', 'sleep', '2400'], 'holder-'+role+'-create.log').stdout.strip()
            self.holders[role] = dict(id=cid, name=name)
            self.owner(role)
            self.t.run(['docker', 'start', cid], 'holder-'+role+'-start.log')
            item = self.owner(role)
            pid = item['State']['Pid']
            need(item['State']['Running'] and pid > 1, 'holder did not start')
            namespace = os.readlink('/proc/'+str(pid)+'/ns/net')
            need(namespace != os.readlink('/proc/self/ns/net'), 'host namespace refused')
            self.holders[role].update(pid=pid, namespace=namespace, started=item['State']['StartedAt'])
        need(self.holders['android']['namespace'] != self.holders['gateway']['namespace'], 'shared holder namespace')
        # Only this newly owned gateway receives a forwarding/NAT configuration.
        self.inside('gateway', ['sysctl', '-w', 'net.ipv4.ip_forward=1'])
        self.inside('android', ['ip', 'link', 'add', 'eth0', 'type', 'veth', 'peer', 'name', 'fixture0',
                                'netns', str(self.holders['gateway']['pid'])])
        for role, dev, address in [('android', 'eth0', ADDRESS), ('gateway', 'fixture0', GATEWAY)]:
            self.inside(role, ['ip', 'link', 'set', 'dev', dev, 'addrgenmode', 'none'])
            self.inside(role, ['ip', 'addr', 'add', address+'/30', 'dev', dev])
            self.inside(role, ['ip', 'link', 'set', 'dev', dev, 'up'])
        self.inside('android', ['ip', 'route', 'add', 'default', 'via', GATEWAY, 'dev', 'eth0'])
        self.inside('gateway', ['iptables', '-t', 'nat', '-N', 'ROYD_QUOTA_TEST'])
        self.inside('gateway', ['iptables', '-t', 'nat', '-A', 'ROYD_QUOTA_TEST', '-s', ADDRESS+'/32',
                                '-o', 'eth0', '-j', 'MASQUERADE'])
        self.inside('gateway', ['iptables', '-t', 'nat', '-A', 'POSTROUTING', '-j', 'ROYD_QUOTA_TEST'])
        self.frozen = self.snapshot('isolated-link-before')
        self.t.manifest['ISOLATION_STATUS'] = 'pass'

    def snapshot(self, label):
        value = dict(holders=self.holders)
        for role in self.holders:
            value[role] = {}
            for kind, argv in [('links', ['ip', '-j', '-d', 'link']),
                               ('addresses', ['ip', '-j', 'addr']), ('routes', ['ip', '-j', 'route'])]:
                value[role][kind] = json.loads(self.inside(role, argv))
        a = next(v for v in value['android']['links'] if v['ifname'] == 'eth0')
        b = next(v for v in value['gateway']['links'] if v['ifname'] == 'fixture0')
        outer = next(v for v in value['gateway']['links'] if v['ifname'] == 'eth0')
        need(a['linkinfo']['info_kind'] == b['linkinfo']['info_kind'] == 'veth'
             and a['ifindex'] == b['link_index'] and b['ifindex'] == a['link_index']
             and not a.get('master') and not b.get('master'), 'isolated link reciprocity')
        value['nat'] = self.inside('gateway', ['iptables-save', '-t', 'nat'])
        rules = self.inside('gateway', ['iptables', '-t', 'nat', '-S'])
        value['forwarding'] = self.inside('gateway', ['cat', '/proc/sys/net/ipv4/ip_forward']).strip()
        need(value['forwarding'] == '1', 'isolated forwarding changed')
        # Exclude lifetimes, counters, multicast membership and other live link fields.
        def ipv4(role):
            return sorted((r['ifname'], v['local'], v['prefixlen'], v['scope'])
                          for r in value[role]['addresses'] for v in r['addr_info'] if v['family'] == 'inet')
        need({r['ifname'] for r in value['android']['links']} == {'lo','eth0'}
             and ('eth0',ADDRESS,30,'global') in ipv4('android')
             and ('fixture0',GATEWAY,30,'global') in ipv4('gateway'), 'isolated IPv4 configuration')
        value['identity'] = dict(android_namespace=self.holders['android']['namespace'],
                                gateway_namespace=self.holders['gateway']['namespace'],
                                android_link=[a[k] for k in ('ifindex','address','link_index')],
                                gateway_link=[b[k] for k in ('ifindex','address','link_index')],
                                outer_link=[outer[k] for k in ('ifindex','address','link_index')],
                                android_ipv4=ipv4('android'), gateway_ipv4=ipv4('gateway'),
                                android_routes=value['android']['routes'], gateway_routes=value['gateway']['routes'],
                                nat=rules)
        self.t.save(label+'.json', value)
        if self.frozen is not None:
            need(value['identity'] == self.frozen['identity'], 'isolated configuration changed')
        return value

    def cleanup(self):
        # Leave both namespaces when workload capture/detachment has not completed.
        self.t.manifest['ISOLATION_CLEANUP_STATUS'] = 'fail'
        ids = self.t.run(['docker', 'ps', '-aq', '--no-trunc']).stdout.split()
        if ids:
            items = json.loads(self.t.run(['docker', 'inspect', *ids]).stdout)
            references = {key for h in self.holders.values() for key in (h['id'], h['name'])}
            need(not any(v['Id'] not in {h['id'] for h in self.holders.values()}
                         and v['HostConfig']['NetworkMode'].removeprefix('container:') in references
                         for v in items), 'unowned container shares an isolated holder')
        for role in list(self.holders):
            item = self.owner(role)
            self.t.save('holder-'+role+'-inspect.json', item)
            self.t.run(['docker', 'logs', item['Id']], 'holder-'+role+'-logs.log')
        for role in list(self.holders):
            self.owner(role)
            self.t.run(['docker', 'rm', '-f', self.holders[role]['id']], 'holder-'+role+'-cleanup.log')
            del self.holders[role]
        self.t.manifest['ISOLATION_CLEANUP_STATUS'] = 'pass'
