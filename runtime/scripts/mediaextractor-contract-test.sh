#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
jq -n '{uid:10096,pid:1234,done:true,status:"pass",rounds:[range(1;6)|{round:.,duration_ms:250,tracks:[{type:2}]}]}' >"$tmp/good.json"
"$root/runtime/scripts/mediaextractor-assess.sh" "$tmp/good.json" 10096 1234 >/dev/null
for change in '.uid=0' '.pid=0' '.done=false' '.status="fail"' '.error="retained failure"' \
    '.rounds=[]' '.rounds[2].round=1' '.rounds[0].duration_ms=0' '.rounds[0].tracks=[]' '.rounds[0].tracks[0].type=1'; do
  jq "$change" "$tmp/good.json" >"$tmp/bad.json"
  if "$root/runtime/scripts/mediaextractor-assess.sh" "$tmp/bad.json" 10096 1234 >/dev/null 2>&1; then
    printf 'error: media observation accepted invalid data: %s\n' "$change" >&2
    exit 1
  fi
done
! grep -Eq 'uses-permission|sharedUserId' "$root/runtime/tests/mediaextractor/AndroidManifest.xml"
printf '%s\n' 'Ordinary-UID media observation, missing audio and retained error contracts passed'
