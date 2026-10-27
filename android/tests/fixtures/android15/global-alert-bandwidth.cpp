// Pinned Android 15 BandwidthController fragments, not a translation unit.
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/pkt_sched.h>

#include "android-base/stringprintf.h"
#include "android-base/strings.h"
#define LOG_TAG "BandwidthController"
#include <cutils/properties.h>
#include <log/log.h>

#include <netdutils/Syscalls.h>
#include "BandwidthController.h"
#include "Controllers.h"
#include "FirewallController.h" /* For makeCriticalCommands */
#include "Fwmark.h"
#include "NetdConstants.h"
#include "android/net/INetd.h"


// Unrelated upstream methods omitted.

}  // namespace

BandwidthController::BandwidthController() {
}

void BandwidthController::flushCleanTables(bool doClean) {
    /* Flush and remove the bw_costly_<iface> tables */
    flushExistingCostlyTables(doClean);

    std::string commands = Join(IPT_FLUSH_COMMANDS, '\n');
    iptablesRestoreFunction(V4V6, commands, nullptr);
}

int BandwidthController::setupIptablesHooks() {
    /* flush+clean is allowed to fail */
    flushCleanTables(true);
    return 0;
}

int BandwidthController::enableBandwidthControl() {
    /* Let's pretend we started from scratch ... */
    mSharedQuotaIfaces.clear();
    mQuotaIfaces.clear();
    mGlobalAlertBytes = 0;
    mSharedQuotaBytes = 0;

    flushCleanTables(false);

    std::string commands = Join(getBasicAccountingCommands(), '\n');
    return iptablesRestoreFunction(V4V6, commands, nullptr);
}

std::string BandwidthController::makeDataSaverCommand(IptablesTarget target, bool enable) {
    std::string cmd;
    const char *chainName = "bw_data_saver";
    const char *op = jumpToString(enable ? IptJumpReject : IptJumpReturn);
    std::string criticalCommands = enable ?
            FirewallController::makeCriticalCommands(target, chainName) : "";
    StringAppendF(&cmd,
        "*filter\n"
        ":%s -\n"
        "%s"
        "-A %s%s\n"
        "COMMIT\n", chainName, criticalCommands.c_str(), chainName, op);
    return cmd;
}

int BandwidthController::enableDataSaver(bool enable) {
    int ret = iptablesRestoreFunction(V4, makeDataSaverCommand(V4, enable), nullptr);
    ret |= iptablesRestoreFunction(V6, makeDataSaverCommand(V6, enable), nullptr);

// Unrelated upstream methods omitted.
    return iptablesRestoreFunction(V4V6, alertQuotaCmd, nullptr);
}

int BandwidthController::setInterfaceQuota(const std::string& iface, int64_t maxBytes) {
    const std::string& cost = iface;

    if (!isIfaceName(iface)) return -EINVAL;

    if (!maxBytes) {
        ALOGE("Invalid bytes value. 1..max_int64.");
        return -ERANGE;
    }
    if (maxBytes == -1) {
        return removeInterfaceQuota(iface);
    }

    /* Insert ingress quota. */
    auto it = mQuotaIfaces.find(iface);

    if (it != mQuotaIfaces.end()) {
        if (int res = updateQuota(cost, maxBytes)) {
            ALOGE("Failed update quota for %s", iface.c_str());
            removeInterfaceQuota(iface);
            return res;
        }
        it->second.quota = maxBytes;
        return 0;
    }

    const std::string chain = "bw_costly_" + iface;
    const int ruleInsertPos = (mGlobalAlertBytes) ? 2 : 1;
    std::vector<std::string> cmds = {
            "*filter",
            StringPrintf(":%s -", chain.c_str()),
            StringPrintf("-A %s -j bw_penalty_box", chain.c_str()),
            StringPrintf("-I bw_INPUT %d -i %s -j %s", ruleInsertPos, iface.c_str(), chain.c_str()),
            StringPrintf("-I bw_OUTPUT %d -o %s -j %s", ruleInsertPos, iface.c_str(),
                         chain.c_str()),
            StringPrintf("-A bw_FORWARD -i %s -j %s", iface.c_str(), chain.c_str()),
            StringPrintf("-A bw_FORWARD -o %s -j %s", iface.c_str(), chain.c_str()),
            StringPrintf("-A %s -m quota2 ! --quota %" PRId64 " --name %s -j REJECT", chain.c_str(),
                         maxBytes, cost.c_str()),
            "COMMIT\n",
    };
    if (iptablesRestoreFunction(V4V6, Join(cmds, "\n"), nullptr) != 0) {
        ALOGE("Failed set quota rule");
        removeInterfaceQuota(iface);
        return -EREMOTEIO;
    }

    mQuotaIfaces[iface] = QuotaInfo{maxBytes, 0};
    return 0;
}

int BandwidthController::getInterfaceSharedQuota(int64_t *bytes) {
    return getInterfaceQuota("shared", bytes);
}

int BandwidthController::getInterfaceQuota(const std::string& iface, int64_t* bytes) {
    const auto& sys = android::netdutils::sSyscalls.get();
    const std::string fname = "/proc/net/xt_quota/" + iface;

    if (!isIfaceName(iface)) return -1;

    StatusOr<UniqueFile> file = sys.fopen(fname, "re");
    if (!isOk(file)) {
        ALOGE("Reading quota %s failed (%s)", iface.c_str(), toString(file).c_str());
        return -1;
    }
    auto rv = sys.fscanf(file.value().get(), "%" SCNd64, bytes);
    if (!isOk(rv)) {
        ALOGE("Reading quota %s failed (%s)", iface.c_str(), toString(rv).c_str());
        return -1;
    }
    ALOGV("Read quota res=%d bytes=%" PRId64, rv.value(), *bytes);
    return rv.value() == 1 ? 0 : -1;
}

int BandwidthController::removeInterfaceQuota(const std::string& iface) {
    if (!isIfaceName(iface)) return -EINVAL;

    auto it = mQuotaIfaces.find(iface);

    if (it == mQuotaIfaces.end()) {
        ALOGE("No such iface %s to delete", iface.c_str());
        return -ENODEV;
    }

    const std::string chain = "bw_costly_" + iface;
    std::vector<std::string> cmds = {
            "*filter",
            StringPrintf("-D bw_INPUT -i %s -j %s", iface.c_str(), chain.c_str()),
            StringPrintf("-D bw_OUTPUT -o %s -j %s", iface.c_str(), chain.c_str()),
            StringPrintf("-D bw_FORWARD -i %s -j %s", iface.c_str(), chain.c_str()),
            StringPrintf("-D bw_FORWARD -o %s -j %s", iface.c_str(), chain.c_str()),
            StringPrintf("-F %s", chain.c_str()),
            StringPrintf("-X %s", chain.c_str()),
            "COMMIT\n",
    };

    const int res = iptablesRestoreFunction(V4V6, Join(cmds, "\n"), nullptr);

    if (res == 0) {
        mQuotaIfaces.erase(it);
    }

    return res ? -EREMOTEIO : 0;
}

int BandwidthController::setGlobalAlert(int64_t bytes) {
    const char *alertName = ALERT_GLOBAL_NAME;

    if (!bytes) {
        ALOGE("Invalid bytes value. 1..max_int64.");
        return -ERANGE;
    }

    int res = 0;
    if (mGlobalAlertBytes) {
        res = updateQuota(alertName, bytes);
    } else {
        res = runIptablesAlertCmd(IptOpInsert, alertName, bytes);
        if (res) {
            res = -EREMOTEIO;
        }
    }
    mGlobalAlertBytes = bytes;
    return res;
}

int BandwidthController::removeGlobalAlert() {

    const char *alertName = ALERT_GLOBAL_NAME;

    if (!mGlobalAlertBytes) {
        ALOGE("No prior alert set");
        return -1;
    }

    int res = 0;
    res = runIptablesAlertCmd(IptOpDelete, alertName, mGlobalAlertBytes);
    mGlobalAlertBytes = 0;
    return res;
}

int BandwidthController::setInterfaceAlert(const std::string& iface, int64_t bytes) {
    if (!isIfaceName(iface)) {
        ALOGE("setInterfaceAlert: Invalid iface \"%s\"", iface.c_str());
        return -EINVAL;
    }

    if (!bytes) {
        ALOGE("Invalid bytes value. 1..max_int64.");
        return -ERANGE;
    }
    auto it = mQuotaIfaces.find(iface);

    if (it == mQuotaIfaces.end()) {
        ALOGE("Need to have a prior interface quota set to set an alert");
        return -ENOENT;
    }

    return setCostlyAlert(iface, bytes, &it->second.alert);
}
