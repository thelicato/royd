#!/bin/sh
# Executed inside booted Android by assert-runtime.sh, not installed in the image.
set -eu

[ "$#" -eq 2 ] || exit 2
width=$1
height=$2
for value in "$width" "$height"; do
  case "$value" in ''|*[!0-9]*|0) exit 2 ;; esac
done

# Docker exec does not inherit init's Java-tool environment. Read data, not code.
export ANDROID_DATA=/data ANDROID_ROOT=/system ANDROID_STORAGE=/storage
export ANDROID_ART_ROOT=/apex/com.android.art ANDROID_I18N_ROOT=/apex/com.android.i18n
export ANDROID_TZDATA_ROOT=/apex/com.android.tzdata
BOOTCLASSPATH=$(sed -n 's/^export BOOTCLASSPATH //p' /data/system/environ/classpath)
DEX2OATBOOTCLASSPATH=$(sed -n 's/^export DEX2OATBOOTCLASSPATH //p' /data/system/environ/classpath)
[ -n "$BOOTCLASSPATH" ] && [ -n "$DEX2OATBOOTCLASSPATH" ] || exit 1
export BOOTCLASSPATH DEX2OATBOOTCLASSPATH

media_root=/storage/emulated/0/Movies
private_root=/data/local/tmp
test -d "$media_root"
reservation=$(mktemp -d "$private_root/royd-runtime-video-test.XXXXXX")
case "$reservation" in "$private_root"/royd-runtime-video-test.??????) ;; *) exit 1 ;; esac
leaf=${reservation##*/}
case "$leaf" in *[!A-Za-z0-9.-]*) exit 1 ;; esac
capture=$media_root/$leaf.mp4
owned=0
files_uri=content://media/external_primary/file
selection="_data='$capture'"

cleanup_capture() {
  cleanup_status=0
  if [ "$owned" = 1 ]; then
    # content can return zero after a provider exception, so inspect its output.
    response=$(timeout 5 content delete --user 0 --uri "$files_uri" --where "$selection" 2>&1) || cleanup_status=1
    if [ -n "$response" ]; then
      printf 'error: capture MediaStore deletion: %s\n' "$response" >&2
      cleanup_status=1
    fi
    rm -f "$capture" || cleanup_status=1
    response=$(timeout 5 content query --user 0 --uri "$files_uri" --projection _id --where "$selection" 2>&1) || cleanup_status=1
    if [ "$response" != 'No result found.' ] || [ -e "$capture" ]; then
      printf 'error: capture cleanup is incomplete: %s\n' "$response" >&2
      cleanup_status=1
    fi
    owned=0
  fi
  if [ -n "$reservation" ]; then
    rmdir "$reservation" || cleanup_status=1
    reservation=
  fi
  return "$cleanup_status"
}
on_exit() {
  status=$?
  trap - EXIT HUP INT TERM
  cleanup_capture || status=1
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

umask 022
# Never overwrite an existing recording, even if its generated name collides.
(set -C; : > "$capture")
owned=1
timeout 5 cmd power wakeup
sleep 1
timeout 10 screenrecord --display-id 0 --size "${width}x${height}" --time-limit 2 "$capture"
test -s "$capture" || { printf '%s\n' 'error: display capture is empty' >&2; exit 1; }

# screenrecord always requests an asynchronous scan. Keep the file until its
# video metadata is indexed, then delete through MediaStore and verify cleanup.
indexed=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  row=$(timeout 5 content query --user 0 --uri content://media/external_primary/video/media \
    --projection _id:_size:width:height:mime_type --where "$selection" 2>&1) || {
    printf 'error: capture metadata query: %s\n' "$row" >&2; exit 1;
  }
  if [ "$row" != 'No result found.' ]; then
    [ "$(printf '%s\n' "$row" | wc -l)" -eq 1 ] || {
      printf 'error: unexpected capture metadata: %s\n' "$row" >&2; exit 1;
    }
    metadata=$(printf '%s\n' "$row" | sed -n \
      "s|^Row: 0 _id=\([0-9][0-9]*\), _size=\([0-9][0-9]*\), width=$width, height=$height, mime_type=video/mp4$|\1 \2|p")
    if [ -n "$metadata" ]; then
      # Splitting is safe: the parser emits exactly two decimal numbers.
      set -- $metadata
      if [ "$1" -gt 0 ] && [ "$2" -gt 0 ] && [ "$2" = "$(stat -c %s "$capture")" ]; then
        indexed=1
        break
      fi
    fi
  fi
  sleep 1
done
[ "$indexed" = 1 ] || {
  printf 'error: capture video metadata was not indexed: %s\n' "$row" >&2; exit 1;
}
capture_id=$1
capture_bytes=$2
cleanup_capture
printf 'Display capture passed: %sx%s, %s bytes, MediaStore row=%s; cleaned\n' \
  "$width" "$height" "$capture_bytes" "$capture_id"
