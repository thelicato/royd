// Pinned Android 15 netd fragments, not a complete translation unit.
#include "Permission.h"
#include "Process.h"
#include "RouteController.h"
#include "SockDiag.h"
#include "UidRanges.h"
#include "android/net/BnNetd.h"

    // their dump() methods MUST handle locking appropriately.

    DumpWriter dw(fd);

    if (!args.isEmpty() && args[0] == TcpSocketMonitor::DUMP_KEYWORD) {
      dw.blankline();
      gCtls->tcpSocketMonitor.dump(dw);
