#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

cat > "$tmp/docker" <<'MOCK'
#!/bin/sh
set -eu
if [ "$1 $2" = "image inspect" ]; then
  format=$4
  case "$format" in
    '{{.Architecture}}') printf '%s\n' amd64 ;;
    '{{json .Config.Entrypoint}}') printf '%s\n' '["/init","androidboot.hardware=royd"]' ;;
    *org.royd.image-format*) printf '%s\n' 1 ;;
    *org.royd.android-ref*) printf '%s\n' android-15.0.0_r36 ;;
    *org.royd.image-profile*) printf '%s\n' standard ;;
    *org.royd.arch*) printf '%s\n' x86_64 ;;
    *org.opencontainers.image.title*) printf '%s\n' royd ;;
    *) printf 'unexpected inspect format: %s\n' "$format" >&2; exit 1 ;;
  esac
  exit 0
fi
if [ "$1" = create ]; then
  printf '%s\n' mock-container
  exit 0
fi
if [ "$1" = cp ]; then
  mkdir -p "$MOCK_RELEASE_DIR"
  cat > "$MOCK_RELEASE_DIR/royd-release" <<'REL'
ROYD_IMAGE_FORMAT=1
ROYD_AOSP_TAG=android-15.0.0_r36
ROYD_ARCH=x86_64
ROYD_IMAGE_PROFILE=standard
ANDROID_PRODUCT=royd_x86_64
REL
  tar -C "$MOCK_RELEASE_DIR" -cf - royd-release
  exit 0
fi
if [ "$1" = rm ]; then
  exit 0
fi
printf 'unexpected docker command: %s\n' "$*" >&2
exit 1
MOCK
chmod +x "$tmp/docker"
mkdir -p "$tmp/release"
PATH="$tmp:$PATH" MOCK_RELEASE_DIR="$tmp/release" "$script_dir/image-inspect.sh" x86_64 standard royd:test >/dev/null

[ "$($script_dir/image-tag.sh x86_64 standard)" = 'royd:15.0.0-r36-standard-amd64' ]
[ "$($script_dir/image-tag.sh arm64 minimal)" = 'royd:15.0.0-r36-minimal-arm64' ]
[ "$($script_dir/image-alias.sh x86_64 standard)" = 'royd:dev' ]
[ "$($script_dir/image-alias.sh arm64 minimal)" = 'royd:dev-minimal-arm64' ]
printf '%s\n' 'Runtime image contract test passed'
