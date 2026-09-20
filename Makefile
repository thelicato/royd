.PHONY: ci android-build-matrix android-build-matrix-test android-build-results-report android-matrix-report android-matrix-report-test check android-hal-profile-test android-hal-contract-test android-build-headless-x86_64 android-build-headless-arm64 android-package-headless-x86_64 android-package-headless-arm64 runtime-import-headless-x86_64 runtime-import-headless-arm64 runtime-smoke-test-headless android-graphics-contract-test runtime-graphics-report android-memory-compat-test android-versions android-version-test android-builder-family-test runtime-host-check runtime-security-contract-test runtime-security-sweep runtime-security-capability-sweep runtime-security-capability-sweep-test runtime-security-evidence-test runtime-smoke-test-experimental runtime-multi-test-experimental runtime-image-contract-test runtime-image-inspect-x86_64 runtime-image-inspect-arm64 cli-test cli-build android-profile-check android-profile-policy-test android-contract-test android-config-check-test android-config-check android-shell android-sync android-build-x86_64 android-build-arm64 android-build-minimal-x86_64 android-build-minimal-arm64 android-package-x86_64 android-package-arm64 android-package-minimal-x86_64 android-package-minimal-arm64 runtime-import-x86_64 runtime-import-arm64 runtime-import-minimal-x86_64 runtime-import-minimal-arm64 runtime-up runtime-down runtime-logs runtime-ps runtime-status runtime-adb-check runtime-adb-contract-test runtime-smoke-test runtime-multi-test runtime-reference-report memory-report memory-sweep memory-provenance-test image-profile-sweep runtime-qualification runtime-qualification-report runtime-qualification-contract-test runtime-binder-isolation-test runtime-qualification-matrix runtime-qualification-matrix-test android-graphics-backend-test android-build-host-gpu-x86_64 android-package-host-gpu-x86_64 runtime-import-host-gpu-x86_64 android-build-host-gpu-arm64 android-package-host-gpu-arm64 runtime-import-host-gpu-arm64 android-build-host-gpu-intel-x86_64 android-package-host-gpu-intel-x86_64 runtime-import-host-gpu-intel-x86_64 runtime-smoke-test-host-gpu runtime-smoke-test-host-gpu-intel runtime-gpu-contract-test android-display-contract-test runtime-entrypoint-contract-test runtime-reference-qualify runtime-reference-bundle-verify runtime-reference-qualify-test

ci:
	./scripts/ci.sh

android-build-matrix:
	./android/scripts/build-matrix.sh

android-build-matrix-test:
	./android/scripts/build-matrix-test.sh

android-build-results-report:
	./android/scripts/build-results-report.sh

android-matrix-report:
	./android/scripts/matrix-report.sh

android-matrix-report-test:
	./android/scripts/matrix-report-test.sh

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

android-graphics-contract-test:
	./android/scripts/graphics-contract-test.sh

android-graphics-backend-test:
	./android/scripts/graphics-backend-test.sh

runtime-gpu-contract-test:
	./runtime/scripts/gpu-contract-test.sh

android-build-host-gpu-x86_64:
	ROYD_GRAPHICS_BACKEND=host-gpu-generic ./android/scripts/builder.sh android/scripts/build.sh x86_64 standard

android-package-host-gpu-x86_64:
	ROYD_GRAPHICS_BACKEND=host-gpu-generic ./android/scripts/builder.sh android/scripts/package.sh x86_64 standard

runtime-import-host-gpu-x86_64:
	ROYD_GRAPHICS_BACKEND=host-gpu-generic ./runtime/scripts/import.sh x86_64 standard

android-build-host-gpu-arm64:
	ROYD_GRAPHICS_BACKEND=host-gpu-generic ./android/scripts/builder.sh android/scripts/build.sh arm64 standard

android-package-host-gpu-arm64:
	ROYD_GRAPHICS_BACKEND=host-gpu-generic ./android/scripts/builder.sh android/scripts/package.sh arm64 standard

runtime-import-host-gpu-arm64:
	ROYD_GRAPHICS_BACKEND=host-gpu-generic ./runtime/scripts/import.sh arm64 standard

android-build-host-gpu-intel-x86_64:
	ROYD_GRAPHICS_BACKEND=host-gpu-intel ./android/scripts/builder.sh android/scripts/build.sh x86_64 standard

android-package-host-gpu-intel-x86_64:
	ROYD_GRAPHICS_BACKEND=host-gpu-intel ./android/scripts/builder.sh android/scripts/package.sh x86_64 standard

runtime-import-host-gpu-intel-x86_64:
	ROYD_GRAPHICS_BACKEND=host-gpu-intel ./runtime/scripts/import.sh x86_64 standard

runtime-smoke-test-host-gpu:
	ROYD_GRAPHICS_BACKEND=host-gpu-generic ROYD_IMAGE=$$(ROYD_GRAPHICS_BACKEND=host-gpu-generic ./runtime/scripts/default-image.sh standard x86_64) ./runtime/scripts/smoke-test.sh

runtime-smoke-test-host-gpu-intel:
	ROYD_GRAPHICS_BACKEND=host-gpu-intel ROYD_IMAGE=$$(ROYD_GRAPHICS_BACKEND=host-gpu-intel ./runtime/scripts/default-image.sh standard x86_64) ./runtime/scripts/smoke-test.sh

android-hal-profile-test:
	./android/scripts/hal-profile-test.sh

android-hal-contract-test:
	./android/scripts/hal-contract-test.sh

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


runtime-qualification:
	./runtime/scripts/qualification.sh

runtime-qualification-matrix:
	./runtime/scripts/qualification-matrix.sh

runtime-qualification-matrix-test:
	./runtime/scripts/qualification-matrix-test.sh

runtime-qualification-report:
	./runtime/scripts/qualification-report.sh

runtime-qualification-contract-test:
	./runtime/scripts/qualification-contract-test.sh

runtime-binder-isolation-test:
	./runtime/scripts/binder-isolation-test.sh

runtime-graphics-report:
	./runtime/scripts/graphics-report.sh

runtime-security-contract-test:
	./runtime/scripts/security-contract-test.sh

runtime-security-sweep:
	./runtime/scripts/security-sweep.sh

runtime-security-capability-sweep:
	./runtime/scripts/security-capability-sweep.sh

runtime-security-capability-sweep-test:
	./runtime/scripts/security-capability-sweep-test.sh

runtime-security-evidence-test:
	./runtime/scripts/security-evidence-test.sh

runtime-smoke-test-experimental:
	ROYD_SECURITY_MODE=experimental ./runtime/scripts/smoke-test.sh

runtime-multi-test-experimental:
	ROYD_SECURITY_MODE=experimental ./runtime/scripts/multi-instance-test.sh

runtime-image-contract-test:
	./runtime/scripts/image-contract-test.sh

runtime-entrypoint-contract-test:
	./runtime/scripts/entrypoint-contract-test.sh

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

android-profile-policy-test:
	./android/scripts/profile-policy-test.sh

android-contract-test:
	./android/scripts/contract-test.sh

android-display-contract-test:
	./android/scripts/display-contract-test.sh

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

android-build-headless-x86_64:
	ROYD_HAL_PROFILE=headless ./android/scripts/builder.sh android/scripts/build.sh x86_64 standard

android-build-headless-arm64:
	ROYD_HAL_PROFILE=headless ./android/scripts/builder.sh android/scripts/build.sh arm64 standard

android-package-headless-x86_64:
	ROYD_HAL_PROFILE=headless ./android/scripts/builder.sh android/scripts/package.sh x86_64 standard

android-package-headless-arm64:
	ROYD_HAL_PROFILE=headless ./android/scripts/builder.sh android/scripts/package.sh arm64 standard

runtime-import-headless-x86_64:
	ROYD_HAL_PROFILE=headless ./runtime/scripts/import.sh x86_64 standard

runtime-import-headless-arm64:
	ROYD_HAL_PROFILE=headless ./runtime/scripts/import.sh arm64 standard

runtime-smoke-test-headless:
	ROYD_HAL_PROFILE=headless ROYD_IMAGE=$$(ROYD_HAL_PROFILE=headless ./runtime/scripts/default-image.sh standard x86_64) ./runtime/scripts/smoke-test.sh

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

runtime-reference-qualify:
	./runtime/scripts/reference-host-qualify.sh

runtime-reference-bundle-verify:
	./runtime/scripts/reference-bundle-verify.sh $(BUNDLE)

runtime-reference-qualify-test:
	./runtime/scripts/reference-host-qualify-test.sh

memory-report:
	./runtime/scripts/memory-report.sh

memory-sweep:
	./runtime/scripts/memory-sweep.sh

memory-provenance-test:
	./runtime/scripts/memory-provenance-test.sh

image-profile-sweep:
	./runtime/scripts/image-profile-sweep.sh

runtime-status:
	./runtime/scripts/status.sh

runtime-adb-check:
	./runtime/scripts/adb-check.sh

runtime-adb-contract-test:
	./runtime/scripts/adb-contract-test.sh
