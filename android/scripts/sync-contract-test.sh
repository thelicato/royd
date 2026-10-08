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
    mkdir -p build system/core/init system/vold frameworks/native/cmds/servicemanager \
      frameworks/native/libs/binder/include/binder frameworks/native/libs/binder \
      system/hardware/interfaces/suspend/1.0/default system/security/keystore2/selinux/src \
      system/security/keystore2/src frameworks/base/core/jni frameworks/native/cmds/installd \
      system/logging/logd packages/modules/Connectivity/bpf/loader \
      packages/modules/Connectivity/bpf/netd \
      packages/modules/Connectivity/service/jni \
      packages/modules/Connectivity/service/src/com/android/server system/netd/server \
      packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink \
      packages/modules/Connectivity/Tethering/src/com/android/networkstack/tethering \
      system/core/libprocessgroup/setup system/core/libprocessgroup \
      frameworks/base/services/core/java/com/android/server/am \
      frameworks/base/core/java/android/app
    if [ ! -f system/core/libprocessgroup/setup/cgroup_map_write.cpp ]; then
      cat > system/core/libprocessgroup/setup/cgroup_map_write.cpp <<'SRC'
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <optional>

static bool IsOptionalController(const CgroupController* controller) {
    return controller->flags() & CGROUPRC_CONTROLLER_FLAG_OPTIONAL;
}

static bool MountV2CgroupController(const CgroupDescriptor& descriptor) {
    const CgroupController* controller = descriptor.controller();

    // /sys/fs/cgroup is created by cgroup2 with specific selinux permissions,
    // try to create again in case the mount point is changed
    if (!Mkdir(controller->path(), 0, "", "")) {
        LOG(ERROR) << "Failed to create directory for " << controller->name() << " cgroup";
        return false;
    }

    // The memory_recursiveprot mount option has been introduced by kernel commit
    if (mount("none", controller->path(), "cgroup2", MS_NODEV | MS_NOEXEC | MS_NOSUID,
              "memory_recursiveprot") < 0) {
        return false;
    }
    return true;
}
SRC
    fi
    if [ ! -f system/core/libprocessgroup/cgroup_map.cpp ]; then
      cat > system/core/libprocessgroup/cgroup_map.cpp <<'SRC'
//#define LOG_NDEBUG 0
#define LOG_TAG "libprocessgroup"

#include <errno.h>
#include <unistd.h>

#include <regex>

bool CgroupControllerWrapper::GetTaskGroup(pid_t tid, std::string* group) const {
    std::string file_name = StringPrintf("/proc/%d/cgroup", tid);
    std::string content;
    if (!android::base::ReadFileToString(file_name, &content)) {
        PLOG(ERROR) << "Failed to read " << file_name;
        return false;
    }

    // if group is null and tid exists return early because
    // user is not interested in cgroup membership
    if (group == nullptr) {
        return true;
    }

    std::string cg_tag;

    if (version() == 2) {
        cg_tag = "0::";
    } else {
        cg_tag = StringPrintf(":%s:", name());
    }
    size_t start_pos = content.find(cg_tag);
    if (start_pos == std::string::npos) {
        return false;
    }

    start_pos += cg_tag.length() + 1;  // skip '/'
    size_t end_pos = content.find('\n', start_pos);
    if (end_pos == std::string::npos) {
        *group = content.substr(start_pos, std::string::npos);
    } else {
        *group = content.substr(start_pos, end_pos - start_pos);
    }

    return true;
}
SRC
    fi
    if [ ! -f frameworks/base/core/java/android/app/SystemServiceRegistry.java ]; then
      cat > frameworks/base/core/java/android/app/SystemServiceRegistry.java <<'SRC'
import android.os.ProfilingFrameworkInitializer;
import android.os.RecoverySystem;
import android.os.SecurityStateManager;
import android.os.ServiceManager;
import android.os.ServiceManager.ServiceNotFoundException;
import android.os.StatsFrameworkInitializer;
import android.os.SystemConfigManager;
import android.os.SystemUpdateManager;
import android.os.SystemVibrator;
import android.os.SystemVibratorManager;
import android.os.UserHandle;
import android.os.UserManager;
import android.os.Vibrator;

public final class SystemServiceRegistry {
    private static final String TAG = "SystemServiceRegistry";

    /** @hide */
    public static boolean sEnableServiceNotFoundWtf = false;

    /**
     * After {@link Build.VERSION_CODES.VANILLA_ICE_CREAM}, Wear devices will be allowed to publish
     * no {@link GameManager} instance. This is because the respective system service is no longer
     * started for Wear devices given that the applications of the service do not currently apply to
     * Wear.
     */
    static final long NULL_GAME_MANAGER_IN_WEAR = 340929737;

    public static Object getSystemService(@NonNull ContextImpl ctx, String name) {
        final ServiceFetcher<?> fetcher = getSystemServiceFetcher(name);
        if (fetcher == null) {
            return null;
        }

        final Object ret = fetcher.getService(ctx);
        if (sEnableServiceNotFoundWtf && ret == null) {
            switch (name) {
                case Context.TEXT_SERVICES_MANAGER_SERVICE:
                    if (android.server.Flags.removeTextService()
                            && hasSystemFeatureOpportunistic(ctx, PackageManager.FEATURE_WATCH)) {
                        return null;
                    }
                    break;
            }
            Slog.wtf(TAG, "Manager wrapper not available: " + name);
            return null;
        }
        return ret;
    }

    /** @hide */
    public static void onServiceNotFound(ServiceNotFoundException e) {
        // We're mostly interested in tracking down long-lived core system
        // components that might stumble if they obtain bad references; just
        // emit a tidy log message for normal apps
        if (android.os.Process.myUid() < android.os.Process.FIRST_APPLICATION_UID) {
            Log.wtf(TAG, e.getMessage(), e);
        } else {
            Log.w(TAG, e.getMessage());
        }
    }
}
SRC
    fi
    if [ ! -f frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java ]; then
      cat > frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java <<'SRC'
import android.os.RemoteCallback;
import android.os.RemoteCallbackList;
import android.os.RemoteException;
import android.os.ResultReceiver;
import android.os.ServiceManager;
import android.os.SharedMemory;
import android.os.ShellCallback;

public class ActivityManagerService {
    @SuppressWarnings("DoNotCall")
    public void addErrorToDropBox() {
        // NOTE -- this must never acquire the ActivityManagerService lock,
        // otherwise the watchdog may be prevented from resetting the system.

        // Bail early if not published yet
        final DropBoxManager dbox;
        try {
            dbox = mContext.getSystemService(DropBoxManager.class);
        } catch (Exception e) {
            return;
        }

        final String dropboxTag = processClass(process) + "_" + eventType;
        if (dbox == null || !dbox.isTagEnabled(dropboxTag)) return;
    }
}
SRC
    fi
    if [ ! -f packages/modules/Connectivity/bpf/netd/BpfHandler.cpp ]; then
      cat > packages/modules/Connectivity/bpf/netd/BpfHandler.cpp <<'SRC'
// sync fixture

#include <linux/bpf.h>
#include <inttypes.h>

#include <android-base/unique_fd.h>
#include <android-modules-utils/sdk_level.h>

static Status checkProgramAccessible(const char* programPath) {
    return netdutils::status::ok;
}

static Status initPrograms(const char* cg2_path) {
    if (!cg2_path) return Status("cg2_path is NULL");

    // This code was mainlined in T, so this should be trivially satisfied.
    if (!modules::sdklevel::IsAtLeastT()) return Status("S- platform is unsupported");

    // U bumps the kernel requirement up to 4.14
    if (modules::sdklevel::IsAtLeastU() && !bpf::isAtLeastKernelVersion(4, 14, 0)) {
        return Status("U+ platform with kernel version < 4.14.0 is unsupported");
    }

    // U mandates this mount point (though it should also be the case on T)
    if (modules::sdklevel::IsAtLeastU() && !!strcmp(cg2_path, "/sys/fs/cgroup")) {
        return Status("U+ platform with cg2_path != /sys/fs/cgroup is unsupported");
    }

    unique_fd cg_fd(open(cg2_path, O_DIRECTORY | O_RDONLY | O_CLOEXEC));
    if (!cg_fd.ok()) {
        return Status("Open the cgroup directory failed");
    }
    return netdutils::status::ok;
}
SRC
    fi
    if [ ! -f packages/modules/Connectivity/service/jni/com_android_server_connectivity_ClatCoordinator.cpp ]; then
      cat > packages/modules/Connectivity/service/jni/com_android_server_connectivity_ClatCoordinator.cpp <<'SRC'
/*
 */
#define LOG_TAG "jniClatCoordinator"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/if_packet.h>
#include <linux/if_tun.h>
#include <linux/ioctl.h>
#include <log/log.h>
#include <nativehelper/JNIHelp.h>
#include <net/if.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <string>
#include <unistd.h>

namespace android {

static bool fatal = false;

#define ALOGF(s ...) do { ALOGE(s); fatal = true; } while(0)

enum verify { VERIFY_DIR, VERIFY_BIN, VERIFY_PROG, VERIFY_MAP_RO, VERIFY_MAP_RW };

static void verifyPerms(const char * const path,
                        const mode_t mode, const uid_t uid, const gid_t gid,
                        const char * const ctxt,
                        const verify vtype) {
    struct stat s = {};

    if (lstat(path, &s)) ALOGF("lstat '%s' errno=%d", path, errno);
    if (s.st_mode != mode) ALOGF("'%s' mode is 0%o != 0%o", path, s.st_mode, mode);
    if (s.st_uid != uid) ALOGF("'%s' uid is %d != %d", path, s.st_uid, uid);
    if (s.st_gid != gid) ALOGF("'%s' gid is %d != %d", path, s.st_gid, gid);

    char b[255] = {};
    int v = lgetxattr(path, "security.selinux", &b, sizeof(b));
    if (v < 0) ALOGF("lgetxattr '%s' errno=%d", path, errno);
    if (strncmp(ctxt, b, sizeof(b))) ALOGF("context of '%s' is '%s' != '%s'", path, b, ctxt);

    int fd = -1;

    switch (vtype) {
      case VERIFY_DIR: return;
      case VERIFY_BIN: return;
      case VERIFY_PROG:   fd = bpf::retrieveProgram(path); break;
      case VERIFY_MAP_RO: fd = bpf::mapRetrieveRO(path); break;
      case VERIFY_MAP_RW: fd = bpf::mapRetrieveLocklessRW(path); break;
    }

    if (fd < 0) ALOGF("bpf_obj_get '%s' failed, errno=%d", path, errno);

    if (fd >= 0) close(fd);
}

#undef ALOGF

static void verifyClatPerms() {
    // We might run as part of tests instead of as part of system server
    if (getuid() != AID_SYSTEM) return;

    // First verify the clatd directory and binary,
    // since this is built into the apex file system image,
    // failures here are 99% likely to be build problems.

    if (fatal) abort();
}
SRC
    fi
    if [ ! -f packages/modules/Connectivity/service/src/com/android/server/BpfNetMaps.java ]; then
      cat > packages/modules/Connectivity/service/src/com/android/server/BpfNetMaps.java <<'SRC'
package com.android.server;

import static android.net.INetd.PERMISSION_NONE;
import static android.net.INetd.PERMISSION_UNINSTALLED;
import static android.net.INetd.PERMISSION_UPDATE_DEVICE_STATS;
import static android.system.OsConstants.EINVAL;
import static android.system.OsConstants.ENODEV;
import static android.system.OsConstants.ENOENT;
import static android.system.OsConstants.EOPNOTSUPP;

import static com.android.server.ConnectivityStatsLog.NETWORK_BPF_MAP_INFO;

import com.android.net.module.util.bpf.CookieTagMapValue;
import com.android.net.module.util.bpf.IngressDiscardKey;
import com.android.net.module.util.bpf.IngressDiscardValue;

import java.io.FileDescriptor;
import java.io.IOException;
import java.net.InetAddress;

public class BpfNetMaps {
    static {
        if (SdkLevel.isAtLeastT()) {
            System.loadLibrary("service-connectivity");
        }
    }

    private static final String TAG = "BpfNetMaps";
    private final INetd mNetd;
    private final Dependencies mDeps;
    // Use legacy netd for releases before T.
    private static boolean sInitialized = false;

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    public void swapActiveStatsMap() {
        throwIfPreT("swapActiveStatsMap is not available on pre-T devices");

        try {
            synchronized (sCurrentStatsMapConfigLock) {
                final long config = sConfigurationMap.getValue(
                        CURRENT_STATS_MAP_CONFIGURATION_KEY).val;
                final long newConfig = (config == STATS_SELECT_MAP_A)
                        ? STATS_SELECT_MAP_B : STATS_SELECT_MAP_A;
                sConfigurationMap.updateEntry(CURRENT_STATS_MAP_CONFIGURATION_KEY,
                        new U32(newConfig));
            }
        } catch (ErrnoException e) {
            throw new ServiceSpecificException(e.errno, "Failed to swap active stats map");
        }

        // After changing the config, it's needed to make sure all the current running eBPF
        // programs are finished and all the CPUs are aware of this config change before the old
        // map is modified. So special hack is needed here to wait for the kernel to do a
        // synchronize_rcu(). Once the kernel called synchronize_rcu(), the updated config will
        // be available to all cores and the next eBPF programs triggered inside the kernel will
        // use the new map configuration. So once this function returns it is safe to modify the
        // old stats map without concerning about race between the kernel and userspace.
        final int err = mDeps.synchronizeKernelRCU();
        maybeThrow(err, "synchronizeKernelRCU failed");
    }
}
SRC
    fi
    if [ ! -f system/netd/server/Android.bp ]; then
      cat > system/netd/server/Android.bp <<'SRC'
cc_library_static {
    name: "libnetd_server",
    shared_libs: [
        "libnetdutils",
        "libpcap",
        "libssl",
        "libsysutils",
        "netd_event_listener_interface-V1-cpp",
    ],
}
SRC
    fi
    if [ ! -f system/netd/server/Controllers.cpp ]; then
      cat > system/netd/server/Controllers.cpp <<'SRC'
/*
 */

#include <cinttypes>
#include <regex>
#include <set>
#include <string>

#include <android-base/stringprintf.h>
#include <android-base/strings.h>
#include <netdutils/Stopwatch.h>

#define LOG_TAG "Netd"
#include <log/log.h>

#include "ConnmarkFlags.h"
#include "Controllers.h"
#include "IdletimerController.h"
#include "NetworkController.h"
#include "RouteController.h"
#include "XfrmController.h"
#include "oem_iptables_hook.h"

namespace android {
namespace net {

using android::base::Join;
using android::base::StringAppendF;
using android::base::StringPrintf;
using android::netdutils::Stopwatch;

auto Controllers::execIptablesRestore  = ::execIptablesRestore;
auto Controllers::execIptablesRestoreWithOutput = ::execIptablesRestoreWithOutput;

netdutils::Log gLog("netd");
netdutils::Log gUnsolicitedLog("netdUnsolicited");

namespace {

static constexpr char CONNMARK_MANGLE_INPUT[] = "connmark_mangle_INPUT";
static constexpr char CONNMARK_MANGLE_OUTPUT[] = "connmark_mangle_OUTPUT";

}  // namespace

void Controllers::init() {
    initIptablesRules();
    Stopwatch s;

    if (int ret = bandwidthCtrl.enableBandwidthControl()) {
        gLog.error("Failed to initialize BandwidthController (%s)", strerror(-ret));
        // A failure to init almost definitely means that iptables failed to load
        // our static ruleset, which then basically means network accounting will not work.
        // As such simply exit netd.  This may crash loop the system, but by failing
        // to bootup we will trigger rollback and thus this offers us protection against
        // a mainline update breaking things.
        exit(1);
    }
    gLog.info("Enabling bandwidth control: %" PRId64 "us", s.getTimeAndResetUs());

    if (int ret = RouteController::Init(NetworkController::LOCAL_NET_ID)) {
        gLog.error("Failed to initialize RouteController (%s)", strerror(-ret));
    }
}
SRC
    fi
    if [ ! -f system/netd/server/TetherController.cpp ]; then
      cat > system/netd/server/TetherController.cpp <<'SRC'
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netdb.h>
#include <spawn.h>
#include <string.h>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include <netinet/in.h>
#include <arpa/inet.h>

#include <array>
#include <cstdlib>
#include <regex>
#include <string>
#include <vector>

namespace android {
namespace net {

namespace {

const char BP_TOOLS_MODE[] = "bp-tools";
const char IPV4_FORWARDING_PROC_FILE[] = "/proc/sys/net/ipv4/ip_forward";
const char IPV6_FORWARDING_PROC_FILE[] = "/proc/sys/net/ipv6/conf/all/forwarding";
const char SEPARATOR[] = "|";
constexpr const char kTcpBeLiberal[] = "/proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal";

// Chosen to match AID_DNS_TETHER, as made "friendly" by fs_config_generator.py.
constexpr const char kDnsmasqUsername[] = "dns_tether";

}  // namespace

StatusOr<TetherController::TetherStatsList> TetherController::getTetherStats() {
    TetherStatsList statsList;
    std::string parsedIptablesOutput;

    for (const IptablesTarget target : {V4, V6}) {
        std::string statsString;
        if (int ret = iptablesRestoreFunction(target, GET_TETHER_STATS_COMMAND, &statsString)) {
            return statusFromErrno(-ret, StringPrintf("failed to fetch tether stats (%d): %d",
                                                      target, ret));
        }

        if (int ret = addForwardChainStats(statsList, statsString, parsedIptablesOutput)) {
            return statusFromErrno(-ret, StringPrintf("failed to parse %s tether stats:\n%s",
                                                      target == V4 ? "IPv4": "IPv6",
                                                      parsedIptablesOutput.c_str()));
        }
    }

    return statsList;
}
SRC
    fi
    if [ ! -f packages/modules/Connectivity/Tethering/src/com/android/networkstack/tethering/Tethering.java ]; then
      cat > packages/modules/Connectivity/Tethering/src/com/android/networkstack/tethering/Tethering.java <<'SRC'
package com.android.networkstack.tethering;

import android.content.Context;
import android.content.pm.PackageManager;

import com.android.networkstack.tethering.util.PrefixUtils;
import com.android.networkstack.tethering.util.VersionedBroadcastListener;
import com.android.networkstack.tethering.wear.WearableConnectionManager;

import java.io.FileDescriptor;
import java.io.PrintWriter;
import java.net.InetAddress;

public class Tethering {
    private Context mContext;

    private void disableUsbIpServing(boolean forNcmFunction) {
    }

    private boolean isEthernetSupported() {
        return mContext.getSystemService(Context.ETHERNET_SERVICE) != null;
    }

    void setUsbTethering(boolean enable, IIntResultListener listener) {
        mHandler.post(() -> {
        });
    }

    private boolean hasSystemFeature(final String feature) {
        return mContext.getPackageManager().hasSystemFeature(feature);
    }
}
SRC
    fi
    if [ ! -f packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink/NetlinkUtils.java ]; then
      cat > packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink/NetlinkUtils.java <<'SRC'
package com.android.net.module.util.netlink;

import static android.net.util.SocketUtils.makeNetlinkSocketAddress;
import static android.system.OsConstants.AF_NETLINK;
import static android.system.OsConstants.EIO;
import static android.system.OsConstants.EPROTO;
import static android.system.OsConstants.ETIMEDOUT;
import static android.system.OsConstants.NETLINK_INET_DIAG;
import static android.system.OsConstants.NETLINK_ROUTE;
import static android.system.OsConstants.SOCK_CLOEXEC;
import static android.system.OsConstants.SOCK_DGRAM;
import static android.system.OsConstants.SOL_SOCKET;
import static android.system.OsConstants.SO_RCVBUF;
import static android.system.OsConstants.SO_RCVTIMEO;
import static android.system.OsConstants.SO_SNDTIMEO;

import static com.android.net.module.util.netlink.NetlinkConstants.hexify;
import static com.android.net.module.util.netlink.NetlinkConstants.NLMSG_DONE;
import static com.android.net.module.util.netlink.NetlinkConstants.RTNL_FAMILY_IP6MR;
import static com.android.net.module.util.netlink.StructNlMsgHdr.NLM_F_DUMP;
import static com.android.net.module.util.netlink.StructNlMsgHdr.NLM_F_REQUEST;

import android.net.util.SocketUtils;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructTimeval;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.FileDescriptor;
import java.io.IOException;
import java.io.InterruptedIOException;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.SocketException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.function.Consumer;

public class NetlinkUtils {
    private static final String TAG = "NetlinkUtils";
    /** Corresponds to enum from bionic/libc/include/netinet/tcp.h. */
    private static final int TCP_ESTABLISHED = 1;
    private static final int TCP_SYN_SENT = 2;
    private static final int TCP_SYN_RECV = 3;

    private static <T extends NetlinkMessage> void getAndProcessNetlinkDumpMessagesWithFd(
            FileDescriptor fd, byte[] dumpRequestMessage, int nlFamily, Class<T> msgClass,
            Consumer<T> func)
            throws SocketException, InterruptedIOException, ErrnoException {
        while (true) {
            final ByteBuffer buf = recvMessage(
                    fd, NetlinkUtils.DEFAULT_RECV_BUFSIZE, IO_TIMEOUT_MS);

            while (buf.remaining() > 0) {
                final int position = buf.position();
                final NetlinkMessage nlMsg = NetlinkMessage.parse(buf, nlFamily);
                if (nlMsg == null) {
                    buf.position(position);
                    Log.e(TAG, "Failed to parse netlink message: " + hexify(buf));
                    break;
                }

                if (nlMsg.getHeader().nlmsg_type == NLMSG_DONE) {
                    return;
                }

                if (!msgClass.isInstance(nlMsg)) {
                    Log.wtf(TAG, "Received unexpected netlink message: " + nlMsg);
                    continue;
                }
            }
        }
    }
}
SRC
    fi
    if [ ! -f packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink/InetDiagMessage.java ]; then
      cat > packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink/InetDiagMessage.java <<'SRC'
package com.android.net.module.util.netlink;

import java.io.FileDescriptor;
import java.io.InterruptedIOException;
import java.net.SocketException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;
import java.util.function.Predicate;

public class InetDiagMessage extends NetlinkMessage {
    public static final String TAG = "InetDiagMessage";
    private static final int TIMEOUT_MS = 500;

    private static int processNetlinkDumpAndDestroySockets(byte[] dumpReq,
            FileDescriptor destroyFd, int proto, Predicate<InetDiagMessage> filter)
            throws SocketException, InterruptedIOException, ErrnoException {
        AtomicInteger destroyedSockets = new AtomicInteger(0);
        Consumer<InetDiagMessage> handleNlDumpMsg = (diagMsg) -> {
            if (filter.test(diagMsg)) {
                try {
                    sendNetlinkDestroyRequest(destroyFd, proto, diagMsg);
                    destroyedSockets.getAndIncrement();
                } catch (InterruptedIOException | ErrnoException e) {
                    if (!(e instanceof ErrnoException
                            && ((ErrnoException) e).errno == ENOENT)) {
                        Log.e(TAG, "Failed to destroy socket: diagMsg=" + diagMsg + ", " + e);
                    }
                }
            }
        };

        NetlinkUtils.<InetDiagMessage>getAndProcessNetlinkDumpMessages(dumpReq,
                NETLINK_INET_DIAG, InetDiagMessage.class, handleNlDumpMsg);
        return destroyedSockets.get();
    }
}
SRC
    fi
    if [ ! -f packages/modules/Connectivity/bpf/loader/Android.bp ]; then
      cat > packages/modules/Connectivity/bpf/loader/Android.bp <<'SRC'
cc_binary {
    name: "netbpfload",
    shared_libs: [
        "libbase",
        "liblog",
    ],
    srcs: ["NetBpfLoad.cpp"],
}
SRC
    fi
    if [ ! -f packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp ]; then
      cat > packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp <<'SRC'
static bool exists(const char* const path) {
    int v = access(path, F_OK);
    if (!v) return true;
    if (errno == ENOENT) return false;
    ALOGE("FATAL: access(%s, F_OK) -> %d [%d:%s]", path, v, errno, strerror(errno));
    abort();  // can only hit this if permissions (likely selinux) are screwed up
}

#define APEXROOT "/apex/com.android.tethering"
#define BPFROOT APEXROOT "/etc/bpf"

static int doLoad(char** argv, char * const envp[]) {
    if (!isEng() && !isUser() && !isUserdebug()) {
        ALOGE("Failed to determine the build type");
        return 1;
    }

    if (runningAsRoot) {
        // Note: writing this proc file requires being root (always the case on V+)

        // Linux 5.16-rc1 changed the default to 2 (disabled but changeable),
        // but we need 0 (enabled)
        if (writeProcSysFile("/proc/sys/kernel/unprivileged_bpf_disabled", "0\n") &&
            isAtLeastKernelVersion(5, 13, 0)) return 1;
    }

    if (isAtLeastU) {
        // Note: writing these proc files requires CAP_NET_ADMIN
        // and sepolicy which is only present on U+,
        // on Android T and earlier versions they're written from the 'load_bpf_programs'
        if (writeProcSysFile("/proc/sys/net/core/bpf_jit_enable", "1\n")) return 1;
        if (writeProcSysFile("/proc/sys/net/core/bpf_jit_kallsyms", "1\n")) return 1;
    }

    for (const auto& location : locations) {
        if (createSysFsBpfSubDir(location.prefix)) return 1;
    }
    for (const auto& location : locations) {
        if (loadAllElfObjects(bpfloader_ver, location) != 0) return 2;
    }
    return 0;
}
SRC
    fi
    if [ ! -f system/logging/logd/Android.bp ]; then
      cat > system/logging/logd/Android.bp <<'SRC'
cc_binary {
    name: "logd",
    shared_libs: [
        "libbinder",
        "libsysutils",
        "libcutils",
        "libpackagelistparser",
        "libprocessgroup",
        "libcap",
        "libutils",
    ],
}
SRC
    fi
    if [ ! -f system/logging/logd/main.cpp ]; then
      cat > system/logging/logd/main.cpp <<'SRC'
#include <private/android_filesystem_config.h>
#include <private/android_logger.h>
#include <processgroup/sched_policy.h>
#include <utils/threads.h>

using android::base::SetProperty;

#define KMSG_PRIORITY(PRI)                                 \
    '<', '0' + LOG_MAKEPRI(LOG_DAEMON, LOG_PRI(PRI)) / 10, \
        '0' + LOG_MAKEPRI(LOG_DAEMON, LOG_PRI(PRI)) % 10, '>'

// The service is designed to be run by init, it does not respond well to starting up manually. Init
// has a 'sigstop' feature that sends SIGSTOP to a service immediately before calling exec().  This
// allows debuggers, etc to be attached to logd at the very beginning, while still having init
// handle the user, groups, capabilities, files, etc setup.
static void DropPrivs(bool klogd, bool auditd) {
    if (set_sched_policy(0, SP_BACKGROUND) < 0) {
        PLOG(FATAL) << "failed to set background scheduling policy";
    }
}
SRC
    fi
    if [ ! -f frameworks/base/core/jni/android_os_Debug.cpp ]; then
      cat > frameworks/base/core/jni/android_os_Debug.cpp <<'SRC'
#include <memunreachable/memunreachable.h>
#include <nativehelper/JNIPlatformHelp.h>
#include <nativehelper/ScopedUtfChars.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static jboolean android_os_Debug_isVmapStack(JNIEnv *env, jobject clazz)
{
    static enum {
        CONFIG_UNKNOWN,
        CONFIG_SET,
        CONFIG_UNSET,
    } cfg_state = CONFIG_UNKNOWN;

    if (cfg_state == CONFIG_UNKNOWN) {
        std::map<std::string, std::string> configs;
        const status_t result = android::kernelconfigs::LoadKernelConfigs(&configs);
        CHECK(result == OK) << "Kernel configs could not be fetched. b/151092221";
        std::map<std::string, std::string>::const_iterator it = configs.find("CONFIG_VMAP_STACK");
        cfg_state = (it != configs.end() && it->second == "y") ? CONFIG_SET : CONFIG_UNSET;
    }
    return cfg_state == CONFIG_SET;
}
SRC
    fi
    if [ ! -f frameworks/native/cmds/installd/InstalldNativeService.cpp ]; then
      cat > frameworks/native/cmds/installd/InstalldNativeService.cpp <<'SRC'
#include <private/android_filesystem_config.h>
#include <private/android_projectid_config.h>
#include <selinux/android.h>
#include <system/thread_defs.h>
#include <utils/Trace.h>

constexpr const char kXattrRestoreconInProgress[] = "user.restorecon_in_progress";

static std::string lgetfilecon(const std::string& path) {
    char* context;
    if (::lgetfilecon(path.c_str(), &context) < 0) {
        PLOG(ERROR) << "Failed to lgetfilecon for " << path;
        return {};
    }
    std::string result{context};
    free(context);
    return result;
}

static int restorecon_app_data_lazy(const std::string& path, const std::string& seInfo, uid_t uid,
        bool existing) {
    ScopedTrace tracer("restorecon-lazy");
    if (!existing) {
        ScopedTrace tracer("new-path");
        if (selinux_android_restorecon_pkgdir(path.c_str(), seInfo.c_str(), uid,
                SELINUX_ANDROID_RESTORECON_RECURSE) < 0) {
            PLOG(ERROR) << "Failed recursive restorecon for " << path;
            return -1;
        }
        return 0;
    }

    // Note that SELINUX_ANDROID_RESTORECON_DATADATA flag is set by libselinux. Not needed here.

    // Check to see if there was an interrupted operation.
    bool inProgress = getRestoreconInProgress(path);
    std::string before, after;
    if (!inProgress) {
        if (before = lgetfilecon(path); before.empty()) {
            PLOG(ERROR) << "Failed before getfilecon for " << path;
            return -1;
        }
        if (selinux_android_restorecon_pkgdir(path.c_str(), seInfo.c_str(), uid, 0) < 0) {
            PLOG(ERROR) << "Failed top-level restorecon for " << path;
            return -1;
        }
        if (after = lgetfilecon(path); after.empty()) {
            PLOG(ERROR) << "Failed after getfilecon for " << path;
            return -1;
        }
    }

    if (inProgress || before != after) {
        return runRecursiveRestorecon(path, seInfo, uid);
    }
    return 0;
}
SRC
    fi
    if [ ! -f frameworks/base/core/jni/com_android_internal_os_Zygote.cpp ]; then
      cat > frameworks/base/core/jni/com_android_internal_os_Zygote.cpp <<'SRC'
#include <processgroup/sched_policy.h>
#include <seccomp_policy.h>
#include <selinux/android.h>
#include <stats_socket.h>
#include <utils/String8.h>
#include <utils/Trace.h>

static bool gIsSecurityEnforced = true;

/**
 * True if the app process is running in its mount namespace.
 */
static bool gInAppMountNamespace = false;

/**
 * The maximum number of characters (not including a null terminator) that a
 * process name may contain.
 */

static void isolateAppData() {
  snprintf(internalDePath, PATH_MAX, "/data/user_de");
  snprintf(externalPrivateMountPath, PATH_MAX, "/mnt/expand");

  // Get the "u:object_r:system_userdir_file:s0" security context.  This can be
  // gotten from several different places; we use /data/user.
  char* dataUserdirContext = nullptr;
  if (getfilecon(internalCePath, &dataUserdirContext) < 0) {
    fail_fn(CREATE_ERROR("Unable to getfilecon on %s %s", internalCePath,
        strerror(errno)));
  }
  // Get the "u:object_r:system_data_file:s0" security context.  This can be
  // gotten from several different places; we use /data/misc.
  char* dataFileContext = nullptr;
  if (getfilecon("/data/misc", &dataFileContext) < 0) {
    fail_fn(CREATE_ERROR("Unable to getfilecon on /data/misc %s", strerror(errno)));
  }

  MountAppDataTmpFs(internalLegacyCePath, fail_fn);

      }
  }

  // We set the label AFTER everything is done, as we are applying
  // the file operations on tmpfs. If we set the label when we mount
  // tmpfs, SELinux will not happy as we are changing system_data_files.
  // Relabel dir under /data/user, including /data/user/0
  relabelSubdirs(internalCePath, dataFileContext, fail_fn);

  // Relabel /data/user
  relabelDir(internalCePath, dataUserdirContext, fail_fn);

  // Relabel /data/data
  relabelDir(internalLegacyCePath, dataFileContext, fail_fn);

  // Relabel subdirectories of /data/user_de
  relabelSubdirs(internalDePath, dataFileContext, fail_fn);

  // Relabel /data/user_de
  relabelDir(internalDePath, dataUserdirContext, fail_fn);

  // Relabel CE and DE dirs under /mnt/expand
  dir = opendir(externalPrivateMountPath);
  if (dir == nullptr) {
    fail_fn(CREATE_ERROR("Failed to opendir %s", externalPrivateMountPath));
  }
  while ((ent = readdir(dir))) {
    if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
    auto volPath = StringPrintf("%s/%s", externalPrivateMountPath, ent->d_name);
    auto cePath = StringPrintf("%s/user", volPath.c_str());
    auto dePath = StringPrintf("%s/user_de", volPath.c_str());

    relabelSubdirs(cePath.c_str(), dataFileContext, fail_fn);
    relabelDir(cePath.c_str(), dataUserdirContext, fail_fn);
    relabelSubdirs(dePath.c_str(), dataFileContext, fail_fn);
    relabelDir(dePath.c_str(), dataUserdirContext, fail_fn);
  }
  closedir(dir);

  freecon(dataUserdirContext);
  freecon(dataFileContext);
}

static void SpecializeCommon() {
    if (is_system_server) {
        env->CallStaticVoidMethod(gZygoteClass, gCallPostForkSystemServerHooks, runtime_flags);
        if (env->ExceptionCheck()) {
            fail_fn("Error calling post fork system server hooks.");
        }

        // TODO(b/117874058): Remove hardcoded label here.
        static const char* kSystemServerLabel = "u:r:system_server:s0";
        if (selinux_android_setcon(kSystemServerLabel) != 0) {
            fail_fn(CREATE_ERROR("selinux_android_setcon(%s)", kSystemServerLabel));
        }
    }
}

/**
 * Next declaration.
 */
SRC
    fi
    if [ ! -f system/hardware/interfaces/suspend/1.0/default/Android.bp ]; then
      cat > system/hardware/interfaces/suspend/1.0/default/Android.bp <<'SRC'
cc_defaults {
    name: "system_suspend_defaults",
    shared_libs: [
        "libcutils",
        "libhidlbase",
        "liblog",
        "libutils",
        "server_configurable_flags",
    ],
}
SRC
    fi
    if [ ! -f system/hardware/interfaces/suspend/1.0/default/main.cpp ]; then
      cat > system/hardware/interfaces/suspend/1.0/default/main.cpp <<'SRC'
#include <binder/IServiceManager.h>
#include <binder/ProcessState.h>
#include <cutils/native_handle.h>
#include <fcntl.h>
#include <hidl/HidlTransportSupport.h>
#include <hwbinder/ProcessState.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>

static constexpr uint32_t kDefaultShortSuspendThresholdMillis = 0;
static constexpr bool kDefaultFailedSuspendBackoffEnabled = true;
static constexpr bool kDefaultShortSuspendBackoffEnabled = false;

int main() {
    unique_fd wakeupCountFd{TEMP_FAILURE_RETRY(open(kSysPowerWakeupCount, O_CLOEXEC | O_RDWR))};
    if (wakeupCountFd < 0) {
        PLOG(ERROR) << "error opening " << kSysPowerWakeupCount;
    }
    unique_fd stateFd{TEMP_FAILURE_RETRY(open(kSysPowerState, O_CLOEXEC | O_RDWR))};
    if (stateFd < 0) {
        PLOG(ERROR) << "error opening " << kSysPowerState;
    }
    unique_fd kernelWakelockStatsFd{
        TEMP_FAILURE_RETRY(open(kSysClassWakeup, O_DIRECTORY | O_CLOEXEC | O_RDONLY))};

    // If either /sys/power/wakeup_count or /sys/power/state fail to open, we construct
    // SystemSuspend with blocking fds. This way this process will keep running, handle wake lock
    // requests, collect stats, but won't suspend the device. We want this behavior on devices
    // (hosts) where system suspend should not be handles by Android platform e.g. ARC++, Android
    // virtual devices.
    if (wakeupCountFd < 0 || stateFd < 0) {
        // This will block all reads/writes to these fds from the suspend thread.
        Socketpair(SOCK_STREAM, &wakeupCountFd, &stateFd);
    }
}
SRC
    fi
    if [ ! -f system/security/keystore2/selinux/src/lib.rs ]; then
      cat > system/security/keystore2/selinux/src/lib.rs <<'SRC'
fn init_logger_once() {
    SELINUX_LOG_INIT.call_once(redirect_selinux_logs_to_logcat)
}

/// Selinux Error code.
#[derive(thiserror::Error, Debug, PartialEq, Eq)]
pub enum Error {
    /// Indicates that an access check yielded no access.
    #[error("Permission Denied")]
    PermissionDenied,
}
SRC
    fi
    if [ ! -f system/security/keystore2/src/apc.rs ]; then
      cat > system/security/keystore2/src/apc.rs <<'SRC'
impl ApcManager {
    pub fn new_native_binder(
        confirmation_token_sender: Sender<Vec<u8>>,
    ) -> Result<Strong<dyn IProtectedConfirmation>> {
        Ok(BnProtectedConfirmation::new_binder(
            Self { state: Arc::new(Mutex::new(ApcState::new(confirmation_token_sender))) },
            BinderFeatures { set_requesting_sid: true, ..BinderFeatures::default() },
        ))
    }
}
SRC
    fi
    if [ ! -f system/security/keystore2/src/authorization.rs ]; then
      cat > system/security/keystore2/src/authorization.rs <<'SRC'
impl AuthorizationManager {
    pub fn new_native_binder() -> Result<Strong<dyn IKeystoreAuthorization>> {
        Ok(BnKeystoreAuthorization::new_binder(
            Self,
            BinderFeatures { set_requesting_sid: true, ..BinderFeatures::default() },
        ))
    }
}
SRC
    fi
    if [ ! -f system/security/keystore2/src/km_compat.rs ]; then
      cat > system/security/keystore2/src/km_compat.rs <<'SRC'
    fn wrap() {

        Ok(BnKeyMintDevice::new_binder(
            Self { real, soft, emu },
            BinderFeatures { set_requesting_sid: true, ..BinderFeatures::default() },
        ))
    }
}
SRC
    fi
    if [ ! -f system/security/keystore2/src/maintenance.rs ]; then
      cat > system/security/keystore2/src/maintenance.rs <<'SRC'
impl Maintenance {
    pub fn new_native_binder(
        delete_listener: Box<dyn DeleteListener + Send + Sync + 'static>,
    ) -> Result<Strong<dyn IKeystoreMaintenance>> {
        Ok(BnKeystoreMaintenance::new_binder(
            Self { delete_listener },
            BinderFeatures { set_requesting_sid: true, ..BinderFeatures::default() },
        ))
    }
}
SRC
    fi
    if [ ! -f system/security/keystore2/src/metrics.rs ]; then
      cat > system/security/keystore2/src/metrics.rs <<'SRC'
impl Metrics {
    pub fn new_native_binder() -> Result<Strong<dyn IKeystoreMetrics>> {
        Ok(BnKeystoreMetrics::new_binder(
            Self,
            BinderFeatures { set_requesting_sid: true, ..BinderFeatures::default() },
        ))
    }
}
SRC
    fi
    if [ ! -f system/security/keystore2/src/operation.rs ]; then
      cat > system/security/keystore2/src/operation.rs <<'SRC'
impl KeystoreOperation {
    pub fn new_native_binder(operation: Arc<Operation>) -> binder::Strong<dyn IKeystoreOperation> {
        BnKeystoreOperation::new_binder(
            Self { operation: Mutex::new(Some(operation)) },
            BinderFeatures { set_requesting_sid: true, ..BinderFeatures::default() },
        )
    }
}
SRC
    fi
    if [ ! -f system/security/keystore2/src/security_level.rs ]; then
      cat > system/security/keystore2/src/security_level.rs <<'SRC'
        let result = BnKeystoreSecurityLevel::new_binder(
            Self {
                security_level,
                keymint: dev,
                hw_info,
                km_uuid,
                operation_db: OperationDb::new(),
                rem_prov_state: RemProvState::new(security_level),
                id_rotation_state,
            },
            BinderFeatures { set_requesting_sid: true, ..BinderFeatures::default() },
        );
        Ok((result, km_uuid))
    }
SRC
    fi
    if [ ! -f system/security/keystore2/src/service.rs ]; then
      cat > system/security/keystore2/src/service.rs <<'SRC'
impl KeystoreService {

        Ok(BnKeystoreService::new_binder(
            result,
            BinderFeatures { set_requesting_sid: true, ..BinderFeatures::default() },
        ))
    }

SRC
    fi
    if [ ! -f system/security/keystore2/src/utils.rs ]; then
      cat > system/security/keystore2/src/utils.rs <<'SRC'
use android_system_keystore2::aidl::android::system::keystore2::{
    Authorization::Authorization, Domain::Domain, KeyDescriptor::KeyDescriptor,
    ResponseCode::ResponseCode,
};
use anyhow::{Context, Result};
use binder::{FromIBinder, StatusCode, Strong, ThreadState};
use keystore2_apc_compat::{
    ApcCompatUiOptions, APC_COMPAT_ERROR_ABORTED, APC_COMPAT_ERROR_CANCELLED,
    APC_COMPAT_ERROR_IGNORED, APC_COMPAT_ERROR_OK, APC_COMPAT_ERROR_OPERATION_PENDING,
};

#[cfg(test)]
mod tests;

/// Per RFC 5280 4.1.2.5, an undefined expiration (not-after) field should be set to GeneralizedTime
/// 999912312359559, which is 253402300799000 ms from Jan 1, 1970.
pub const UNDEFINED_NOT_AFTER: i64 = 253402300799000i64;

/// This function uses its namesake in the permission module and in
/// combination with with_calling_sid from the binder crate to check
/// if the caller has the given keystore permission.
pub fn check_keystore_permission(perm: KeystorePerm) -> anyhow::Result<()> {
    ThreadState::with_calling_sid(|calling_sid| {
        permission::check_keystore_permission(
            calling_sid
                .ok_or_else(Error::sys)
                .context(ks_err!("Cannot check permission without calling_sid."))?,
            perm,
        )
    })
}

/// This function uses its namesake in the permission module and in
/// combination with with_calling_sid from the binder crate to check
/// if the caller has the given grant permission.
pub fn check_grant_permission(access_vec: KeyPermSet, key: &KeyDescriptor) -> anyhow::Result<()> {
    ThreadState::with_calling_sid(|calling_sid| {
        permission::check_grant_permission(
            ThreadState::get_calling_uid(),
            calling_sid
                .ok_or_else(Error::sys)
                .context(ks_err!("Cannot check permission without calling_sid."))?,
            access_vec,
            key,
        )
    })
}

/// This function uses its namesake in the permission module and in
/// combination with with_calling_sid from the binder crate to check
/// if the caller has the given key permission.
pub fn check_key_permission(
    perm: KeyPerm,
    key: &KeyDescriptor,
    access_vector: &Option<KeyPermSet>,
) -> anyhow::Result<()> {
    ThreadState::with_calling_sid(|calling_sid| {
        permission::check_key_permission(
            ThreadState::get_calling_uid(),
            calling_sid
                .ok_or_else(Error::sys)
                .context(ks_err!("Cannot check permission without calling_sid."))?,
            perm,
            key,
            access_vector,
        )
    })
}
SRC
    fi
    if [ ! -f system/vold/Utils.cpp ]; then
      cat > system/vold/Utils.cpp <<'SRC'
#include <logwrap/logwrap.h>
#include <private/android_filesystem_config.h>
#include <private/android_projectid_config.h>

#include <dirent.h>
#include <fcntl.h>

status_t PrepareDir(const std::string& path, mode_t mode, uid_t uid, gid_t gid,
                    unsigned int attrs) {
    std::lock_guard<std::mutex> lock(kSecurityLock);
    const char* cpath = path.c_str();
    auto clearfscreatecon = android::base::make_scope_guard([] { setfscreatecon(nullptr); });
    auto secontext = std::unique_ptr<char, void (*)(char*)>(nullptr, freecon);
    char* tmp_secontext;

    if (selabel_lookup(sehandle, &tmp_secontext, cpath, S_IFDIR) == 0) {
        secontext.reset(tmp_secontext);
        if (setfscreatecon(secontext.get()) != 0) {
            LOG(ERROR) << "Failed to setfscreatecon for directory " << path;
            return -EINVAL;
        }
    } else if (errno == ENOENT) {
        LOG(DEBUG) << "No selabel defined for directory " << path;
    }
}
SRC
    fi
    if [ ! -f system/vold/vold_prepare_subdirs.cpp ]; then
      cat > system/vold/vold_prepare_subdirs.cpp <<'SRC'

#include <cutils/fs.h>
#include <selinux/android.h>

#include "Utils.h"
#include "android/os/IVold.h"

#include <private/android_filesystem_config.h>

static void usage(const char* progname) {
    std::cerr << "Usage: " << progname << " [ prepare | destroy ] <volume_uuid> <user_id> <flags>"
              << std::endl;
}

static bool prepare_dir_for_user(struct selabel_handle* sehandle, mode_t mode, uid_t uid, gid_t gid,
                                 const std::string& path, uid_t user_id) {
    auto clearfscreatecon = android::base::make_scope_guard([] { setfscreatecon(nullptr); });
    auto secontext = std::unique_ptr<char, void (*)(char*)>(nullptr, freecon);
    char* tmp_secontext;

    if (selabel_lookup(sehandle, &tmp_secontext, path.c_str(), S_IFDIR) == 0) {
        secontext.reset(tmp_secontext);
        if (user_id != (uid_t)-1) {
            if (selinux_android_context_with_level(secontext.get(), &tmp_secontext, user_id,
                                                   (uid_t)-1) != 0) {
                PLOG(ERROR) << "Unable to create context with level for: " << path;
                return false;
            }
            secontext.reset(tmp_secontext);
        }
        if (setfscreatecon(secontext.get()) != 0) {
            LOG(ERROR) << "Failed to setfscreatecon for directory " << path;
            return false;
        }
    } else if (errno == ENOENT) {
        LOG(DEBUG) << "No selabel defined for directory " << path;
    }

    LOG(DEBUG) << "Setting up mode " << std::oct << mode << std::dec << " uid " << uid << " gid "
               << gid << " context " << (secontext ? secontext.get() : "null")
               << " on path: " << path;
    if (fs_prepare_dir(path.c_str(), mode, uid, gid) != 0) {
        return false;
    }
    if (secontext) {
        char* tmp_oldsecontext = nullptr;
        if (lgetfilecon(path.c_str(), &tmp_oldsecontext) < 0) {
            PLOG(ERROR) << "Unable to read secontext for: " << path;
            return false;
        }
    }
    return true;
}
SRC
    fi
    if [ ! -f system/core/init/util.cpp ]; then
      cat > system/core/init/util.cpp <<'SRC'
#include <android-base/unique_fd.h>
#include <cutils/sockets.h>
#include <selinux/android.h>

#if defined(__ANDROID__)
#include <fs_mgr.h>
#endif
SRC
      padding=0
      while [ "$padding" -lt 641 ]; do
        printf '%s\n' '// sync fixture padding' >> system/core/init/util.cpp
        padding=$((padding + 1))
      done
      cat >> system/core/init/util.cpp <<'SRC'
// access any fds that it opens, including the one opened below for /dev/null.  Therefore,
// SetStdioToDevNull() must be called again in second stage init.
void SetStdioToDevNull(char** argv) {
    // Make stdin/stdout/stderr all point to /dev/null.
    int fd = open("/dev/null", O_RDWR);  // NOLINT(android-cloexec-open)
    if (fd == -1) {
        int saved_errno = errno;
        android::base::InitLogging(argv, &android::base::KernelLogger, InitAborter);
        errno = saved_errno;
        PLOG(FATAL) << "Couldn't open /dev/null";
    }
    dup2(fd, STDIN_FILENO);
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    if (fd > STDERR_FILENO) close(fd);
}

void InitKernelLogging(char** argv) {
SRC
    fi
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
    virtual bool canFind(const CallingContext& ctx, const std::string& name);
    virtual bool canAdd(const CallingContext& ctx, const std::string& name);
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
    if [ ! -f frameworks/native/libs/binder/include/binder/ProcessState.h ]; then
      cat > frameworks/native/libs/binder/include/binder/ProcessState.h <<'SRC'
#pragma once

namespace android {

class ProcessState {
public:
    LIBBINDER_EXPORTED void startThreadPool();

    [[nodiscard]] LIBBINDER_EXPORTED bool becomeContextManager();

    LIBBINDER_EXPORTED sp<IBinder> getStrongProxyForHandle(int32_t handle);
    LIBBINDER_EXPORTED void expungeHandle(int32_t handle, IBinder* binder);
};

}  // namespace android
SRC
    fi
    if [ ! -f frameworks/native/libs/binder/ProcessState.cpp ]; then
      cat > frameworks/native/libs/binder/ProcessState.cpp <<'SRC'
void ProcessState::startThreadPool()
{
    std::unique_lock<std::mutex> _l(mLock);
    if (!mThreadPoolStarted) {
        if (mMaxThreads == 0) {
            ALOGW("Extra binder thread started, but 0 threads requested. Do not use "
                  "*startThreadPool when zero threads are requested.");
        }
        mThreadPoolStarted = true;
        spawnPooledThread(true);
    }
}

bool ProcessState::becomeContextManager()
{
    std::unique_lock<std::mutex> _l(mLock);

    flat_binder_object obj {
        .flags = FLAT_BINDER_FLAG_TXN_SECURITY_CTX,
    };

    int result = ioctl(mDriverFD, BINDER_SET_CONTEXT_MGR_EXT, &obj);

    // fallback to original method
    if (result != 0) {
        android_errorWriteLog(0x534e4554, "121035042");

        int unused = 0;
        result = ioctl(mDriverFD, BINDER_SET_CONTEXT_MGR, &unused);
    }

    if (result == -1) {
        ALOGE("Binder ioctl to become context manager failed: %s\n", strerror(errno));
    }

    return result == 0;
}
SRC
    fi
    if [ ! -f frameworks/native/cmds/servicemanager/main.cpp ]; then
      cat > frameworks/native/cmds/servicemanager/main.cpp <<'SRC'
int main(int argc, char** argv) {
    const char* driver = argc == 2 ? argv[1] : "/dev/binder";

    LOG(INFO) << "Starting sm instance on " << driver;

    sp<ProcessState> ps = ProcessState::initWithDriver(driver);
    ps->setThreadPoolMaxThreadCount(0);
    ps->setCallRestriction(ProcessState::CallRestriction::FATAL_IF_NOT_ONEWAY);

    IPCThreadState::self()->disableBackgroundScheduling(true);

    sp<ServiceManager> manager = sp<ServiceManager>::make(std::make_unique<Access>());
    manager->setRequestingSid(true);
    if (!manager->addService("manager", manager, false /*allowIsolated*/, IServiceManager::DUMP_FLAG_PRIORITY_DEFAULT).isOk()) {
        LOG(ERROR) << "Could not self register servicemanager";
    }

    IPCThreadState::self()->setTheContextObject(manager);
    if (!ps->becomeContextManager()) {
        LOG(FATAL) << "Could not become context manager";
    }

    sp<Looper> looper = Looper::prepare(false /*allowNonCallbacks*/);
}
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
grep -Fq '#include <selinux/selinux.h>' "$tmp/src/system/core/init/util.cpp"
grep -Fq 'const bool preserve_container_output = royd_container != nullptr &&' \
  "$tmp/src/system/core/init/util.cpp"
grep -Fq 'strcmp(royd_container, "1") == 0 && is_selinux_enabled() <= 0;' \
  "$tmp/src/system/core/init/util.cpp"
grep -Fq 'if (!preserve_container_output) {' "$tmp/src/system/core/init/util.cpp"
grep -Fq 'dup2(fd, STDIN_FILENO);' "$tmp/src/system/core/init/util.cpp"
grep -Fq 'mSkipSelinux = IsRoydContainerWithoutSelinux();' "$tmp/src/frameworks/native/cmds/servicemanager/Access.cpp"
grep -Fq 'CHECK(selinux_status_open(true /*fallback*/) >= 0);' "$tmp/src/frameworks/native/cmds/servicemanager/Access.cpp"
grep -Fq 'selinux_check_access' "$tmp/src/frameworks/native/cmds/servicemanager/Access.cpp"
grep -Fq 'selabel_lookup' "$tmp/src/frameworks/native/cmds/servicemanager/Access.cpp"
grep -Fq 'bool usesSelinux() const { return !mSkipSelinux; }' "$tmp/src/frameworks/native/cmds/servicemanager/Access.h"
grep -Fq '[[nodiscard]] LIBBINDER_EXPORTED bool becomeContextManager();' "$tmp/src/frameworks/native/libs/binder/include/binder/ProcessState.h"
grep -Fq '[[nodiscard]] LIBBINDER_EXPORTED bool becomeContextManager(bool requestSecurityContext);' "$tmp/src/frameworks/native/libs/binder/include/binder/ProcessState.h"
grep -Fq 'return becomeContextManager(true);' "$tmp/src/frameworks/native/libs/binder/ProcessState.cpp"
grep -Fq '.flags = static_cast<__u32>(requestSecurityContext ? FLAT_BINDER_FLAG_TXN_SECURITY_CTX : 0),' "$tmp/src/frameworks/native/libs/binder/ProcessState.cpp"
grep -Fq 'const bool requestSecurityContext = access->usesSelinux();' "$tmp/src/frameworks/native/cmds/servicemanager/main.cpp"
grep -Fq 'manager->setRequestingSid(requestSecurityContext);' "$tmp/src/frameworks/native/cmds/servicemanager/main.cpp"
grep -Fq 'ps->becomeContextManager(requestSecurityContext)' "$tmp/src/frameworks/native/cmds/servicemanager/main.cpp"
grep -Fq 'saved_errno == EINVAL' "$tmp/src/system/vold/Utils.cpp"
grep -Fq 'is_selinux_enabled() <= 0' "$tmp/src/system/vold/Utils.cpp"
grep -Fq 'static bool is_royd_selinux_disabled()' "$tmp/src/system/vold/vold_prepare_subdirs.cpp"
grep -Fq 'if (secontext && !is_royd_selinux_disabled()) {' \
  "$tmp/src/system/vold/vold_prepare_subdirs.cpp"
grep -Fq '"libselinux",' \
  "$tmp/src/system/hardware/interfaces/suspend/1.0/default/Android.bp"
grep -Fq 'const bool disableHostSuspend = isRoydContainerWithoutSelinux();' \
  "$tmp/src/system/hardware/interfaces/suspend/1.0/default/main.cpp"
grep -Fq 'if (disableHostSuspend || wakeupCountFd < 0 || stateFd < 0) {' \
  "$tmp/src/system/hardware/interfaces/suspend/1.0/default/main.cpp"
grep -Fq 'pub fn is_selinux_enabled() -> i32 {' \
  "$tmp/src/system/security/keystore2/selinux/src/lib.rs"
[ "$(grep -R -c 'crate::utils::binder_features(BinderFeatures {' \
  "$tmp/src/system/security/keystore2/src"/*.rs | awk -F: '{sum += $2} END {print sum + 0}')" -eq 8 ]
grep -Fq 'fn royd_missing_sid_fallback_enabled() -> bool {' \
  "$tmp/src/system/security/keystore2/src/utils.rs"
grep -Fq 'matches!(perm, KeystorePerm::Unlock | KeystorePerm::ChangeUser)' \
  "$tmp/src/system/security/keystore2/src/utils.rs"
grep -Fq 'key.nspace == LOCK_SETTINGS_NAMESPACE' \
  "$tmp/src/system/security/keystore2/src/utils.rs"
grep -Fq 'missing-SID grant permission fallback' \
  "$tmp/src/system/security/keystore2/src/utils.rs"
grep -Fq '#include <selinux/selinux.h>' \
  "$tmp/src/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp"
grep -Fq 'static bool IsRoydContainerWithoutSelinux() {' \
  "$tmp/src/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp"
grep -Fq 'const bool skip_selinux_labelling = IsRoydContainerWithoutSelinux();' \
  "$tmp/src/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp"
grep -Fq 'ROYD: skipping app-data SELinux context copy and relabelling' \
  "$tmp/src/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp"
grep -Fq 'MountAppDataTmpFs(internalLegacyCePath, fail_fn);' \
  "$tmp/src/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp"
grep -Fq 'if (!skip_selinux_labelling) {' \
  "$tmp/src/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp"
grep -Fq 'if (IsRoydContainerWithoutSelinux()) {' \
  "$tmp/src/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp"
grep -Fq 'ROYD: skipping system_server setcon because ROYD_CONTAINER=1 and kernel' \
  "$tmp/src/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp"
grep -Fq '} else if (selinux_android_setcon(kSystemServerLabel) != 0) {' \
  "$tmp/src/frameworks/base/core/jni/com_android_internal_os_Zygote.cpp"
grep -Fq '#include <selinux/selinux.h>' \
  "$tmp/src/frameworks/base/core/jni/android_os_Debug.cpp"
grep -Fq 'if (result != OK && royd_container != nullptr && strcmp(royd_container, "1") == 0 &&' \
  "$tmp/src/frameworks/base/core/jni/android_os_Debug.cpp"
grep -Fq 'ROYD: /proc/config.gz unavailable with kernel SELinux disabled;' \
  "$tmp/src/frameworks/base/core/jni/android_os_Debug.cpp"
grep -Fq 'CHECK(result == OK) << "Kernel configs could not be fetched. b/151092221";' \
  "$tmp/src/frameworks/base/core/jni/android_os_Debug.cpp"
grep -Fq '#include <selinux/selinux.h>' \
  "$tmp/src/frameworks/native/cmds/installd/InstalldNativeService.cpp"
grep -Fq 'static bool isRoydContainerWithoutSelinux() {' \
  "$tmp/src/frameworks/native/cmds/installd/InstalldNativeService.cpp"
grep -Fq 'if (!inProgress && isRoydContainerWithoutSelinux()) {' \
  "$tmp/src/frameworks/native/cmds/installd/InstalldNativeService.cpp"
grep -Fq 'ROYD: skipping Installd app-data SELinux context comparison for' \
  "$tmp/src/frameworks/native/cmds/installd/InstalldNativeService.cpp"
grep -Fq 'if (!existing) {' \
  "$tmp/src/frameworks/native/cmds/installd/InstalldNativeService.cpp"
grep -Fq 'if (before = lgetfilecon(path); before.empty()) {' \
  "$tmp/src/frameworks/native/cmds/installd/InstalldNativeService.cpp"
grep -Fxq '$(call inherit-product, frameworks/native/build/phone-hdpi-512-dalvik-heap.mk)' \
  "$tmp/src/device/royd/container_version.mk"
grep -Fxq 'PRODUCT_PACKAGES += android.hardware.security.keymint-service' \
  "$tmp/src/vendor/royd/version.mk"
grep -Fq '"libselinux",' "$tmp/src/system/logging/logd/Android.bp"
grep -Fq 'static bool IsRoydContainerWithoutSelinux() {' \
  "$tmp/src/system/logging/logd/main.cpp"
grep -Fq 'if (saved_errno == ENOENT && IsRoydContainerWithoutSelinux()) {' \
  "$tmp/src/system/logging/logd/main.cpp"
grep -Fq 'PLOG(FATAL) << "failed to set background scheduling policy";' \
  "$tmp/src/system/logging/logd/main.cpp"
grep -Fq 'static bool isRoydContainerWithoutSelinux() {' \
  "$tmp/src/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp"
grep -Fq 'const bool preserveHostBpfSysctls = isRoydContainerWithoutSelinux();' \
  "$tmp/src/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp"
grep -Fq 'if (runningAsRoot && !preserveHostBpfSysctls) {' \
  "$tmp/src/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp"
grep -Fq 'if (isAtLeastU && !preserveHostBpfSysctls) {' \
  "$tmp/src/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp"
grep -Fq 'writeProcSysFile("/proc/sys/kernel/unprivileged_bpf_disabled", "0\n")' \
  "$tmp/src/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp"
grep -Fq 'writeProcSysFile("/proc/sys/net/core/bpf_jit_enable", "1\n")' \
  "$tmp/src/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp"
grep -Fq 'writeProcSysFile("/proc/sys/net/core/bpf_jit_kallsyms", "1\n")' \
  "$tmp/src/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp"
grep -Fq 'if (loadAllElfObjects(bpfloader_ver, location) != 0) return 2;' \
  "$tmp/src/packages/modules/Connectivity/bpf/loader/NetBpfLoad.cpp"
grep -Fq 'on post-fs-data && property:ro.build.version.sdk=35' \
  "$tmp/src/vendor/royd/init.royd.rc"
grep -Fq 'setprop sys.use_memfd true' "$tmp/src/vendor/royd/init.royd.rc"
grep -Fq 'on property:sys.boot_completed=1 && property:ro.build.version.sdk=35' \
  "$tmp/src/vendor/royd/init.royd.rc"
grep -Fq 'exec -- /system/bin/ip rule add pref 31999 lookup main' \
  "$tmp/src/vendor/royd/init.royd.rc"
grep -Fxq 'PRODUCT_VENDOR_PROPERTIES += media.c2.hal.selection=aidl' \
  "$tmp/src/vendor/royd/version.mk"
grep -Fxq 'PRODUCT_VENDOR_PROPERTIES += debug.stagefright.c2inputsurface=-1' \
  "$tmp/src/vendor/royd/version.mk"
grep -Fxq 'PRODUCT_VENDOR_PROPERTIES += debug.stagefright.c2-poolmask=786432' \
  "$tmp/src/vendor/royd/version.mk"
grep -Fxq 'ROYD_APP_WIDGETS := true' "$tmp/src/vendor/royd/version.mk"
grep -Fxq 'PRODUCT_COPY_FILES += frameworks/native/data/etc/android.software.app_widgets.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.app_widgets.xml' \
  "$tmp/src/vendor/royd/version.mk"
grep -Fxq 'ROYD_CGROUP2_SUBTREE := /sys/fs/cgroup/royd' \
  "$tmp/src/vendor/royd/version.mk"
grep -Fxq 'PRODUCT_MEMCG_V2_FORCE_ENABLED := true' \
  "$tmp/src/vendor/royd/version.mk"
grep -Fxq 'PRODUCT_COPY_FILES += vendor/royd/cgroups.json:$(TARGET_COPY_OUT_VENDOR)/etc/cgroups.json' \
  "$tmp/src/vendor/royd/version.mk"
grep -Fq 'static bool IsRoydContainerCgroup(const CgroupController* controller) {' \
  "$tmp/src/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
grep -Fq 'controller->name() == CGROUPV2_HIERARCHY_NAME &&' \
  "$tmp/src/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
! grep -Fq 'strcmp(controller->name(), CGROUPV2_HIERARCHY_NAME)' \
  "$tmp/src/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
grep -Fq 'strcmp(controller->path(), "/sys/fs/cgroup/royd") == 0 &&' \
  "$tmp/src/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
grep -Fq 'android::base::WriteStringToFile(std::to_string(getpid()), procs_path)' \
  "$tmp/src/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
grep -Fq 'const std::string init_path = std::string(controller->path()) + "/init";' \
  "$tmp/src/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
grep -Fq 'const std::string procs_path = init_path + "/cgroup.procs";' \
  "$tmp/src/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
grep -Fq '"+memory", "/sys/fs/cgroup/cgroup.subtree_control"' \
  "$tmp/src/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
grep -Fq 'Failed to delegate the memory controller to' \
  "$tmp/src/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
grep -Fq 'ROYD: using delegated cgroup v2 subtree at' \
  "$tmp/src/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
grep -Fq 'mount("none", controller->path(), "cgroup2"' \
  "$tmp/src/system/core/libprocessgroup/setup/cgroup_map_write.cpp"
grep -Fq 'import android.os.SELinux;' \
  "$tmp/src/frameworks/base/core/java/android/app/SystemServiceRegistry.java"
grep -Fq 'import android.os.SystemProperties;' \
  "$tmp/src/frameworks/base/core/java/android/app/SystemServiceRegistry.java"
grep -Fq 'private static boolean shouldSuppressRoydPreBootServiceNotFound() {' \
  "$tmp/src/frameworks/base/core/java/android/app/SystemServiceRegistry.java"
grep -Fq '!SystemProperties.getBoolean("sys.boot_completed", false);' \
  "$tmp/src/frameworks/base/core/java/android/app/SystemServiceRegistry.java"
[ "$(grep -c 'if (shouldSuppressRoydPreBootServiceNotFound()) {' \
  "$tmp/src/frameworks/base/core/java/android/app/SystemServiceRegistry.java")" -eq 2 ]
grep -Fq 'Slog.wtf(TAG, "Manager wrapper not available: " + name);' \
  "$tmp/src/frameworks/base/core/java/android/app/SystemServiceRegistry.java"
grep -Fq 'Log.wtf(TAG, e.getMessage(), e);' \
  "$tmp/src/frameworks/base/core/java/android/app/SystemServiceRegistry.java"
grep -Fq 'import android.os.SELinux;' \
  "$tmp/src/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java"
grep -Fq '"1".equals(System.getenv("ROYD_CONTAINER")) && !SELinux.isSELinuxEnabled()' \
  "$tmp/src/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java"
grep -Fq 'ServiceManager.checkService(Context.DROPBOX_SERVICE) == null' \
  "$tmp/src/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java"
grep -Fq 'dbox = mContext.getSystemService(DropBoxManager.class);' \
  "$tmp/src/frameworks/base/services/core/java/com/android/server/am/ActivityManagerService.java"
grep -Fq 'const char* royd_container = getenv("ROYD_CONTAINER");' \
  "$tmp/src/system/core/libprocessgroup/cgroup_map.cpp"
grep -Fq '!strcmp(path(), "/sys/fs/cgroup/royd")) {' \
  "$tmp/src/system/core/libprocessgroup/cgroup_map.cpp"
grep -Fq 'group->compare(0, 5, "royd/") == 0' \
  "$tmp/src/system/core/libprocessgroup/cgroup_map.cpp"
grep -Fq 'group->erase(0, 5);' \
  "$tmp/src/system/core/libprocessgroup/cgroup_map.cpp"
grep -Fq 'static bool isRoydDelegatedCgroup(const char* cg2_path) {' \
  "$tmp/src/packages/modules/Connectivity/bpf/netd/BpfHandler.cpp"
grep -Fq '!isRoydDelegatedCgroup(cg2_path)) {' \
  "$tmp/src/packages/modules/Connectivity/bpf/netd/BpfHandler.cpp"
grep -Fq 'ROYD: attaching network BPF to %s' \
  "$tmp/src/packages/modules/Connectivity/bpf/netd/BpfHandler.cpp"
grep -Fq 'static_cast<uint64_t>(BufferUsage::VIDEO_ENCODER)' \
  "$tmp/src/vendor/royd/graphics_allocator/allocator/Allocator.cpp"
! grep -Fq 'eventfd(' "$tmp/src/vendor/royd/graphics_composer/composer/Composer.cpp"
grep -Fq 'c3::Capability::PRESENT_FENCE_IS_NOT_RELIABLE' \
  "$tmp/src/vendor/royd/graphics_composer/composer/Composer.cpp"
! grep -Fq 'setPresentFence' "$tmp/src/vendor/royd/graphics_composer/composer/Composer.cpp"
grep -Fq '"libselinux",' "$tmp/src/system/netd/server/Android.bp"
grep -Fq 'static bool isRoydContainerWithoutSelinux() {' \
  "$tmp/src/system/netd/server/Controllers.cpp"
grep -Fq 'if (isRoydContainerWithoutSelinux()) {' \
  "$tmp/src/system/netd/server/Controllers.cpp"
grep -Fq 'ROYD: continuing without legacy iptables bandwidth rules because' \
  "$tmp/src/system/netd/server/Controllers.cpp"
grep -Fq 'exit(1);' "$tmp/src/system/netd/server/Controllers.cpp"
grep -Fq 'bool isRoydContainerWithoutSelinux() {' \
  "$tmp/src/system/netd/server/TetherController.cpp"
grep -Fq 'if (mFwdIfaces.empty() && isRoydContainerWithoutSelinux()) {' \
  "$tmp/src/system/netd/server/TetherController.cpp"
grep -Fq 'for (const IptablesTarget target : {V4, V6}) {' \
  "$tmp/src/system/netd/server/TetherController.cpp"
grep -Fq 'failed to fetch tether stats' \
  "$tmp/src/system/netd/server/TetherController.cpp"
grep -Fq 'static boolean isRoydContainerWithoutSelinux() {' \
  "$tmp/src/packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink/NetlinkUtils.java"
grep -Fq 'error.error == -ENOENT' \
  "$tmp/src/packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink/NetlinkUtils.java"
grep -Fq 'error.msg.nlmsg_type == SOCK_DIAG_BY_FAMILY' \
  "$tmp/src/packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink/NetlinkUtils.java"
grep -Fq 'private static volatile boolean sRoydInetDiagUnavailable = false;' \
  "$tmp/src/packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink/InetDiagMessage.java"
grep -Fq 'sRoydInetDiagUnavailable = true;' \
  "$tmp/src/packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink/InetDiagMessage.java"
grep -Fq 'skipping subsequent socket-destruction dumps' \
  "$tmp/src/packages/modules/Connectivity/staticlibs/device/com/android/net/module/util/netlink/InetDiagMessage.java"
grep -Fq 'private static boolean isRoydContainerWithoutSelinux() {' \
  "$tmp/src/packages/modules/Connectivity/Tethering/src/com/android/networkstack/tethering/Tethering.java"
grep -Fq '!hasSystemFeature(PackageManager.FEATURE_ETHERNET)' \
  "$tmp/src/packages/modules/Connectivity/Tethering/src/com/android/networkstack/tethering/Tethering.java"
grep -Fq '!hasSystemFeature(PackageManager.FEATURE_USB_HOST)) {' \
  "$tmp/src/packages/modules/Connectivity/Tethering/src/com/android/networkstack/tethering/Tethering.java"
grep -Fq 'return mContext.getSystemService(Context.ETHERNET_SERVICE) != null;' \
  "$tmp/src/packages/modules/Connectivity/Tethering/src/com/android/networkstack/tethering/Tethering.java"
grep -Fq 'static bool isRoydContainerWithoutSelinux() {' \
  "$tmp/src/packages/modules/Connectivity/service/jni/com_android_server_connectivity_ClatCoordinator.cpp"
grep -Fq 'if (!isRoydContainerWithoutSelinux()) {' \
  "$tmp/src/packages/modules/Connectivity/service/jni/com_android_server_connectivity_ClatCoordinator.cpp"
grep -Fq 'ROYD: skipping CLAT SELinux context verification because' \
  "$tmp/src/packages/modules/Connectivity/service/jni/com_android_server_connectivity_ClatCoordinator.cpp"
grep -Fq 'case VERIFY_PROG:   fd = bpf::retrieveProgram(path); break;' \
  "$tmp/src/packages/modules/Connectivity/service/jni/com_android_server_connectivity_ClatCoordinator.cpp"
grep -Fq 'if (fatal) abort();' \
  "$tmp/src/packages/modules/Connectivity/service/jni/com_android_server_connectivity_ClatCoordinator.cpp"
grep -Fq 'import static android.system.OsConstants.EAFNOSUPPORT;' \
  "$tmp/src/packages/modules/Connectivity/service/src/com/android/server/BpfNetMaps.java"
grep -Fq 'private static boolean isRoydContainerWithoutSelinux() {' \
  "$tmp/src/packages/modules/Connectivity/service/src/com/android/server/BpfNetMaps.java"
grep -Fq 'private static volatile boolean sRoydKernelRcuUnavailable = false;' \
  "$tmp/src/packages/modules/Connectivity/service/src/com/android/server/BpfNetMaps.java"
grep -Fq 'if (probeErr == -EAFNOSUPPORT) {' \
  "$tmp/src/packages/modules/Connectivity/service/src/com/android/server/BpfNetMaps.java"
grep -Fq 'ROYD: leaving the active network stats map unchanged because' \
  "$tmp/src/packages/modules/Connectivity/service/src/com/android/server/BpfNetMaps.java"
grep -Fq 'sConfigurationMap.updateEntry(CURRENT_STATS_MAP_CONFIGURATION_KEY,' \
  "$tmp/src/packages/modules/Connectivity/service/src/com/android/server/BpfNetMaps.java"
grep -Fq 'maybeThrow(err, "synchronizeKernelRCU failed");' \
  "$tmp/src/packages/modules/Connectivity/service/src/com/android/server/BpfNetMaps.java"
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
