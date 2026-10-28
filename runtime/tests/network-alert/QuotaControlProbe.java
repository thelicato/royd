package org.royd.alertprobe;

import android.net.INetd;
import android.os.Process;
import android.os.ServiceManager;
import android.os.ServiceSpecificException;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

/** Existing netd Binder operations only. No product-map writes or APK privileges. */
public final class QuotaControlProbe {
    public static void main(String[] args) throws Exception {
        if (args.length != 4 || !args[0].matches("[0-9a-f]{32}")) throw new java.io.IOException("arguments");
        String operation = args[1];
        long bytes = Long.parseLong(args[2]);
        int expected = Integer.parseInt(args[3]), error = 0;
        boolean denied = false;
        INetd netd = INetd.Stub.asInterface(ServiceManager.checkService("netd"));
        if (netd == null) throw new java.io.IOException("netd unavailable");
        try {
            if ("set".equals(operation)) netd.bandwidthSetInterfaceQuota("eth0", bytes);
            else if ("remove".equals(operation) && bytes == 0) netd.bandwidthRemoveInterfaceQuota("eth0");
            else throw new java.io.IOException("operation");
        } catch (ServiceSpecificException failure) { error = failure.errorCode; }
        catch (SecurityException failure) { denied = true; }
        if ((expected == -1 ? !denied || error != 0 : denied || error != expected)) {
            throw new java.io.IOException("unexpected Binder result: denied=" + denied + " error=" + error);
        }
        String capabilities = "";
        try (FileInputStream input = new FileInputStream("/proc/self/status")) {
            for (String line : new String(input.readNBytes(16384), StandardCharsets.UTF_8).split("\n")) {
                if (line.startsWith("CapEff:")) capabilities = line.substring(7).trim();
            }
        }
        if (!capabilities.matches("[0-9a-f]+")) throw new java.io.IOException("capability observation missing");
        System.out.println(new JSONObject().put("nonce", args[0]).put("uid", Process.myUid())
                .put("pid", Process.myPid()).put("operation", operation).put("bytes", bytes)
                .put("error", error).put("denied", denied).put("cap_eff", capabilities));
        System.exit(0);
    }
}
