// Pinned Android 15 netd fragments, not a complete translation unit.
#include "NetdConstants.h"
#include "NetlinkCommands.h"
#include "TcUtils.h"

#include <android-base/file.h>

static void maybeModifyQdiscClsact(const char* interface, bool add) {
    // The clsact attaching of v4- tun interface is triggered by ClatdController::maybeStartBpf
    // because the clat is started before the v4- interface is added to the network and the
    // clat startup needs to add {in, e}gress filters.
