#!/bin/sh
set -eu

errors=0
warnings=0
security_mode=${ROYD_SECURITY_MODE:-privileged}

ok() {
  printf 'ok      %s\n' "$*"
}

warn() {
  warnings=$((warnings + 1))
  printf 'warning %s\n' "$*"
}

fail() {
  errors=$((errors + 1))
  printf 'error   %s\n' "$*"
}

case "$security_mode" in
  privileged) ok "runtime security mode: privileged development baseline" ;;
  experimental) warn "runtime security mode: experimental reduced capability set" ;;
  *) fail "unknown runtime security mode: $security_mode" ;;
esac

if [ "$(uname -s)" = Linux ]; then
  ok "Linux host kernel: $(uname -r)"
else
  fail "royd requires a Linux host kernel"
fi

if command -v docker >/dev/null 2>&1; then
  ok "Docker command found"
  if docker info >/dev/null 2>&1; then
    ok "Docker daemon reachable"
  else
    fail "Docker daemon is not reachable"
  fi
else
  fail "Docker command not found"
fi

if awk '$NF == "binder" { found=1 } END { exit !found }' /proc/filesystems 2>/dev/null; then
  ok "binderfs advertised by kernel"
else
  fail "binderfs is not advertised by the host kernel"
fi

if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  ok "cgroup v2 detected"
else
  warn "cgroup v2 not detected"
fi

if [ -r /proc/pressure/memory ]; then
  ok "memory PSI available"
else
  warn "memory PSI unavailable"
fi

if [ -e /dev/dri/renderD128 ]; then
  ok "DRM render node available at /dev/dri/renderD128"
else
  ok "no DRM render node required for the software graphics baseline"
fi

printf '\nSummary: %s error(s), %s warning(s)\n' "$errors" "$warnings"
[ "$errors" -eq 0 ]
