#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

run ./scripts/check-repo.sh
run ./scripts/check-runtime.sh
run ./scripts/build-helper-test.sh
run ./android/scripts/version-test.sh
run ./android/scripts/builder-family-test.sh
run ./android/scripts/sync-contract-test.sh
run ./android/scripts/aosp-shell-test.sh
run ./android/scripts/profile-test.sh
run ./android/scripts/profile-policy-test.sh
run ./android/scripts/hal-profile-test.sh
run ./android/scripts/contract-test.sh
run ./android/scripts/vintf-contract-test.sh
run ./android/scripts/android15-build-readiness-test.sh
run ./android/scripts/android15-container-init-test.sh
run ./android/scripts/display-contract-test.sh
run ./android/scripts/config-check-test.sh
run ./android/scripts/memory-compat-test.sh
run ./android/scripts/graphics-contract-test.sh
run ./android/scripts/graphics-backend-test.sh
run ./android/scripts/hal-contract-test.sh
run ./android/scripts/matrix-report-test.sh
run ./android/scripts/build-matrix-test.sh
run ./android/scripts/package-contract-test.sh
run ./runtime/scripts/image-contract-test.sh
run ./runtime/scripts/memory-provenance-test.sh
run ./runtime/scripts/entrypoint-contract-test.sh
run ./runtime/scripts/boot-diagnostics-contract-test.sh
run ./runtime/scripts/container-evidence-test.sh
run ./runtime/scripts/kernel-evidence-test.sh
run ./runtime/scripts/rootless-probe-test.sh
run ./runtime/scripts/gpu-contract-test.sh
run ./runtime/scripts/security-contract-test.sh
run ./runtime/scripts/security-capability-sweep-test.sh
run ./runtime/scripts/security-evidence-test.sh
run ./runtime/scripts/adb-contract-test.sh
run ./runtime/scripts/qualification-contract-test.sh
run ./runtime/scripts/qualification-matrix-test.sh
run ./runtime/scripts/reference-host-qualify-test.sh
run sh -c 'cd cli && go test ./...'

printf '\n%s\n' 'royd lightweight CI passed'
