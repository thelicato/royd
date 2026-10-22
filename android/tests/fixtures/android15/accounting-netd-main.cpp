// Pinned Android 15 netd fragments, not a complete translation unit.
#include "NetdNativeService.h"
#include "NetlinkManager.h"
#include "Process.h"

#include "NetdUpdatablePublic.h"
#include "netd_resolv/resolv.h"

    }
    gLog.info("libnetd_updatable_init success");

    NetlinkManager *nm = NetlinkManager::Instance();
    if (nm == nullptr) {
        ALOGE("Unable to create NetlinkManager");
