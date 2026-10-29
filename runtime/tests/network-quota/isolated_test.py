import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch
from unittest.mock import Mock
from types import SimpleNamespace
from fixture import Fixture
from isolated import IsolatedLink
from interface_alert import AlertTrial
import runner_test


class Ownership(unittest.TestCase):
    def configure(self):
        self.calls = []
        self.item = dict(Id='cid',Name='/owned',Image='image',RestartCount=0,
                         Config=dict(Labels={'org.royd.test.owner':'token','org.royd.test':'quota-link-holder'}),
                         HostConfig=dict(NetworkMode='none',ReadonlyRootfs=True,CapDrop=None,Privileged=True),
                         State=dict(Running=True,Pid=7,StartedAt='start',OOMKilled=False))
        def run(argv,*args,**kwargs):
            self.calls.append(argv)
            return subprocess.CompletedProcess(argv,0,json.dumps([self.item]))
        self.link = IsolatedLink(SimpleNamespace(run=run,save=lambda *a:None,image='image',token='token',manifest={}))
        self.link.holders['android'] = dict(id='cid',name='owned',pid=7,namespace='private',started='start')

    def test_holder_replacement_restart_privilege_and_namespace_changes_refused(self):
        self.configure()
        with patch('isolated.os.readlink',return_value='private'):self.link.owner('android')
        mutations = [lambda v:v.update(Id='other'),lambda v:v.update(Image='other'),
                     lambda v:v.update(Name='/other'),lambda v:v.update(RestartCount=1),
                     lambda v:v['Config']['Labels'].update({'org.royd.test.owner':'other'}),
                     lambda v:v['HostConfig'].update(NetworkMode='host'),
                     lambda v:v['HostConfig'].update(Privileged=False),
                     lambda v:v['HostConfig'].update(ReadonlyRootfs=False),
                     lambda v:v['HostConfig'].update(CapDrop=[]),
                     lambda v:v['State'].update(StartedAt='restarted'),
                     lambda v:v['State'].update(Pid=8),lambda v:v['State'].update(OOMKilled=True)]
        original=copy.deepcopy(self.item)
        for mutate in mutations:
            self.item=copy.deepcopy(original);mutate(self.item)
            with self.subTest(mutate=mutate),patch('isolated.os.readlink',return_value='private'),self.assertRaises(ValueError):
                self.link.owner('android')
        self.item=original
        with patch('isolated.os.readlink',return_value='changed'),self.assertRaises(ValueError):self.link.owner('android')

    def test_gateway_retains_capability_free_profile(self):
        self.configure();self.item['HostConfig'].update(NetworkMode='bridge',CapDrop=['ALL'],Privileged=False)
        self.link.holders['gateway']=self.link.holders.pop('android')
        with patch('isolated.os.readlink',return_value='private'):self.link.owner('gateway')
        self.item['HostConfig']['Privileged']=True
        with patch('isolated.os.readlink',return_value='private'),self.assertRaises(ValueError):self.link.owner('gateway')

    def test_unowned_holder_is_neither_entered_nor_deleted(self):
        self.configure();self.item['Image']='foreign'
        original=self.link.t.run
        self.link.t.run=lambda argv,*a,**kw:subprocess.CompletedProcess(argv,0,'') if argv[:3]==['docker','ps','-aq'] else original(argv,*a,**kw)
        for operation in (lambda:self.link.inside('android',['sysctl','-w','net.ipv4.ip_forward=1']),self.link.cleanup):
            with self.assertRaises(ValueError):operation()
        self.assertTrue(all(argv[:2]==['docker','inspect'] for argv in self.calls))
        self.assertEqual(self.link.t.manifest['ISOLATION_CLEANUP_STATUS'],'fail')

    def test_unowned_namespace_client_preserves_both_holders(self):
        self.configure()
        def run(argv,*args,**kwargs):
            self.calls.append(argv)
            text='foreign' if argv[:3]==['docker','ps','-aq'] else json.dumps([
                dict(Id='foreign',HostConfig=dict(NetworkMode='container:cid'))])
            return subprocess.CompletedProcess(argv,0,text)
        self.link.t.run=run
        with self.assertRaisesRegex(ValueError,'unowned container shares'):self.link.cleanup()
        self.assertFalse(any(v[:2]==['docker','rm'] for v in self.calls))


class NamespaceSockets(unittest.TestCase):
    def test_socket_namespace_entry_occurs_only_on_creator_thread(self):
        main=threading.get_ident();entries=[]
        with tempfile.TemporaryDirectory() as name,patch('fixture.os.setns',side_effect=lambda *a:entries.append(threading.get_ident())):
            fixture=Fixture('127.0.0.1',Path(name)/'rows','/proc/self/ns/net')
            try:self.assertEqual(len(entries),1);self.assertNotEqual(entries[0],main)
            finally:fixture.close()

    def test_namespace_failure_propagates_before_socket_creation(self):
        with tempfile.TemporaryDirectory() as name,patch('fixture.os.setns',side_effect=PermissionError('refused')),patch('fixture.socket.socket') as create:
            with self.assertRaisesRegex(PermissionError,'refused'):Fixture('127.0.0.1',Path(name)/'rows','/proc/self/ns/net')
            create.assert_not_called()

    def test_changed_namespace_descriptor_refused_before_entry_or_socket(self):
        with tempfile.TemporaryDirectory() as name,patch('fixture.os.setns') as enter,patch('fixture.socket.socket') as create:
            with self.assertRaisesRegex(ValueError,'identity changed'):
                Fixture('127.0.0.1',Path(name)/'rows','/proc/self/ns/net','net:[foreign]')
            enter.assert_not_called();create.assert_not_called()

    def test_isolated_mode_requires_capture_and_preserves_alert_stage_requirements(self):
        with tempfile.TemporaryDirectory() as name:
            with patch.dict(os.environ,ROYD_QUOTA_NETWORK_MODE='isolated',ROYD_QUOTA_PACKET_HEADERS='0',ROYD_QUOTA_OUTPUT_DIR=name+'/bad'):
                with self.assertRaisesRegex(ValueError,'requires packet headers'):AlertTrial()
            with patch.dict(os.environ,ROYD_QUOTA_NETWORK_MODE='isolated',ROYD_QUOTA_PACKET_HEADERS='1',ROYD_QUOTA_OUTPUT_DIR=name+'/valid'):
                trial=AlertTrial()
            self.assertEqual(set(trial.extra_required),{'ALERT_STATUS','ALERT_RESTORE_STATUS','ISOLATION_STATUS','ISOLATION_CLEANUP_STATUS','PREPARATION_STATUS'})


class Cleanup(unittest.TestCase):
    setUp=runner_test.Lifecycle.setUp
    tearDown=runner_test.Lifecycle.tearDown
    configure=runner_test.Lifecycle.configure

    def test_failed_android_capture_retains_gateway_and_namespace_holder(self):
        t=self.configure(capture_failure=True);t.link=Mock()
        t.finish();t.link.cleanup.assert_not_called()
        self.assertEqual(t.manifest['CAPTURE_STATUS'],'fail')


if __name__=='__main__':unittest.main()
