#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
android_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/repo" "$tmp/bin" "$tmp/src"
cp -a "$android_dir" "$tmp/repo/android"

cat > "$tmp/bin/repo" <<'MOCK'
#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$ROYD_REPO_LOG"
case "$1" in
  init)
    mkdir -p .repo
    ;;
  sync)
    mkdir -p build system/core/init
    cat > system/core/init/service.cpp <<'SRC'
#include <inttypes.h>
#include <linux/securebits.h>
#include <sched.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/time.h>
using android::base::WriteStringToFile;
namespace android {
namespace init {

static Result<std::string> ComputeContextFromExecutable(const std::string& service_path) {
    std::string computed_context;

void Service::SetProcessAttributesAndCaps() {
    if (auto result = SetProcessAttributes(proc_attr_); !result.ok()) {
        LOG(FATAL) << "cannot set attribute for " << name_ << ": " << result.error();
    }
    if (!seclabel_.empty()) {
        if (setexeccon(seclabel_.c_str()) < 0) {
            PLOG(FATAL) << "cannot setexeccon('" << seclabel_ << "') for " << name_;
        }
    }
}
Result<void> Service::Start() {
    }

    std::string scon;
    if (!seclabel_.empty()) {
        scon = seclabel_;
    } else {
        auto result = ComputeContextFromExecutable(args_[0]);
SRC
    cat > system/core/init/subcontext.cpp <<'SRC'

#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <android-base/file.h>
#include <android-base/properties.h>
#include <android-base/strings.h>
#include <selinux/android.h>

#include "action.h"
#include "builtins.h"
static std::vector<Subcontext> subcontexts;
static bool shutting_down;

std::vector<Subcontext>* InitializeSubcontexts() {
    if (SelinuxGetVendorAndroidVersion() >= __ANDROID_API_P__) {
        for (const auto& [path_prefix, secontext] : paths_and_secontexts) {
            subcontexts.emplace_back(path_prefix, secontext);
SRC
    ;;
  forall)
    ;;
  manifest)
    output=
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -o)
          output=$2
          shift 2
          ;;
        *)
          shift
          ;;
      esac
    done
    [ -n "$output" ] || exit 2
    mkdir -p "$(dirname -- "$output")"
    printf '%s\n' '<manifest />' > "$output"
    ;;
  *)
    exit 2
    ;;
esac
MOCK
cat > "$tmp/bin/git-lfs" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$tmp/bin/repo" "$tmp/bin/git-lfs"

: > "$tmp/repo.log"
for pass in 1 2; do
  TERM=${TERM:-dumb} \
  PATH="$tmp/bin:$PATH" \
  ROYD_REPO_LOG="$tmp/repo.log" \
  ROYD_ANDROID_VERSION=15 \
  ROYD_ANDROID_SRC="$tmp/src" \
  JOBS=1 \
    "$tmp/repo/android/scripts/sync.sh" >/dev/null

done

[ "$(grep -c '^init ' "$tmp/repo.log")" -eq 1 ] || {
  printf '%s\n' 'error: resumable sync reinitialised an existing Repo checkout' >&2
  exit 1
}
[ "$(grep -c '^sync ' "$tmp/repo.log")" -eq 2 ] || {
  printf '%s\n' 'error: expected both sync passes to invoke repo sync' >&2
  exit 1
}
if grep -Fq -- '--git-lfs' "$tmp/repo.log"; then
  printf '%s\n' 'error: sync still passes unsupported repo init --git-lfs' >&2
  exit 1
fi
grep -Fq "forall -c git lfs pull" "$tmp/repo.log" || {
  printf '%s\n' 'error: explicit Git LFS pull step is missing' >&2
  exit 1
}
test -f "$tmp/repo/.work/android-manifest-15.lock.xml"

printf '%s\n' 'Android Repo and Git LFS sync contract test passed'
