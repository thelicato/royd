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
    mkdir -p build system/core/init frameworks/native/cmds/servicemanager
    if [ ! -f system/core/init/service.cpp ]; then
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
}

void Service::SetProcessAttributesAndCaps(InterprocessFifo setsid_finished) {
    if (auto result = SetProcessAttributes(proc_attr_, std::move(setsid_finished)); !result.ok()) {
        LOG(FATAL) << "cannot set attribute for " << name_ << ": " << result.error();
    }

    if (!seclabel_.empty()) {
        if (setexeccon(seclabel_.c_str()) < 0) {
            PLOG(FATAL) << "cannot setexeccon('" << seclabel_ << "') for " << name_;
        }
    }
}

Result<void> Service::Start() {
    if (Result<void> result = CheckConsole(); !result.ok()) {
        return result;
    }

    struct stat sb;
    if (stat(args_[0].c_str(), &sb) == -1) {
        flags_ |= SVC_DISABLED;
        return ErrnoError() << "Cannot find '" << args_[0] << "'";
    }

    std::string scon;
    if (!seclabel_.empty()) {
        scon = seclabel_;
    } else {
        auto result = ComputeContextFromExecutable(args_[0]);
SRC
    fi
    if [ ! -f system/core/init/subcontext.cpp ]; then
      cat > system/core/init/subcontext.cpp <<'SRC'

#include <fcntl.h>
#include <poll.h>
#include <sys/time.h>
#include <sys/resource.h>
#include <unistd.h>

#include <android-base/file.h>
#include <android-base/logging.h>
#include <android-base/properties.h>
#include <android-base/strings.h>
#include <selinux/android.h>

#include "action.h"
#include "builtins.h"
#include "mount_namespace.h"
#include "proto_utils.h"
#include "util.h"

#ifdef INIT_FULL_SOURCES
#include <android/api-level.h>
#include "property_service.h"
#include "selabel.h"
#include "selinux.h"
#else
#include "host_init_stubs.h"
#endif

using android::base::GetExecutablePath;
using android::base::GetProperty;
using android::base::Join;
using android::base::Socketpair;
using android::base::Split;
using android::base::StartsWith;
using android::base::unique_fd;

namespace android {
namespace init {
namespace {

std::string shutdown_command;
static bool subcontext_terminated_by_shutdown;
static std::unique_ptr<Subcontext> subcontext;

Result<std::vector<std::string>> Subcontext::ExpandArgs(const std::vector<std::string>& args) {
    return args;
}

void InitializeSubcontext() {
    if (IsMicrodroid()) {
        LOG(INFO) << "Not using subcontext for microdroid";
        return;
    }

    if (SelinuxGetVendorAndroidVersion() >= __ANDROID_API_P__) {
        subcontext.reset(new Subcontext(std::vector<std::string>{"/vendor", "/odm"},
                                        std::vector<std::string>{"VENDOR", "ODM"}, kVendorContext));
    }
}
SRC
    fi
    if [ ! -f frameworks/native/cmds/servicemanager/Access.cpp ]; then
      cat > frameworks/native/cmds/servicemanager/Access.cpp <<'SRC'
#include "Access.h"

#include <android-base/logging.h>
#include <binder/IPCThreadState.h>
#include <log/log_safetynet.h>
#include <selinux/android.h>
#include <selinux/avc.h>

#include <sstream>

namespace android {

#ifdef VENDORSERVICEMANAGER
constexpr bool kIsVendor = true;
#else
constexpr bool kIsVendor = false;
#endif

#ifdef __ANDROID__
static std::string getPidcon(pid_t pid) {
    android_errorWriteLog(0x534e4554, "121035042");
    return "";
}

static struct selabel_handle* getSehandle() {
    return nullptr;
}

struct AuditCallbackData {
    const Access::CallingContext* context;
    const std::string* tname;
};

static int auditCallback(void *data, security_class_t /*cls*/, char *buf, size_t len) {
    const AuditCallbackData* ad = reinterpret_cast<AuditCallbackData*>(data);
    if (!ad) {
        return 0;
    }
    snprintf(buf, len, "pid=%d uid=%d name=%s", ad->context->debugPid, ad->context->uid,
        ad->tname->c_str());
    return 0;
}
#endif

std::string Access::CallingContext::toDebugString() const {
    std::stringstream ss;
    ss << "Caller(pid=" << debugPid << ",uid=" << uid << ",sid=" << sid << ")";
    return ss.str();
}

Access::Access() {
#ifdef __ANDROID__
    union selinux_callback cb;

    cb.func_audit = auditCallback;
    selinux_set_callback(SELINUX_CB_AUDIT, cb);

    cb.func_log = kIsVendor ? selinux_vendor_log_callback : selinux_log_callback;
    selinux_set_callback(SELINUX_CB_LOG, cb);

    CHECK(selinux_status_open(true /*fallback*/) >= 0);

    CHECK(getcon(&mThisProcessContext) == 0);
#endif
}

Access::~Access() {
    freecon(mThisProcessContext);
}

Access::CallingContext Access::getCallingContext() {
#ifdef __ANDROID__
    IPCThreadState* ipc = IPCThreadState::self();

    const char* callingSid = ipc->getCallingSid();
    pid_t callingPid = ipc->getCallingPid();

    return CallingContext {
        .debugPid = callingPid,
        .uid = ipc->getCallingUid(),
        .sid = callingSid ? std::string(callingSid) : getPidcon(callingPid),
    };
#else
    return CallingContext();
#endif
}

bool Access::canList(const CallingContext& ctx) {
    return actionAllowed(ctx, mThisProcessContext, "list", "service_manager");
}

bool Access::actionAllowed(const CallingContext& sctx, const char* tctx, const char* perm,
        const std::string& tname) {
#ifdef __ANDROID__
    const char* tclass = "service_manager";

    AuditCallbackData data = {
        .context = &sctx,
        .tname = &tname,
    };

    return 0 == selinux_check_access(sctx.sid.c_str(), tctx, tclass, perm,
        reinterpret_cast<void*>(&data));
#else
    return true;
#endif
}

bool Access::actionAllowedFromLookup(const CallingContext& sctx, const std::string& name, const char *perm) {
#ifdef __ANDROID__
    char *tctx = nullptr;
    if (selabel_lookup(getSehandle(), &tctx, name.c_str(), SELABEL_CTX_ANDROID_SERVICE) != 0) {
        LOG(ERROR) << "SELinux: No match for " << name << " in service_contexts.\n";
        return false;
    }

    bool allowed = actionAllowed(sctx, tctx, perm, name);
    freecon(tctx);
    return allowed;
#else
    return true;
#endif
}

}  // android
SRC
    fi
    if [ ! -f frameworks/native/cmds/servicemanager/Access.h ]; then
      cat > frameworks/native/cmds/servicemanager/Access.h <<'SRC'
#pragma once

#include <string>
#include <sys/types.h>

namespace android {

class Access {
public:
    Access();
    virtual ~Access();

    struct CallingContext {
        pid_t debugPid;
        uid_t uid;
        std::string sid;
        std::string toDebugString() const;
    };

    virtual CallingContext getCallingContext();
    virtual bool canList(const CallingContext& ctx);

private:
    bool actionAllowed(const CallingContext& sctx, const char* tctx, const char* perm,
            const std::string& tname);
    bool actionAllowedFromLookup(const CallingContext& sctx, const std::string& name,
            const char *perm);

    char* mThisProcessContext = nullptr;
};

};
SRC
    fi
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
grep -Fq 'IsRoydContainerWithoutSelinux' "$tmp/src/system/core/init/service.cpp"
grep -Fq 'mSkipSelinux = IsRoydContainerWithoutSelinux();' "$tmp/src/frameworks/native/cmds/servicemanager/Access.cpp"
grep -Fq 'CHECK(selinux_status_open(true /*fallback*/) >= 0);' "$tmp/src/frameworks/native/cmds/servicemanager/Access.cpp"
grep -Fq 'selinux_check_access' "$tmp/src/frameworks/native/cmds/servicemanager/Access.cpp"
grep -Fq 'selabel_lookup' "$tmp/src/frameworks/native/cmds/servicemanager/Access.cpp"
test -f "$tmp/repo/.work/android-manifest-15.lock.xml"

# Adding a new patch at the end of an already applied set must not require a
# fresh multi-gigabyte AOSP checkout. Changed or reordered existing patches
# still fail because their prefix digest no longer matches the marker.
cat > "$tmp/repo/android/patches/android-15.0.0_r36/9999-append-only-probe.patch" <<'PATCH'
diff --git a/royd-append-only-probe b/royd-append-only-probe
new file mode 100644
--- /dev/null
+++ b/royd-append-only-probe
@@ -0,0 +1 @@
+ok
PATCH
ROYD_ANDROID_VERSION=15 "$tmp/repo/android/scripts/apply-patches.sh" "$tmp/src" >/dev/null
grep -Fx 'ok' "$tmp/src/royd-append-only-probe" >/dev/null

printf '%s\n' 'Android Repo, Git LFS and local patch sync contract test passed'
