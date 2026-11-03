#!/usr/bin/env python3
"""Check resolved Telecom build artefacts; source tests cannot qualify ART selection."""
import copy
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

IKE = 'android.net.ipsec.ike'
IKE_JAR = '/apex/com.android.ipsec/javalib/android.net.ipsec.ike.jar'
NAME = '{http://schemas.android.com/apk/res/android}name'


def check(global_config, module, manifest, status):
    assert global_config['DisablePreopt'] is False, 'precompilation disabled'
    assert global_config['DisablePreoptBootImages'] is False, 'boot precompilation disabled'
    assert global_config['RelaxUsesLibraryCheck'] is False, 'verification relaxed'
    assert 'Telecom' not in global_config['DisablePreoptModules'], 'Telecom excluded'
    assert module['Name'] == 'Telecom'
    assert module['DexLocation'] == '/system/priv-app/Telecom/Telecom.apk'
    assert module['EnforceUsesLibraries'] is True, 'verification disabled'
    assert IKE_JAR in module['PreoptBootClassPathDexLocations'], 'IKE absent from boot classpath'

    def names(contexts):
        for context in contexts:
            yield context['Name']
            yield from names(context['Subcontexts'])

    assert IKE not in names([entry for entries in module['ClassLoaderContexts'].values()
                            for entry in entries]), 'IKE remains in class-loader context'
    assert IKE not in [node.get(NAME) for node in ET.fromstring(manifest).iter('uses-library')], \
        'IKE remains in manifest'
    assert not status.strip(), 'manifest verification failed'


def self_test():
    global_config = dict(DisablePreopt=False, DisablePreoptBootImages=False,
                         RelaxUsesLibraryCheck=False, DisablePreoptModules=[])
    module = dict(Name='Telecom', DexLocation='/system/priv-app/Telecom/Telecom.apk',
                  EnforceUsesLibraries=True, PreoptBootClassPathDexLocations=[IKE_JAR],
                  ClassLoaderContexts={'any': [dict(Name='retained', Subcontexts=[])]})
    manifest = '<manifest xmlns:android="http://schemas.android.com/apk/res/android"><application><uses-library android:name="retained"/></application></manifest>'
    check(global_config, module, manifest, '')
    cases = []
    for field in ['DisablePreopt', 'DisablePreoptBootImages', 'RelaxUsesLibraryCheck']:
        changed = copy.deepcopy(global_config); changed[field] = True
        cases.append((changed, module, manifest, ''))
    changed = copy.deepcopy(global_config); changed['DisablePreoptModules'] = ['Telecom']
    cases.append((changed, module, manifest, ''))
    for field, value in [('EnforceUsesLibraries', False), ('PreoptBootClassPathDexLocations', [])]:
        changed = copy.deepcopy(module); changed[field] = value
        cases.append((global_config, changed, manifest, ''))
    for nested in [False, True]:
        changed = copy.deepcopy(module)
        entry = dict(Name=IKE, Subcontexts=[])
        if nested:
            changed['ClassLoaderContexts']['any'][0]['Subcontexts'].append(entry)
        else:
            changed['ClassLoaderContexts']['any'].append(entry)
        cases.append((global_config, changed, manifest, ''))
    cases.append((global_config, module, manifest.replace('retained', IKE), ''))
    cases.append((global_config, module, manifest, 'verification failure'))
    for args in cases:
        try:
            check(*args)
        except AssertionError:
            continue
        raise AssertionError('invalid build artefacts accepted')
    print('Telecom precompilation artefact checks passed: positive control and 10 failures')


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
    else:
        if len(sys.argv) != 5:
            sys.exit('usage: android15-telecom-preopt-check.py GLOBAL_JSON MODULE_JSON MANIFEST_XML VERIFICATION_STATUS')
        global_file, module_file, manifest_file, status_file = map(Path, sys.argv[1:])
        check(json.loads(global_file.read_text()), json.loads(module_file.read_text()),
              manifest_file.read_text(), status_file.read_text())
        print('Resolved Telecom manifest and precompilation context agree; verification enabled')
