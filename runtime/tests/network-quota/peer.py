"""Read-only identity for an owned Docker eth0's host-side veth peer."""
import re
from assess import need


def identify(container_links, host_links, expected_ifindex):
    need(len(container_links) == 1, 'ambiguous container link')
    inner = container_links[0]
    need(inner['ifname'] == 'eth0' and inner['ifindex'] == expected_ifindex > 1
         and inner['linkinfo']['info_kind'] == 'veth', 'container veth identity')
    peers = [v for v in host_links if v['ifindex'] == inner['link_index']]
    need(len(peers) == 1, 'missing/ambiguous host peer')
    outer = peers[0]
    need(outer['linkinfo']['info_kind'] == 'veth' and outer['link_index'] == expected_ifindex
         and outer['ifindex'] > 1 and outer.get('master') == 'docker0', 'host veth reciprocity/bridge')
    need(re.fullmatch(r'veth[0-9a-f]{1,11}', outer['ifname']), 'unexpected host veth name')
    for link in (inner, outer):
        need(re.fullmatch(r'(?:[0-9a-f]{2}:){5}[0-9a-f]{2}', link['address']), 'invalid link address')
    return dict(container=dict(ifindex=inner['ifindex'], address=inner['address']),
                host=dict(ifindex=outer['ifindex'], ifname=outer['ifname'], address=outer['address'],
                          master=outer['master']))
