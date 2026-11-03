#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" "${ROYD_ANDROID15_SETTINGS_HEARING_SOURCE:-}" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:3])
sys.dont_write_bytecode=True
sys.path.insert(0,str(root/'android/tests/fixtures/android15'))
from SettingsSearchPatchFixture import sources,method
patch=root/'android/patches/android-15.0.0_r36/0080-settings-respect-hearing-aid-controller-availability.patch'
old=sources(patch);new=sources(patch,after=True)
assert len(new)==1
name=next(iter(new))
if sys.argv[3]:new[name]=(Path(sys.argv[3])/name).read_text()
added=[line[1:] for line in patch.read_text().splitlines() if line.startswith('+') and not line.startswith('+++')]
assert not any(word in '\n'.join(added) for word in ['catch ', 'Log.', 'Slog.', 'ServiceManager'])
assert 'private final boolean mBluetoothUnavailable;' in new[name]
helper_source=sources(root/'android/patches/android-15.0.0_r36/0078-settings-respect-optional-service-availability.patch',after=True)
helper=method(helper_source['packages/apps/Settings/src/com/android/settings/Utils.java'],'isRoydHardwareUnavailable')
if sys.argv[3]:helper=method((Path(sys.argv[3])/'packages/apps/Settings/src/com/android/settings/Utils.java').read_text(),'isRoydHardwareUnavailable')
methods=['AccessibilityHearingAidPreferenceController','displayPreference','getAvailabilityStatus','onStart','onStop','handlePreferenceTreeClick','refreshSummary','onActiveDeviceChanged','onServiceConnected','setFragmentManager']
classes=[]
for classname,source in [('Controller',new[name]),('StockController',old[name])]:
    body='static class '+classname+' extends Base {\n'
    if classname=='Controller':body+='final boolean mBluetoothUnavailable;\n'
    body+='final LocalBluetoothManager mLocalBluetoothManager;\nfinal LocalBluetoothProfileManager mProfileManager;\nfinal HearingAidHelper mHelper;\n'
    for key in methods:
        text=method(source,key)
        if key==methods[0]:text=text.replace(key+'(',classname+'(',1)
        body+=text+'\n'
    classes.append(body+'}\n')
template=(root/'android/tests/fixtures/android15/SettingsHearingAidControllerContract.java').read_text()
for marker,replacement in {'// INSERT_ACTUAL_CAPABILITY_HELPER':helper,'// INSERT_ACTUAL_CONTROLLER_CLASSES':'\n'.join(classes)}.items():
    assert template.count(marker)==1;template=template.replace(marker,replacement)
(out/'SettingsHearingAidControllerTest.java').write_text(template)
PY
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/SettingsHearingAidControllerTest.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" SettingsHearingAidControllerTest
fi
printf '%s\n' 'Android 15 Settings hearing-aid controller contracts passed'
