"""Apply the actual quota/alert/event layers to the pinned controller fixture."""
from pathlib import Path
import subprocess
import sys

root, output = map(Path, sys.argv[1:])
source = output/'applied'
server = source/'system/netd/server'
server.mkdir(parents=True)
fixtures = root/'android/tests/fixtures/android15'
for suffix in ('cpp','h'):
    (server/('BandwidthController.'+suffix)).write_bytes((fixtures/('global-alert-bandwidth.'+suffix)).read_bytes())
names = ('BandwidthController.cpp','BandwidthController.h','RoydInterfaceQuota.h',
         'RoydGlobalAlert.h','RoydGlobalAlertSource.h','RoydInterfaceAlert.h',
         'RoydInterfaceAlertSource.h','RoydQuotaEvents.h','RoydQuotaEventSource.h')
for number in ('0070','0071','0072','0075','0088'):
    patch = next((root/'android/patches/android-15.0.0_r36').glob(number+'-*.patch'))
    sections = patch.read_text().split('diff --git ')[1:]
    selected = ''.join('diff --git '+part for part in sections
                       if any(part.startswith('a/system/netd/server/'+name+' ') for name in names))
    subprocess.run(['patch','--batch','-s','--fuzz=0','-p1','-d',str(source)],
                   input=selected,text=True,check=True)
    if number == '0075':
        (output/'before-controller.cpp').write_bytes((server/'BandwidthController.cpp').read_bytes())
        (output/'before-quota.h').write_bytes((server/'RoydInterfaceQuota.h').read_bytes())
for name in names:
    if (server/name).is_file():
        (output/name).write_bytes((server/name).read_bytes())
