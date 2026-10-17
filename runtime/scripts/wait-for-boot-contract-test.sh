#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
cat >"$tmp/bin/docker" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"$MOCK_STATE/calls"
case "$1" in
  inspect)
    if [ "${2:-}" = -f ]; then
      if [ "$MOCK_CASE" = stopped ]; then printf '%s\n' false; else printf '%s\n' true; fi
    fi ;;
  logs)
    count=$(cat "$MOCK_STATE/logs"); count=$((count+1)); printf '%s\n' "$count" >"$MOCK_STATE/logs"
    [ "$MOCK_CASE" != log_failure ] || exit 1
    if [ "$MOCK_CASE" = gated ] && [ "$count" -ge 2 ]; then printf '%s\n' 'ready marker'; fi ;;
  exec)
    if [ "$MOCK_CASE" = gated ]; then [ "$(cat "$MOCK_STATE/logs")" -ge 2 ]; fi
    printf '%s\n' 1 ;;
  *) exit 99 ;;
esac
MOCK
printf '%s\n' '#!/bin/sh' 'exit 0' >"$tmp/bin/sleep"
chmod +x "$tmp/bin/"*
for mode in default gated absent log_failure stopped; do
  state=$tmp/$mode
  mkdir "$state"
  printf '%s\n' 0 >"$state/logs"
  marker='ready marker'
  timeout=0
  case "$mode" in default) marker= ;; gated) timeout=10 ;; esac
  status=0
  PATH="$tmp/bin:$PATH" MOCK_STATE="$state" MOCK_CASE="$mode" ROYD_BOOT_WAIT_MARKER="$marker" \
    "$script_dir/wait-for-boot.sh" owned-test "$timeout" >"$state/result.log" 2>&1 || status=$?
  case "$mode" in
    default|gated) [ "$status" -eq 0 ]; [ "$(grep -c '^exec ' "$state/calls")" = 1 ] ;;
    *) [ "$status" -ne 0 ]; ! grep -q '^exec ' "$state/calls" ;;
  esac
  if [ "$mode" = default ]; then ! grep -q '^logs ' "$state/calls"; fi
done
printf '%s\n' 'Boot polling observation gate contract passed'
