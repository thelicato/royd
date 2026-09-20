.PHONY: check android-memory-compat-test android-versions android-version-test android-builder-family-test runtime-host-check runtime-security-contract-test runtime-security-sweep runtime-smoke-test-experimental runtime-multi-test-experimental runtime-image-contract-test runtime-image-inspect-x86_64 runtime-image-inspect-arm64 cli-test cli-build android-profile-check android-contract-test android-config-check-test android-config-check android-shell android-sync android-build-x86_64 android-build-arm64 android-build-minimal-x86_64 android-build-minimal-arm64 android-package-x86_64 android-package-arm64 android-package-minimal-x86_64 android-package-minimal-arm64 runtime-import-x86_64 runtime-import-arm64 runtime-import-minimal-x86_64 runtime-import-minimal-arm64 runtime-up runtime-down runtime-logs runtime-ps runtime-smoke-test runtime-multi-test runtime-reference-report memory-report memory-sweep image-profile-sweep

check:
	./scripts/check-repo.sh
	./scripts/check-runtime.sh

android-versions:
	@printf '%s\n' \
	  '8.0 android-8.0.0_r36  legacy-configured' \
	  '8.1 android-8.1.0_r81  legacy-configured' \
	  '9   android-9.0.0_r61  legacy-configured' \
	  '10  android-10.0.0_r47 legacy-configured' \
	  '11  android-11.0.0_r48 configured' \
	  '12  android-12.0.0_r34 configured' \
	  '13  android-13.0.0_r75 configured' \
	  '14  android-14.0.0_r14 configured' \
	  '15  android-15.0.0_r36 baseline' \
	  '16  android-16.0.0_r4  configured' \
	  '17  android-17.0.0_r1  configured'

android-version-test:
	./android/scripts/version-test.sh

android-builder-family-test:
	./android/scripts/builder-family-test.sh

android-memory-compat-test:
	./android/scripts/memory-compat-test.sh

android-sync-%:
	ROYD_ANDROID_VERSION=$* ./android/scripts/builder.sh android/scripts/sync.sh

android-config-check-%:
	ROYD_ANDROID_VERSION=$* ./android/scripts/builder.sh android/scripts/config-check.sh

android-build-x86_64-%:
	ROYD_ANDROID_VERSION=$* ./android/scripts/builder.sh android/scripts/build.sh x86_64 standard

android-build-arm64-%:
	ROYD_ANDROID_VERSION=$* ./android/scripts/builder.sh android/scripts/build.sh arm64 standard

android-package-x86_64-%:
	ROYD_ANDROID_VERSION=$* ./android/scripts/builder.sh android/scripts/package.sh x86_64 standard

android-package-arm64-%:
	ROYD_ANDROID_VERSION=$* ./android/scripts/builder.sh android/scripts/package.sh arm64 standard

runtime-import-x86_64-%:
	ROYD_ANDROID_VERSION=$* ./runtime/scripts/import.sh x86_64 standard

runtime-import-arm64-%:
	ROYD_ANDROID_VERSION=$* ./runtime/scripts/import.sh arm64 standard

runtime-host-check:
	./runtime/scripts/host-check.sh

runtime-security-contract-test:
	./runtime/scripts/security-contract-test.sh

runtime-security-sweep:
	./runtime/scripts/security-sweep.sh

runtime-smoke-test-experimental:
	ROYD_SECURITY_MODE=experimental ./runtime/scripts/smoke-test.sh

runtime-multi-test-experimental:
	ROYD_SECURITY_MODE=experimental ./runtime/scripts/multi-instance-test.sh

runtime-image-contract-test:
	./runtime/scripts/image-contract-test.sh

runtime-image-inspect-x86_64:
	./runtime/scripts/image-inspect.sh x86_64 standard

runtime-image-inspect-arm64:
	./runtime/scripts/image-inspect.sh arm64 standard

cli-test:
	cd cli && go test ./...

cli-build:
	mkdir -p bin
	cd cli && go build -o ../bin/royd ./cmd/royd

android-profile-check:
	./android/scripts/profile-test.sh

android-contract-test:
	./android/scripts/contract-test.sh

android-config-check-test:
	./android/scripts/config-check-test.sh

android-config-check:
	./android/scripts/builder.sh android/scripts/config-check.sh

android-shell:
	./android/scripts/builder.sh

android-sync:
	./android/scripts/builder.sh android/scripts/sync.sh

android-build-x86_64:
	./android/scripts/builder.sh android/scripts/build.sh x86_64 standard

android-build-arm64:
	./android/scripts/builder.sh android/scripts/build.sh arm64 standard

android-build-minimal-x86_64:
	./android/scripts/builder.sh android/scripts/build.sh x86_64 minimal

android-build-minimal-arm64:
	./android/scripts/builder.sh android/scripts/build.sh arm64 minimal

android-package-x86_64:
	./android/scripts/builder.sh android/scripts/package.sh x86_64 standard

android-package-arm64:
	./android/scripts/builder.sh android/scripts/package.sh arm64 standard

android-package-minimal-x86_64:
	./android/scripts/builder.sh android/scripts/package.sh x86_64 minimal

android-package-minimal-arm64:
	./android/scripts/builder.sh android/scripts/package.sh arm64 minimal

runtime-import-x86_64:
	./runtime/scripts/import.sh x86_64 standard

runtime-import-arm64:
	./runtime/scripts/import.sh arm64 standard

runtime-import-minimal-x86_64:
	./runtime/scripts/import.sh x86_64 minimal

runtime-import-minimal-arm64:
	./runtime/scripts/import.sh arm64 minimal

runtime-up:
	./runtime/scripts/compose.sh up -d

runtime-down:
	./runtime/scripts/compose.sh down

runtime-logs:
	./runtime/scripts/compose.sh logs -f android

runtime-ps:
	./runtime/scripts/compose.sh ps

runtime-smoke-test:
	./runtime/scripts/smoke-test.sh

runtime-multi-test:
	./runtime/scripts/multi-instance-test.sh

runtime-reference-report:
	./runtime/scripts/reference-report.sh

memory-report:
	./runtime/scripts/memory-report.sh

memory-sweep:
	./runtime/scripts/memory-sweep.sh

image-profile-sweep:
	./runtime/scripts/image-profile-sweep.sh
