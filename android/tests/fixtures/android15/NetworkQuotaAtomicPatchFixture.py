#!/usr/bin/env python3
"""Merge exact new patch context into the sparse sync fixture preimage."""
from pathlib import Path
import sys
from SettingsSearchPatchFixture import sources
for name,text in sources(Path(sys.argv[1]),prefixes=('frameworks/base/services/core/java/com/android/server/net/',)).items():
 target=Path(name);existing=target.read_text() if target.exists() else ''
 markers=('private static boolean shouldUseRoydOciQuotaReplacement()',
          'final boolean roydReplace = exists && quotaBytes > 0',
          'royd interface quota replacement: mode=atomic used=') if target.name=='NetworkManagementService.java' else (
          'if (!mObserveRoydEthernetStats || !"eth0".equals(val.iface))',)
 if all(marker in existing for marker in markers):continue
 assert not any(marker in existing for marker in markers),(name,'partial postimage')
 if target.name=='NetworkPolicyManagerService.java' and 'case MSG_UPDATE_INTERFACE_QUOTAS: {' in existing:
  # A later shared fixture has already reconstructed and reversed this exact case.
  start=text.index('case MSG_UPDATE_INTERFACE_QUOTAS: {')
  end=text.index('case MSG_REMOVE_INTERFACE_QUOTAS:',start)
  assert text[start:end].strip() in existing,(name,'different preimage')
  continue
 rows=existing.splitlines()
 incoming=text.splitlines();rows.extend(['']*max(0,len(incoming)-len(rows)))
 for number,line in enumerate(incoming):
  if line:
   assert not rows[number] or rows[number]==line,(name,number)
   rows[number]=line
 target.parent.mkdir(parents=True,exist_ok=True);target.write_text('\n'.join(rows)+'\n')
