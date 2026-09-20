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
  PATH="$tmp/bin:$PATH" ROYD_DOCKER_LOG="$tmp/docker.log" ROYD_WORK_DIR="$tmp/work" ROYD_ANDROID_VERSION="$version" "$script_dir/builder.sh" true
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
printf '%s\n' 'Android builder family test passed'
