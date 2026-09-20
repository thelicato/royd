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
    '{{json .Config.Entrypoint}}') printf '%s\n' '["/royd-entrypoint"]' ;;
    '{{json .Config.Cmd}}') printf '%s\n' '["royd.width=540","royd.height=960","royd.dpi=240","royd.fps=30"]' ;;
    '{{json .Config.Healthcheck.Test}}') printf '%s\n' '["CMD","/vendor/bin/royd-health"]' ;;
    '{{json .Config.ExposedPorts}}') printf '%s\n' '{"5555/tcp":{}}' ;;
    *org.royd.image-format*) printf '%s\n' 3 ;;
    *org.royd.android-version*) printf '%s\n' 15 ;;
    *org.royd.android-ref*) printf '%s\n' android-15.0.0_r36 ;;
    *org.royd.image-profile*) printf '%s\n' standard ;;
    *org.royd.profile-policy-sha256*) printf '%s\n' e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ;;
    *org.royd.profile-policy*) printf '%s\n' standard-v1 ;;
    *org.royd.hal-profile*) printf '%s\n' graphical ;;
    *org.royd.graphics-backend*) printf '%s\n' software ;;
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
ROYD_IMAGE_FORMAT=3
ROYD_ANDROID_VERSION=15
ROYD_AOSP_TAG=android-15.0.0_r36
ROYD_ARCH=x86_64
ROYD_IMAGE_PROFILE=standard
ROYD_PROFILE_POLICY=standard-v1
ROYD_PROFILE_POLICY_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
ROYD_HAL_PROFILE=graphical
ROYD_GRAPHICS_BACKEND=software
ROYD_RUNTIME_ENTRYPOINT=/royd-entrypoint
ROYD_RUNTIME_CONFIG=/royd-runtime.conf
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

[ "$(ROYD_ANDROID_VERSION=8.0 $script_dir/image-tag.sh x86_64 standard)" = 'royd:8.0.0-r36-standard-graphical-amd64' ]
[ "$(ROYD_ANDROID_VERSION=8.1 $script_dir/image-tag.sh x86_64 standard)" = 'royd:8.1.0-r81-standard-graphical-amd64' ]
[ "$(ROYD_ANDROID_VERSION=9 $script_dir/image-tag.sh x86_64 standard)" = 'royd:9.0.0-r61-standard-graphical-amd64' ]
[ "$(ROYD_ANDROID_VERSION=10 $script_dir/image-tag.sh x86_64 standard)" = 'royd:10.0.0-r47-standard-graphical-amd64' ]
[ "$(ROYD_ANDROID_VERSION=13 $script_dir/image-tag.sh arm64 standard)" = 'royd:13.0.0-r75-standard-graphical-arm64' ]
[ "$($script_dir/image-tag.sh x86_64 standard)" = 'royd:15.0.0-r36-standard-graphical-amd64' ]
[ "$(ROYD_ANDROID_VERSION=14 $script_dir/image-tag.sh x86_64 standard)" = 'royd:14.0.0-r14-standard-graphical-amd64' ]
[ "$(ROYD_ANDROID_VERSION=16 $script_dir/image-tag.sh arm64 minimal)" = 'royd:16.0.0-r4-minimal-graphical-arm64' ]
[ "$(ROYD_ANDROID_VERSION=17 $script_dir/image-tag.sh x86_64 standard)" = 'royd:17.0.0-r1-standard-graphical-amd64' ]
[ "$($script_dir/image-tag.sh arm64 minimal)" = 'royd:15.0.0-r36-minimal-graphical-arm64' ]
[ "$(ROYD_ANDROID_VERSION=8.0 $script_dir/image-alias.sh x86_64 standard)" = 'royd:dev-8.0' ]
[ "$(ROYD_ANDROID_VERSION=8.1 $script_dir/image-alias.sh x86_64 standard)" = 'royd:dev-8.1' ]
[ "$(ROYD_ANDROID_VERSION=10 $script_dir/image-alias.sh arm64 standard)" = 'royd:dev-10-arm64' ]
[ "$(ROYD_ANDROID_VERSION=13 $script_dir/image-alias.sh x86_64 minimal)" = 'royd:dev-13-minimal' ]
[ "$($script_dir/image-alias.sh x86_64 standard)" = 'royd:dev' ]
[ "$(ROYD_ANDROID_VERSION=14 $script_dir/image-alias.sh x86_64 standard)" = 'royd:dev-14' ]
[ "$(ROYD_ANDROID_VERSION=16 $script_dir/image-alias.sh arm64 standard)" = 'royd:dev-16-arm64' ]
[ "$(ROYD_ANDROID_VERSION=17 $script_dir/image-alias.sh x86_64 minimal)" = 'royd:dev-17-minimal' ]
[ "$($script_dir/image-alias.sh arm64 minimal)" = 'royd:dev-minimal-arm64' ]

[ "$(ROYD_HAL_PROFILE=headless $script_dir/image-tag.sh x86_64 standard)" = 'royd:15.0.0-r36-standard-headless-amd64' ]
[ "$(ROYD_HAL_PROFILE=headless $script_dir/image-alias.sh x86_64 standard)" = 'royd:dev-headless' ]

[ "$(ROYD_GRAPHICS_BACKEND=host-gpu-generic $script_dir/image-tag.sh x86_64 standard)" = 'royd:15.0.0-r36-standard-graphical-host-gpu-generic-amd64' ]
[ "$(ROYD_GRAPHICS_BACKEND=host-gpu-generic $script_dir/image-alias.sh x86_64 standard)" = 'royd:dev-host-gpu-generic' ]
[ "$(ROYD_GRAPHICS_BACKEND=host-gpu-intel $script_dir/image-tag.sh x86_64 standard)" = 'royd:15.0.0-r36-standard-graphical-host-gpu-intel-amd64' ]
[ "$(ROYD_GRAPHICS_BACKEND=host-gpu-intel $script_dir/image-alias.sh x86_64 standard)" = 'royd:dev-host-gpu-intel' ]
printf '%s\n' 'Runtime image contract test passed'
