.PHONY: check runtime-host-check cli-test cli-build android-profile-check android-shell android-sync android-build-x86_64 android-build-arm64 android-build-minimal-x86_64 android-build-minimal-arm64 android-package-x86_64 android-package-arm64 android-package-minimal-x86_64 android-package-minimal-arm64 runtime-import-x86_64 runtime-import-arm64 runtime-import-minimal-x86_64 runtime-import-minimal-arm64 runtime-up runtime-down runtime-logs runtime-ps runtime-smoke-test runtime-multi-test runtime-reference-report memory-report memory-sweep image-profile-sweep

check:
	./scripts/check-repo.sh
	./scripts/check-runtime.sh

runtime-host-check:
	./runtime/scripts/host-check.sh

cli-test:
	cd cli && go test ./...

cli-build:
	mkdir -p bin
	cd cli && go build -o ../bin/royd ./cmd/royd

android-profile-check:
	./android/scripts/profile-test.sh

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
