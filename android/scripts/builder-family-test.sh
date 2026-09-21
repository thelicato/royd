#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/bin" "$tmp/work"
cat > "$tmp/bin/docker" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$ROYD_DOCKER_LOG"
MOCK
chmod +x "$tmp/bin/docker"

run_case() {
  version=$1
  expected=$2
  : > "$tmp/docker.log"
  PATH="$tmp/bin:$PATH" ROYD_DOCKER_LOG="$tmp/docker.log" ROYD_WORK_DIR="$tmp/work" ROYD_ANDROID_VERSION="$version" ROYD_BUILDER_TTY=never "$script_dir/builder.sh" true
  grep -Fq -- "-f $repo_root/android/builder/$expected" "$tmp/docker.log" || {
    printf 'error: Android %s did not select %s\n' "$version" "$expected" >&2
    exit 1
  }
}

run_case 8.0 Dockerfile.legacy
run_case 8.1 Dockerfile.legacy
run_case 10 Dockerfile.legacy
run_case 11 Dockerfile
run_case 17 Dockerfile

: > "$tmp/docker.log"
PATH="$tmp/bin:$PATH" ROYD_DOCKER_LOG="$tmp/docker.log" ROYD_WORK_DIR="$tmp/work" ROYD_ANDROID_VERSION=15 ROYD_BUILDER_TTY=always "$script_dir/builder.sh" true
grep -Fq -- 'run --rm -it --privileged' "$tmp/docker.log" || {
  printf '%s\n' 'error: ROYD_BUILDER_TTY=always did not request an interactive TTY' >&2
  exit 1
}

: > "$tmp/docker.log"
PATH="$tmp/bin:$PATH" ROYD_DOCKER_LOG="$tmp/docker.log" ROYD_WORK_DIR="$tmp/work" ROYD_ANDROID_VERSION=15 ROYD_BUILDER_TTY=never "$script_dir/builder.sh" true
if grep -Fq -- 'run --rm -it' "$tmp/docker.log"; then
  printf '%s\n' 'error: ROYD_BUILDER_TTY=never still requested an interactive TTY' >&2
  exit 1
fi

: > "$tmp/docker.log"
PATH="$tmp/bin:$PATH" \
ROYD_DOCKER_LOG="$tmp/docker.log" \
ROYD_WORK_DIR="$tmp/work" \
ROYD_ANDROID_VERSION=15 \
ROYD_BUILDER_TTY=never \
JOBS=7 \
ROYD_CLEAN_BUILD=1 \
ROYD_ANDROID_PROFILE=minimal \
ROYD_HAL_PROFILE=headless \
ROYD_GRAPHICS_BACKEND=software \
  "$script_dir/builder.sh" true
for expected in \
  '-e JOBS=7' \
  '-e ROYD_CLEAN_BUILD=1' \
  '-e ROYD_ANDROID_VERSION=15' \
  '-e ROYD_ANDROID_PROFILE=minimal' \
  '-e ROYD_HAL_PROFILE=headless' \
  '-e ROYD_GRAPHICS_BACKEND=software'
do
  grep -Fq -- "$expected" "$tmp/docker.log" || {
    printf 'error: builder did not forward %s\n' "$expected" >&2
    exit 1
  }
done

if [ "$(id -u)" -eq 0 ]; then
  : > "$tmp/docker.log"
  PATH="$tmp/bin:$PATH" \
  ROYD_DOCKER_LOG="$tmp/docker.log" \
  ROYD_WORK_DIR="$tmp/work" \
  ROYD_BUILD_UID=1234 \
  ROYD_BUILD_GID=2345 \
  ROYD_ANDROID_VERSION=15 \
  ROYD_BUILDER_TTY=never \
    "$script_dir/builder.sh" true
  grep -Fq -- '--build-arg UID=1234 --build-arg GID=2345' "$tmp/docker.log" || {
    printf '%s\n' 'error: root builder invocation did not use the requested non-root UID/GID' >&2
    exit 1
  }
  if PATH="$tmp/bin:$PATH" ROYD_DOCKER_LOG="$tmp/docker.log" ROYD_WORK_DIR="$tmp/work" ROYD_BUILD_UID=0 ROYD_BUILD_GID=0 ROYD_ANDROID_VERSION=15 ROYD_BUILDER_TTY=never "$script_dir/builder.sh" true >/dev/null 2>&1; then
    printf '%s\n' 'error: root builder invocation accepted UID/GID 0' >&2
    exit 1
  fi
fi

printf '%s\n' 'Android builder family, identity, environment and TTY tests passed'
