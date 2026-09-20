.PHONY: check android-shell android-sync android-build-x86_64 android-build-arm64

check:
	./scripts/check-repo.sh

android-shell:
	./android/scripts/builder.sh

android-sync:
	./android/scripts/builder.sh android/scripts/sync.sh

android-build-x86_64:
	./android/scripts/builder.sh android/scripts/build.sh x86_64

android-build-arm64:
	./android/scripts/builder.sh android/scripts/build.sh arm64
