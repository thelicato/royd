#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

cat > "$tmp/docker" <<'MOCK'
#!/bin/sh
set -eu
if [ "$1 $2" != 'image inspect' ]; then
  printf 'unexpected docker command: %s\n' "$*" >&2
  exit 1
fi
[ "${MOCK_MISSING_POLICY:-0}" = 0 ] || missing_policy=1
if [ "$#" -eq 3 ]; then
  exit 0
fi
format=$4
case "$format" in
  '{{.Id}}') printf '%s\n' sha256:benchmark-image ;;
  *org.royd.android-version*) printf '%s\n' 15 ;;
  *org.royd.android-ref*) printf '%s\n' android-15.0.0_r36 ;;
  *org.royd.image-profile*) printf '%s\n' minimal ;;
  *org.royd.profile-policy-sha256*)
    if [ "${missing_policy:-0}" = 1 ]; then printf '%s\n' '<no value>'; else printf '%s\n' 0123456789abcdef; fi
    ;;
  *org.royd.profile-policy*) printf '%s\n' minimal-v2-modern ;;
  *org.royd.hal-profile*) printf '%s\n' graphical ;;
  *org.royd.graphics-backend*) printf '%s\n' software ;;
  *) printf 'unexpected inspect format: %s\n' "$format" >&2; exit 1 ;;
esac
MOCK
chmod +x "$tmp/docker"

output=$(PATH="$tmp:$PATH" "$script_dir/memory-provenance.sh" royd:test compact)
printf '%s\n' "$output" | grep -Fq -- '- image ID: `sha256:benchmark-image`'
printf '%s\n' "$output" | grep -Fq -- '- Android image profile: `minimal`'
printf '%s\n' "$output" | grep -Fq -- '- image profile policy: `minimal-v2-modern`'
printf '%s\n' "$output" | grep -Fq -- '- runtime display profile: `compact` (360x640, 160 dpi, 30 fps)'

if PATH="$tmp:$PATH" MOCK_MISSING_POLICY=1 "$script_dir/memory-provenance.sh" royd:test compact >/dev/null 2>&1; then
  printf '%s\n' 'error: benchmark provenance accepted an image without a profile-policy digest' >&2
  exit 1
fi

printf '%s\n' 'Memory benchmark provenance contract test passed'
