import copy
import unittest
from peer import identify


def links():
    return ([dict(ifname='eth0',ifindex=2,link_index=748,address='3a:0a:bb:8c:fd:c9',
                  linkinfo=dict(info_kind='veth'))],
            [dict(ifname='veth87a8fa7',ifindex=748,link_index=2,address='46:ee:32:9f:1b:44',
                  master='docker0',linkinfo=dict(info_kind='veth'))])


class PeerIdentity(unittest.TestCase):
    def test_reciprocal_peer_is_distinct_from_container_mac(self):
        inner,outer = links();value = identify(inner,outer,2)
        self.assertEqual(value['host']['address'],'46:ee:32:9f:1b:44')
        self.assertNotEqual(value['host']['address'],value['container']['address'])

    def test_unowned_physical_renamed_recycled_and_ambiguous_links_rejected(self):
        mutations = [lambda a,b:a.append(copy.deepcopy(a[0])),
                     lambda a,b:b.append(copy.deepcopy(b[0])),lambda a,b:b.clear(),
                     lambda a,b:a[0].update(ifindex=3),lambda a,b:a[0].update(ifname='other'),
                     lambda a,b:b[0].update(link_index=3),lambda a,b:b[0].update(master='other'),
                     lambda a,b:b[0].update(ifname='../eth0'),lambda a,b:b[0].update(address='invalid'),
                     lambda a,b:b[0].update(linkinfo=dict(info_kind='physical')),
                     lambda a,b:a[0].update(linkinfo=dict(info_kind='physical'))]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                inner,outer = links();mutate(inner,outer)
                with self.assertRaises(ValueError):identify(inner,outer,2)


if __name__ == '__main__':unittest.main()
