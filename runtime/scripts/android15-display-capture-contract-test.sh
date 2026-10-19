#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
real_mktemp=$(command -v mktemp)

cat >"$tmp/bin/mktemp" <<'MOCK'
#!/bin/sh
set -eu
if [ "$MOCK_CASE" = unsafe_reservation ]; then
  printf '%s\n' "$MOCK_STATE/unrelated"
  exit 0
fi
reservation=$("$MOCK_MKTEMP" "$@")
capture=$MOCK_STATE/Movies/${reservation##*/}.mp4
printf '%s\n' "$capture" >"$MOCK_STATE/capture.path"
if [ "$MOCK_CASE" = collision ]; then printf '%s\n' 'preserve collision' >"$capture"; fi
printf '%s\n' "$reservation"
MOCK
cat >"$tmp/bin/timeout" <<'MOCK'
#!/bin/sh
case "$1:$2" in 5:cmd|10:screenrecord|5:content) ;; *) exit 98 ;; esac
shift
exec "$@"
MOCK
cat >"$tmp/bin/cmd" <<'MOCK'
#!/bin/sh
[ "$*" = 'power wakeup' ] || exit 98
[ "$MOCK_CASE" != wake_failure ]
MOCK
cat >"$tmp/bin/screenrecord" <<'MOCK'
#!/bin/sh
set -eu
expected=$(cat "$MOCK_STATE/capture.path")
[ "$*" = "--display-id 0 --size 544x960 --time-limit 2 $expected" ] || exit 98
case "$MOCK_CASE" in
  record_failure) exit 1 ;;
  empty) exit 0 ;;
esac
printf 'encoded-frames' >"$expected"
case "$MOCK_CASE" in
  partial_failure) exit 1 ;;
  interrupted) kill -TERM "$PPID"; exit 143 ;;
esac
MOCK
cat >"$tmp/bin/content" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_STATE/content.log"
[ "$BOOTCLASSPATH" = /apex/test/core.jar ]
[ "$DEX2OATBOOTCLASSPATH" = /apex/test/core.jar ]
[ "$ANDROID_DATA:$ANDROID_STORAGE" = /data:/storage ]
operation=$1
shift
uri=
projection=
selection=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --user) [ "$2" = 0 ] ;;
    --uri) uri=$2 ;;
    --projection) projection=$2 ;;
    --where) selection=$2 ;;
    *) exit 98 ;;
  esac
  shift 2
done
capture=$(cat "$MOCK_STATE/capture.path")
[ "$selection" = "_data='$capture'" ] || exit 98
case "$operation:$uri" in
  delete:content://media/external_primary/file)
    case "$MOCK_CASE" in
      delete_failure) exit 1 ;;
      delete_error_output) printf '%s\n' 'Error while accessing provider:media'; exit 0 ;;
    esac
    rm -f "$capture"
    : >"$MOCK_STATE/deleted"
    ;;
  query:content://media/external_primary/file)
    [ "$projection" = _id ] || exit 98
    if [ "$MOCK_CASE" = stale_row ]; then printf '%s\n' 'Row: 0 _id=42';
    else printf '%s\n' 'No result found.'; fi
    ;;
  query:content://media/external_primary/video/media)
    [ "$projection" = _id:_size:width:height:mime_type ] || exit 98
    count=$(cat "$MOCK_STATE/queries"); count=$((count + 1)); printf '%s\n' "$count" >"$MOCK_STATE/queries"
    case "$MOCK_CASE" in
      query_failure) exit 1 ;;
      query_timeout) exit 124 ;;
      query_error_output) printf '%s\n' 'Error while accessing provider:media'; exit 0 ;;
      unindexed) printf '%s\n' 'No result found.'; exit 0 ;;
      delayed) if [ "$count" -lt 3 ]; then printf '%s\n' 'No result found.'; exit 0; fi ;;
    esac
    id=42
    size=$(wc -c <"$capture" | tr -d ' ')
    width=544
    height=960
    mime=video/mp4
    case "$MOCK_CASE" in
      wrong_id) id=0 ;;
      wrong_size) size=999 ;;
      wrong_width) width=540 ;;
      wrong_height) height=961 ;;
      wrong_mime) mime=application/octet-stream ;;
      missing_metadata) width=NULL ;;
    esac
    printf 'Row: 0 _id=%s, _size=%s, width=%s, height=%s, mime_type=%s\n' "$id" "$size" "$width" "$height" "$mime"
    if [ "$MOCK_CASE" = extra_row ]; then printf '%s\n' 'Row: 1 _id=43'; fi
    ;;
  *) exit 98 ;;
esac
MOCK
printf '%s\n' '#!/bin/sh' 'exit 0' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/"*

for mode in good delayed wake_failure record_failure partial_failure empty interrupted \
    query_failure query_timeout query_error_output unindexed wrong_id wrong_size \
    wrong_width wrong_height wrong_mime missing_metadata extra_row delete_failure \
    delete_error_output stale_row collision unsafe_reservation missing_classpath missing_dex2oat \
    missing_movies invalid_dimensions; do
  state=$tmp/$mode
  mkdir -p "$state/private" "$state/Movies" "$state/unrelated"
  printf '%s\n' keep >"$state/Movies/keep.mp4"
  printf '%s\n' keep >"$state/unrelated/keep"
  printf '%s\n' 0 >"$state/queries"
  printf '%s\n' 'export BOOTCLASSPATH /apex/test/core.jar' \
    'export DEX2OATBOOTCLASSPATH /apex/test/core.jar' >"$state/classpath"
  if [ "$mode" = missing_classpath ]; then : >"$state/classpath"; fi
  if [ "$mode" = missing_dex2oat ]; then sed -i '/DEX2OAT/d' "$state/classpath"; fi
  if [ "$mode" = missing_movies ]; then mv "$state/Movies" "$state/preserved-movies"; fi
  # Only fixed filesystem roots change; execute the production shell otherwise.
  sed -e "s|/data/system/environ/classpath|$state/classpath|g" \
    -e "s|/storage/emulated/0/Movies|$state/Movies|g" \
    -e "s|private_root=/data/local/tmp|private_root=$state/private|g" \
    "$script_dir/android15-display-capture.sh" >"$state/capture.sh"
  width=544
  [ "$mode" != invalid_dimensions ] || width=invalid
  status=0
  PATH="$tmp/bin:$PATH" MOCK_CASE="$mode" MOCK_STATE="$state" MOCK_MKTEMP="$real_mktemp" \
    sh "$state/capture.sh" "$width" 960 >"$state/output" 2>&1 || status=$?
  case "$mode" in
    good|delayed)
      [ "$status" -eq 0 ]
      grep -Fq 'Display capture passed: 544x960, 14 bytes, MediaStore row=42; cleaned' "$state/output"
      test -e "$state/deleted"
      if [ "$mode" = delayed ]; then [ "$(cat "$state/queries")" = 3 ]; fi
      ;;
    *)
      [ "$status" -ne 0 ] || { printf 'error: display capture accepted %s\n' "$mode" >&2; exit 1; }
      ! grep -Fq 'Display capture passed:' "$state/output"
      ;;
  esac
  if [ "$mode" = interrupted ]; then [ "$status" -eq 143 ]; fi
  if [ "$mode" = unindexed ]; then [ "$(cat "$state/queries")" = 10 ]; fi
  [ "$(cat "$state/unrelated/keep")" = keep ]
  if [ "$mode" = missing_movies ]; then
    [ "$(cat "$state/preserved-movies/keep.mp4")" = keep ]
  else
    [ "$(cat "$state/Movies/keep.mp4")" = keep ]
  fi
  if [ -e "$state/capture.path" ]; then
    capture=$(cat "$state/capture.path")
    if [ "$mode" = collision ]; then
      [ "$(cat "$capture")" = 'preserve collision' ]
      test ! -e "$state/content.log"
    else [ ! -e "$capture" ]; fi
  fi
  [ -z "$(ls -A "$state/private")" ]
done
printf '%s\n' 'Android 15 display capture/MediaStore contract passed (27 cases)'
