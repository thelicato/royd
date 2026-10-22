// Pinned Android 15 netd fragments, not a complete translation unit.
#include "PhysicalNetwork.h"
#include "RouteController.h"
#include "TcUtils.h"
#include "UnreachableNetwork.h"

    const auto& ifaces = getIfaceNames();
    if (isOk(ifaces)) {
        for (const std::string& iface : ifaces.value()) {
            if (int ifIndex = if_nametoindex(iface.c_str())) {
                // Ignore the error because the interface might not have a clsact.
                tcQdiscDelDevClsact(ifIndex);
