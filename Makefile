.PHONY: check cli-test cli-build android-shell android-sync android-build-x86_64 android-build-arm64 android-package-x86_64 android-package-arm64 runtime-import-x86_64 runtime-import-arm64 runtime-up runtime-down runtime-logs runtime-ps runtime-smoke-test runtime-multi-test runtime-reference-report memory-report memory-sweep

check:
	./scripts/check-repo.sh
	./scripts/check-runtime.sh

cli-test:
	cd cli && go test ./...

cli-build:
	mkdir -p bin
	cd cli && go build -o ../bin/royd ./cmd/royd

android-shell:
	./android/scripts/builder.sh

android-sync:
	./android/scripts/builder.sh android/scripts/sync.sh

android-build-x86_64:
	./android/scripts/builder.sh android/scripts/build.sh x86_64

android-build-arm64:
	./android/scripts/builder.sh android/scripts/build.sh arm64

android-package-x86_64:
	./android/scripts/builder.sh android/scripts/package.sh x86_64

android-package-arm64:
	./android/scripts/builder.sh android/scripts/package.sh arm64

runtime-import-x86_64:
	./runtime/scripts/import.sh x86_64

runtime-import-arm64:
	./runtime/scripts/import.sh arm64

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
