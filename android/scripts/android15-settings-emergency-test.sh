#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

# Evaluate the real product fragment. Version metadata is not yet available at
# this point in product inheritance, so selection must use the upstream SDK.
for sdk in 26 27 28 29 30 31 32 33 34 35 36 37; do
  overlays=$(make -s --no-print-directory -f - PLATFORM_SDK_VERSION="$sdk" <<EOF_MAKE
include $root/android/royd/device/royd/container_common.mk
all:
	@echo \$(PRODUCT_PACKAGE_OVERLAYS)
EOF_MAKE
  )
  if [ "$sdk" = 35 ]; then
    [ "$overlays" = device/royd/overlay/android15 ]
  else
    [ -z "$overlays" ]
  fi
done

python3 - "$root" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root = Path(sys.argv[1])
settings = root / 'android/royd/device/royd/overlay/android15/packages/apps/Settings/res'
config = ET.parse(settings / 'values/config.xml').getroot()
assert config.tag == 'resources'
assert len(config) == 1
flag = config[0]
assert flag.tag == 'bool' and flag.attrib == {'name': 'config_show_emergency_gesture_settings'}
assert (flag.text or '').strip() == 'false'

# A false availability flag alone is insufficient: DashboardFragment calls
# displayPreference even on unavailable controllers during a forced page load.
# The replacement page must never instantiate those provider-backed controls.
android = '{http://schemas.android.com/apk/res/android}'
page = ET.parse(settings / 'xml/emergency_gesture_settings.xml').getroot()
assert page.tag == 'PreferenceScreen'
assert page.attrib == {android + 'title': '@string/emergency_gesture_screen_title'}
assert len(page) == 1
notice = page[0]
assert notice.tag == 'Preference' and len(notice) == 0
assert notice.attrib == {
    android + 'key': 'emergency_gesture_unavailable',
    android + 'title': '@string/device_info_not_available',
    android + 'selectable': 'false',
}
assert {p.relative_to(settings).as_posix() for p in settings.rglob('*') if p.is_file()} == {
    'values/config.xml', 'xml/emergency_gesture_settings.xml',
}
PY
printf '%s\n' 'Android 15 emergency Settings product/forced-link contracts passed'
