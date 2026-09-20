#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

cat > "$tmp/runner" <<'MOCK'
#!/bin/sh
set -eu
case " ${ROYD_CAPABILITIES_OVERRIDE:-} " in
  *' SYS_ADMIN '*) exit 0 ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/runner"

report="$tmp/report.md"
ROYD_SECURITY_SWEEP_CHECK_IMAGE=0 \
ROYD_SECURITY_SINGLE_RUNNER="$tmp/runner" \
ROYD_SECURITY_MULTI_RUNNER="$tmp/runner" \
ROYD_SECURITY_CAPABILITY_SWEEP_OUTPUT="$report" \
"$script_dir/security-capability-sweep.sh" example/royd:test >/dev/null

grep -Fq '| `baseline` | passed | passed | baseline passed |' "$report"
grep -Fq '| `without-SYS_PTRACE` | passed | passed | candidate for removal |' "$report"
grep -Fq '| `without-SYS_ADMIN` | failed | failed | keep pending deeper diagnosis |' "$report"
grep -Fq 'security profile SHA-256' "$report"

cat > "$tmp/fail-runner" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$tmp/fail-runner"
if ROYD_SECURITY_SWEEP_CHECK_IMAGE=0 \
  ROYD_SECURITY_SINGLE_RUNNER="$tmp/fail-runner" \
  ROYD_SECURITY_MULTI_RUNNER="$tmp/fail-runner" \
  ROYD_SECURITY_CAPABILITY_SWEEP_OUTPUT="$tmp/fail.md" \
  "$script_dir/security-capability-sweep.sh" example/royd:test >/dev/null 2>&1; then
  printf '%s\n' 'error: capability sweep accepted a failing experimental baseline' >&2
  exit 1
fi

printf '%s\n' 'Runtime security capability sweep test passed'
