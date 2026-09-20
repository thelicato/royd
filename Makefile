.PHONY: check android-shell android-sync android-build-x86_64 android-build-arm64 android-package-x86_64 android-package-arm64 runtime-import-x86_64 runtime-import-arm64 runtime-smoke-test runtime-multi-test memory-report

check:
	./scripts/check-repo.sh
	./scripts/check-runtime.sh

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

runtime-smoke-test:
	./runtime/scripts/smoke-test.sh

runtime-multi-test:
	./runtime/scripts/multi-instance-test.sh

memory-report:
	./runtime/scripts/memory-report.sh
