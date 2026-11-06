#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
python3 - "$root" "$tmp" "${ROYD_ANDROID15_SETTINGS_SAVED_SOURCE:-}" <<'PY'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:3])
sys.dont_write_bytecode=True
sys.path.insert(0,str(root/'android/tests/fixtures/android15'))
from SettingsSearchPatchFixture import sources,method
patch=root/'android/patches/android-15.0.0_r36/0083-settings-skip-unavailable-saved-bluetooth.patch'
old=sources(patch);new=sources(patch,after=True)
assert len(new)==2 and old.keys()==new.keys()
if sys.argv[3]:new={name:(Path(sys.argv[3])/name).read_text() for name in new}
added='\n'.join(line[1:] for line in patch.read_text().splitlines() if line.startswith('+') and not line.startswith('+++'))
assert not any(word in added for word in ['catch ', 'Log.', 'Slog.', 'setVisible', 'return AVAILABLE'])
classes=[]
for name in new:
    original=Path(name).stem
    short='Previously' if original.startswith('Previously') else 'Saved'
    for target,source in [(short,new[name]),('Stock'+short,old[name])]:
        body=source[source.index('public class '+original):]
        body=body.replace(original,target).replace('public class '+target,'static class '+target,1)
        classes.append(body)
helper_source=sources(root/'android/patches/android-15.0.0_r36/0078-settings-respect-optional-service-availability.patch',after=True)
helper=method(helper_source['packages/apps/Settings/src/com/android/settings/Utils.java'],'isRoydHardwareUnavailable')
if sys.argv[3]:helper=method((Path(sys.argv[3])/'packages/apps/Settings/src/com/android/settings/Utils.java').read_text(),'isRoydHardwareUnavailable')
template=(root/'android/tests/fixtures/android15/SettingsSavedBluetoothControllerContract.java').read_text()
for marker,replacement in {'// INSERT_ACTUAL_CAPABILITY_HELPER':helper,'// INSERT_ACTUAL_CONTROLLER_CLASSES':'\n'.join(classes)}.items():
    assert template.count(marker)==1;template=template.replace(marker,replacement)
(out/'SettingsSavedBluetoothControllerTest.java').write_text(template)
PY
if [ -n "${ROYD_TEST_JAVA_HOME:-}" ]; then
  "$ROYD_TEST_JAVA_HOME/bin/javac" -d "$tmp" "$tmp/SettingsSavedBluetoothControllerTest.java"
  "$ROYD_TEST_JAVA_HOME/bin/java" -cp "$tmp" SettingsSavedBluetoothControllerTest
else
  printf '%s\n' 'Java execution skipped: set ROYD_TEST_JAVA_HOME for saved-device contracts'
fi
printf '%s\n' 'Android 15 Settings saved-Bluetooth controller contracts passed'
