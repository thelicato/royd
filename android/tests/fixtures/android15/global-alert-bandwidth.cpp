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
