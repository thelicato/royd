#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" "${ROYD_ANDROID15_SETTINGS_PRINTING_SOURCE:-}" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:3])
sys.dont_write_bytecode=True
sys.path.insert(0,str(root/'android/tests/fixtures/android15'))
from SettingsSearchPatchFixture import sources,method
patch=root/'android/patches/android-15.0.0_r36/0084-settings-respect-printing-availability.patch'
old=sources(patch);new=sources(patch,after=True);assert len(new)==1
name=next(iter(new))
if sys.argv[3]:new[name]=(Path(sys.argv[3])/name).read_text()
added='\n'.join(line[1:] for line in patch.read_text().splitlines() if line.startswith('+') and not line.startswith('+++'))
assert not any(word in added for word in ['catch ', 'Log.', 'Slog.', 'setUiRestricted', 'setRestrictionKey'])
assert 'super(UserManager.DISALLOW_PRINTING);' in new[name]
methods=['PrintSettingsFragment','onAttach','onCreateView','onViewCreated','onStart','setupPreferences','setupEmptyViews','startSettings','onClick']
classes=[]
for target,source in [('Fragment',new[name]),('StockFragment',old[name])]:
    body='static class '+target+' extends BaseFragment {\n'
    if target=='Fragment':body+='boolean mPrintingUnavailable;\n'
    for key in methods:
        text=method(source,key)
        if key=='PrintSettingsFragment':text=text.replace(key+'(',target+'(',1)
        body+=text+'\n'
    classes.append(body+'}\n')
provider='static class Provider extends BaseSearchIndexProvider {\nProvider(){super(R.xml.print_settings);}\n'
provider+='\n'.join(method(new[name],key) for key in ['getXmlResourcesToIndex','isPageSearchEnabled'])+'\n}\n'
helper_source=sources(root/'android/patches/android-15.0.0_r36/0078-settings-respect-optional-service-availability.patch',after=True)
helper=method(helper_source['packages/apps/Settings/src/com/android/settings/Utils.java'],'isRoydHardwareUnavailable')
if sys.argv[3]:helper=method((Path(sys.argv[3])/'packages/apps/Settings/src/com/android/settings/Utils.java').read_text(),'isRoydHardwareUnavailable')
template=(root/'android/tests/fixtures/android15/SettingsPrintingAvailabilityContract.java').read_text()
for marker,replacement in {'// INSERT_ACTUAL_CAPABILITY_HELPER':helper,'// INSERT_ACTUAL_FRAGMENT_CLASSES':'\n'.join(classes),'// INSERT_ACTUAL_PROVIDER_CLASSES':provider}.items():
    assert template.count(marker)==1;template=template.replace(marker,replacement)
(out/'SettingsPrintingAvailabilityTest.java').write_text(template)
PY
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/SettingsPrintingAvailabilityTest.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" SettingsPrintingAvailabilityTest
else
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for Printing contracts'
fi
printf '%s\n' 'Android 15 Settings Printing availability contracts passed'
