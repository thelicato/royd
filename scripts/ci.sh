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
run ./android/scripts/version-test.sh
run ./android/scripts/builder-family-test.sh
run ./android/scripts/profile-test.sh
run ./android/scripts/hal-profile-test.sh
run ./android/scripts/contract-test.sh
run ./android/scripts/config-check-test.sh
run ./android/scripts/memory-compat-test.sh
run ./android/scripts/graphics-contract-test.sh
run ./android/scripts/hal-contract-test.sh
run ./android/scripts/matrix-report-test.sh
run ./runtime/scripts/image-contract-test.sh
run ./runtime/scripts/security-contract-test.sh
run ./runtime/scripts/adb-contract-test.sh
run sh -c 'cd cli && go test ./...'

printf '\n%s\n' 'royd lightweight CI passed'
