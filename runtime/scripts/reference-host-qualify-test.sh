#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work/bin" "$work/results"

cat > "$work/bin/pass" <<'RUNNER'
#!/bin/sh
set -eu
case "${ROYD_KERNEL_EVIDENCE_OUTPUT:-}" in
  ?*)
    contract_sha=$(sha256sum "${ROYD_TEST_KERNEL_CONTRACT:?}" | awk '{print $1}')
    cat > "$ROYD_KERNEL_EVIDENCE_OUTPUT" <<KERNEL
ROYD_KERNEL_EVIDENCE_FORMAT=1
CONFIG_CONTRACT_SHA256=$contract_sha
KERNEL
    ;;
esac
case "${ROYD_REPORT_OUTPUT:-}" in ?*) printf '# mock reference\n' > "$ROYD_REPORT_OUTPUT" ;; esac
case "${ROYD_MEMORY_SWEEP_OUTPUT:-}" in ?*) printf '# mock memory\n' > "$ROYD_MEMORY_SWEEP_OUTPUT" ;; esac
case "${ROYD_SECURITY_CAPABILITY_SWEEP_OUTPUT:-}" in ?*) printf '# mock security\n' > "$ROYD_SECURITY_CAPABILITY_SWEEP_OUTPUT" ;; esac
if [ -n "${ROYD_RUNTIME_RESULT_FILE:-}" ]; then
  mkdir -p "$(dirname -- "$ROYD_RUNTIME_RESULT_FILE")"
  cat > "$ROYD_RUNTIME_RESULT_FILE" <<'RESULT'
RESULT_FORMAT=4
RESULT_STATUS=pass
CONTAINER_EVIDENCE_STATUS=pass
RESULT
fi
if [ -n "${ROYD_RUNTIME_LOG_FILE:-}" ]; then
  printf '%s\n' 'mock runtime qualification log' > "$ROYD_RUNTIME_LOG_FILE"
fi
if [ -n "${ROYD_RUNTIME_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$ROYD_RUNTIME_EVIDENCE_DIR"
  printf '%s\n' '[{}]' > "$ROYD_RUNTIME_EVIDENCE_DIR/container-inspect.json"
  printf '%s\n' 'mock container log' > "$ROYD_RUNTIME_EVIDENCE_DIR/container.log"
  printf '%s\n' 'status=running' > "$ROYD_RUNTIME_EVIDENCE_DIR/state.txt"
fi
exit 0
RUNNER
chmod +x "$work/bin/pass"

runtime_result="$work/results/runtime.env"
runtime_log="$work/results/runtime.log"
runtime_evidence="$work/results/runtime.evidence"

bundle="$work/bundle"
ROYD_REFERENCE_BUNDLE_OUTPUT="$bundle" \
ROYD_RUNTIME_RESULT_FILE="$runtime_result" \
ROYD_RUNTIME_LOG_FILE="$runtime_log" \
ROYD_RUNTIME_EVIDENCE_DIR="$runtime_evidence" \
ROYD_TEST_KERNEL_CONTRACT="$repo_root/runtime/kernel/config-contract.tsv" \
ROYD_REFERENCE_KERNEL_RUNNER="$work/bin/pass" \
ROYD_REFERENCE_HOST_RUNNER="$work/bin/pass" \
ROYD_REFERENCE_IMAGE_RUNNER="$work/bin/pass" \
ROYD_REFERENCE_QUALIFICATION_RUNNER="$work/bin/pass" \
ROYD_REFERENCE_REPORT_RUNNER="$work/bin/pass" \
ROYD_REFERENCE_MEMORY_RUNNER="$work/bin/pass" \
ROYD_REFERENCE_INCLUDE_MEMORY=1 \
"$script_dir/reference-host-qualify.sh"

[ -f "$bundle/manifest.env" ]
[ -f "$bundle/kernel.env" ]
[ -f "$bundle/reference-host.md" ]
[ -f "$bundle/memory.md" ]
[ -f "$bundle/runtime-result.env" ]
[ -f "$bundle/runtime-qualification.log" ]
[ -f "$bundle/runtime-evidence/container-inspect.json" ]
[ -f "$bundle/runtime-evidence/container.log" ]
[ -f "$bundle/runtime-evidence/state.txt" ]
[ -f "$bundle/SHA256SUMS" ]
grep -Fqx 'RESULT_STATUS=pass' "$bundle/manifest.env"
grep -Fqx 'KERNEL_STATUS=pass' "$bundle/manifest.env"
grep -Fqx 'MEMORY_STATUS=pass' "$bundle/manifest.env"
grep -Fqx 'RUNTIME_LOG_STATUS=pass' "$bundle/manifest.env"
grep -Fqx 'RUNTIME_EVIDENCE_STATUS=pass' "$bundle/manifest.env"
"$script_dir/reference-bundle-verify.sh" "$bundle" >/dev/null

stale_kernel_bundle="$work/stale-kernel-bundle"
cp -R "$bundle" "$stale_kernel_bundle"
sed -i 's/^CONFIG_CONTRACT_SHA256=.*/CONFIG_CONTRACT_SHA256=stale/' "$stale_kernel_bundle/kernel.env"
(
  cd "$stale_kernel_bundle"
  find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort | sed 's#^./##' | while IFS= read -r file; do sha256sum "$file"; done > SHA256SUMS
)
if "$script_dir/reference-bundle-verify.sh" "$stale_kernel_bundle" >/dev/null 2>&1; then
  printf '%s\n' 'error: stale kernel contract unexpectedly verified' >&2
  exit 1
fi

printf '%s\n' tampered >> "$bundle/host.log"
if "$script_dir/reference-bundle-verify.sh" "$bundle" >/dev/null 2>&1; then
  printf '%s\n' 'error: tampered reference bundle unexpectedly verified' >&2
  exit 1
fi

cat > "$work/bin/no-kernel-evidence" <<'RUNNER'
#!/bin/sh
exit 0
RUNNER
chmod +x "$work/bin/no-kernel-evidence"
missing_kernel_bundle="$work/missing-kernel-bundle"
set +e
ROYD_REFERENCE_BUNDLE_OUTPUT="$missing_kernel_bundle" ROYD_RUNTIME_RESULT_FILE="$runtime_result" \
ROYD_RUNTIME_LOG_FILE="$runtime_log" ROYD_RUNTIME_EVIDENCE_DIR="$runtime_evidence" \
ROYD_REFERENCE_KERNEL_RUNNER="$work/bin/no-kernel-evidence" ROYD_REFERENCE_HOST_RUNNER="$work/bin/pass" \
ROYD_REFERENCE_IMAGE_RUNNER="$work/bin/pass" ROYD_REFERENCE_QUALIFICATION_RUNNER="$work/bin/pass" \
ROYD_REFERENCE_REPORT_RUNNER="$work/bin/pass" ROYD_REFERENCE_MEMORY_RUNNER="$work/bin/pass" \
"$script_dir/reference-host-qualify.sh" >/dev/null 2>&1
code=$?
set -e
[ "$code" -ne 0 ]
grep -Fqx 'KERNEL_STATUS=fail' "$missing_kernel_bundle/manifest.env"

fail_bundle="$work/fail-bundle"
cat > "$work/bin/fail" <<'RUNNER'
#!/bin/sh
exit 1
RUNNER
chmod +x "$work/bin/fail"
set +e
ROYD_REFERENCE_BUNDLE_OUTPUT="$fail_bundle" ROYD_RUNTIME_RESULT_FILE="$runtime_result" \
ROYD_RUNTIME_LOG_FILE="$runtime_log" ROYD_RUNTIME_EVIDENCE_DIR="$runtime_evidence" \
ROYD_TEST_KERNEL_CONTRACT="$repo_root/runtime/kernel/config-contract.tsv" \
ROYD_REFERENCE_KERNEL_RUNNER="$work/bin/pass" ROYD_REFERENCE_HOST_RUNNER="$work/bin/fail" ROYD_REFERENCE_IMAGE_RUNNER="$work/bin/pass" \
ROYD_REFERENCE_QUALIFICATION_RUNNER="$work/bin/pass" ROYD_REFERENCE_REPORT_RUNNER="$work/bin/pass" \
ROYD_REFERENCE_MEMORY_RUNNER="$work/bin/pass" "$script_dir/reference-host-qualify.sh" >/dev/null 2>&1
code=$?
set -e
[ "$code" -ne 0 ]
grep -Fqx 'RESULT_STATUS=fail' "$fail_bundle/manifest.env"
grep -Fqx 'HOST_STATUS=fail' "$fail_bundle/manifest.env"

printf '%s\n' 'Reference-host qualification bundle test passed'
