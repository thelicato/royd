#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
repo="$tmp/repo"
mkdir -p "$repo/android/scripts" "$repo/android/versions" "$repo/runtime/scripts" "$repo/.work"
cp "$root/build.sh" "$repo/build.sh"
printf '%s\n' 'ROYD_DEFAULT_ANDROID_VERSION=15' > "$repo/android/baseline.env"
: > "$repo/android/versions/15.env"

for forbidden in 'sed -i' 'config.mk' 'DEVICE_MANIFEST_FILE' 'PRODUCT_ENFORCE_VINTF_MANIFEST' '--disable-vintf-validation'; do
  if grep -Fq -- "$forbidden" "$root/build.sh"; then
    printf 'error: build helper contains forbidden source/VINTF mutation token: %s\n' "$forbidden" >&2
    exit 1
  fi
done

cat > "$repo/android/scripts/version-list.sh" <<'EOF_MOCK'
#!/bin/sh
printf '%s\n' 15
EOF_MOCK
cat > "$repo/android/scripts/profile.sh" <<'EOF_MOCK'
#!/bin/sh
case "${1:-}" in standard|minimal) printf '%s\n' "$1" ;; *) exit 1 ;; esac
EOF_MOCK
cat > "$repo/android/scripts/hal-profile.sh" <<'EOF_MOCK'
#!/bin/sh
case "${1:-}" in graphical|headless) printf '%s\n' "$1" ;; *) exit 1 ;; esac
EOF_MOCK
cat > "$repo/android/scripts/graphics-backend.sh" <<'EOF_MOCK'
#!/bin/sh
case "${1:-}" in software|host-gpu-generic) printf '%s\n' "$1" ;; host-gpu-intel) [ "${2:-}" = x86_64 ] && printf '%s\n' "$1" || exit 1 ;; *) exit 1 ;; esac
EOF_MOCK
cat > "$repo/android/scripts/lunch-target.sh" <<'EOF_MOCK'
#!/bin/sh
case "${1:-}" in x86_64|arm64) printf 'royd_%s-userdebug\n' "$1" ;; *) exit 1 ;; esac
EOF_MOCK
cat > "$repo/android/scripts/builder.sh" <<'EOF_MOCK'
#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
printf '%s|jobs=%s|clean=%s|version=%s|profile=%s|hal=%s|graphics=%s|tty=%s\n' \
  "$*" "${JOBS:-}" "${ROYD_CLEAN_BUILD:-}" "${ROYD_ANDROID_VERSION:-}" \
  "${ROYD_ANDROID_PROFILE:-}" "${ROYD_HAL_PROFILE:-}" "${ROYD_GRAPHICS_BACKEND:-}" \
  "${ROYD_BUILDER_TTY:-}" >> "$TEST_LOG"
case "${1:-}" in
  android/scripts/sync.sh)
    count=0
    [ ! -f "$SYNC_COUNT" ] || count=$(cat "$SYNC_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$SYNC_COUNT"
    mkdir -p "$repo/.work/android-src-${ROYD_ANDROID_VERSION}/.repo"
    if [ "${FAIL_FIRST_SYNC:-0}" = 1 ] && [ "$count" -eq 1 ]; then
      exit 1
    fi
    ;;
  android/scripts/package.sh)
    out="$repo/.work/runtime/android-${ROYD_ANDROID_VERSION}"
    mkdir -p "$out"
    suffix=
    [ "${ROYD_GRAPHICS_BACKEND}" = software ] || suffix="-${ROYD_GRAPHICS_BACKEND}"
    archive="$out/royd-${2}-${3}-${ROYD_HAL_PROFILE}${suffix}.tar"
    manifest="$out/royd-${2}-${3}-${ROYD_HAL_PROFILE}${suffix}.manifest"
    printf 'archive\n' > "$archive"
    printf 'manifest\n' > "$manifest"
    ;;
esac
EOF_MOCK
cat > "$repo/runtime/scripts/import.sh" <<'EOF_MOCK'
#!/bin/sh
printf 'import|%s|%s|version=%s|hal=%s|graphics=%s\n' "$1" "$2" "${ROYD_ANDROID_VERSION:-}" "${ROYD_HAL_PROFILE:-}" "${ROYD_GRAPHICS_BACKEND:-}" >> "$TEST_LOG"
EOF_MOCK
cat > "$repo/runtime/scripts/image-tag.sh" <<'EOF_MOCK'
#!/bin/sh
printf '%s\n' royd:test
EOF_MOCK
cat > "$repo/runtime/scripts/image-alias.sh" <<'EOF_MOCK'
#!/bin/sh
printf '%s\n' royd:dev
EOF_MOCK
chmod 0755 "$repo/build.sh" "$repo/android/scripts/"*.sh "$repo/runtime/scripts/"*.sh

mock_bin="$tmp/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/docker" <<'EOF_MOCK'
#!/bin/sh
case "${1:-}" in
  info) exit 0 ;;
  image)
    [ "${2:-}" = inspect ] || exit 1
    printf '%s\n' 'ID=sha256:test Size=1 Created=1970-01-01T00:00:00Z'
    ;;
  *) exit 1 ;;
esac
EOF_MOCK
cat > "$mock_bin/sleep" <<'EOF_MOCK'
#!/bin/sh
printf 'sleep|%s\n' "${1:-}" >> "$TEST_LOG"
EOF_MOCK
chmod 0755 "$mock_bin/docker" "$mock_bin/sleep"

TEST_LOG="$tmp/actions.log"
SYNC_COUNT="$tmp/sync-count"
export TEST_LOG SYNC_COUNT

PATH="$mock_bin:$PATH" "$repo/build.sh" --help | grep -q '^Usage: ./build.sh'

if PATH="$mock_bin:$PATH" "$repo/build.sh" --jobs 0 >/dev/null 2>&1; then
  printf '%s\n' 'error: build helper accepted zero build jobs' >&2
  exit 1
fi
if PATH="$mock_bin:$PATH" "$repo/build.sh" --arch riscv64 >/dev/null 2>&1; then
  printf '%s\n' 'error: build helper accepted an unsupported architecture' >&2
  exit 1
fi

: > "$TEST_LOG"
FAIL_FIRST_SYNC=1 PATH="$mock_bin:$PATH" "$repo/build.sh" \
  --android 15 \
  --arch x86_64 \
  --profile minimal \
  --hal-profile headless \
  --graphics host-gpu-generic \
  --jobs 7 \
  --sync-jobs 1 \
  --sync-attempts 3 \
  --sync-retry-delay 9 \
  --incremental >/dev/null

[ "$(cat "$SYNC_COUNT")" = 2 ] || {
  printf '%s\n' 'error: build helper did not retry the failed sync exactly once' >&2
  exit 1
}
grep -q '^sleep|9$' "$TEST_LOG" || {
  printf '%s\n' 'error: build helper did not honour the sync retry delay' >&2
  exit 1
}
grep -q '^android/scripts/sync.sh|jobs=1|clean=0|version=15|profile=minimal|hal=headless|graphics=host-gpu-generic|tty=never$' "$TEST_LOG" || {
  printf '%s\n' 'error: sync selection was not forwarded correctly' >&2
  exit 1
}
grep -q '^android/scripts/config-check.sh x86_64|jobs=7|clean=0|version=15|profile=minimal|hal=headless|graphics=host-gpu-generic|tty=never$' "$TEST_LOG" || {
  printf '%s\n' 'error: config-check selection was not forwarded correctly' >&2
  exit 1
}
grep -q '^android/scripts/build.sh x86_64 minimal|jobs=7|clean=0|version=15|profile=minimal|hal=headless|graphics=host-gpu-generic|tty=never$' "$TEST_LOG" || {
  printf '%s\n' 'error: incremental build selection was not forwarded correctly' >&2
  exit 1
}
grep -q '^import|x86_64|minimal|version=15|hal=headless|graphics=host-gpu-generic$' "$TEST_LOG" || {
  printf '%s\n' 'error: image import selection was not forwarded correctly' >&2
  exit 1
}
[ -f "$repo/.work/logs/android15-x86_64-minimal-headless-host-gpu-generic.log" ] || {
  printf '%s\n' 'error: build helper did not write the expected log' >&2
  exit 1
}

: > "$TEST_LOG"
PATH="$mock_bin:$PATH" "$repo/build.sh" --android 15 --arch x86_64 --jobs 2 --skip-sync --clean >/dev/null
if grep -q '^android/scripts/sync.sh|' "$TEST_LOG"; then
  printf '%s\n' 'error: --skip-sync still invoked source synchronisation' >&2
  exit 1
fi
grep -q '^android/scripts/build.sh x86_64 standard|jobs=2|clean=1|version=15|profile=standard|hal=graphical|graphics=software|tty=never$' "$TEST_LOG" || {
  printf '%s\n' 'error: clean build defaults or forwarding are incorrect' >&2
  exit 1
}

rm -rf "$repo/.work/android-src-15/.repo"
if PATH="$mock_bin:$PATH" "$repo/build.sh" --android 15 --skip-sync --jobs 1 >/dev/null 2>&1; then
  printf '%s\n' 'error: --skip-sync accepted a missing source checkout' >&2
  exit 1
fi

printf '%s\n' 'build helper tests passed'
