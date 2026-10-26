package org.royd.alertprobe;

import android.net.INetd;
import android.net.INetdUnsolicitedEventListener;
import android.os.Binder;
import android.os.Process;
import android.os.ServiceManager;
import android.os.ServiceSpecificException;
import android.os.SystemClock;
import android.system.OsConstants;
import java.io.BufferedReader;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import java.io.InputStreamReader;
import org.json.JSONObject;

/** Privileged test observer for the existing platform Binder API, never an APK. */
public final class GlobalAlertProbe {
    private static String nonce;
    private static int netdPid, callbacks;
    private static synchronized void emit(String event, JSONObject data) throws Exception {
        data.put("event", event).put("nonce", nonce).put("pid", Process.myPid())
                .put("uid", Process.myUid()).put("time_ns", SystemClock.elapsedRealtimeNanos());
        System.out.println(data.toString());
        System.out.flush();
    }
    private static void require(boolean valid, String message) throws Exception {
        if (!valid) throw new java.io.IOException(message);
    }
    private static final class Listener extends INetdUnsolicitedEventListener.Stub {
        @Override public void onQuotaLimitReached(String name, String iface) {
            try {
                int caller = Binder.getCallingUidOrThrow(), pid = Binder.getCallingPid();
                // Stock oneway Binder delivers the UID but no sending PID.
                require(caller == 0 && pid == 0, "unexpected oneway caller: uid=" + caller + " pid=" + pid);
                synchronized (GlobalAlertProbe.class) {
                    if ("globalAlert".equals(name)) callbacks++;
                    emit("callback", new JSONObject().put("name", name).put("interface", iface)
                            .put("caller_uid", caller).put("caller_pid", pid).put("callbacks", callbacks));
                }
            } catch (Exception error) {
                error.printStackTrace(System.err);
                System.exit(1);
            }
        }
        // A real listener must implement every stock event, without altering other listeners.
        @Override public void onInterfaceClassActivityChanged(boolean a, int b, long c, int d) {}
        @Override public void onInterfaceDnsServerInfo(String a, long b, String[] c) {}
        @Override public void onInterfaceAddressUpdated(String a, String b, int c, int d) {}
        @Override public void onInterfaceAddressRemoved(String a, String b, int c, int d) {}
        @Override public void onInterfaceAdded(String a) {}
        @Override public void onInterfaceRemoved(String a) {}
        @Override public void onInterfaceChanged(String a, boolean b) {}
        @Override public void onInterfaceLinkStateChanged(String a, boolean b) {}
        @Override public void onRouteChanged(boolean a, String b, String c, String d) {}
        @Override public void onStrictCleartextDetected(int a, String b) {}
        @Override public int getInterfaceVersion() { return INetdUnsolicitedEventListener.VERSION; }
        @Override public String getInterfaceHash() { return INetdUnsolicitedEventListener.HASH; }
    }
    public static void main(String[] args) throws Exception {
        require(args.length == 4 && args[0].matches("[0-9a-f]{32}"), "probe arguments");
        nonce = args[0];
        netdPid = Integer.parseInt(args[2]);
        long originalBytes = Long.parseLong(args[3]);
        require(netdPid > 1 && originalBytes > 0, "invalid original state");
        INetd netd = INetd.Stub.asInterface(ServiceManager.checkService("netd"));
        require(netd != null, "netd unavailable");
        Listener listener = new Listener();
        try (FileInputStream status = new FileInputStream("/proc/self/status");
             FileInputStream cgroup = new FileInputStream("/proc/self/cgroup")) {
            emit("identity", new JSONObject().put("status", new String(status.readNBytes(16384), StandardCharsets.UTF_8))
                    .put("cgroup", new String(cgroup.readNBytes(4096), StandardCharsets.UTF_8)));
        }
        if ("denied".equals(args[1])) {
            require(Process.myUid() >= 10000 && Process.myUid() < 20000, "ordinary UID required");
            try {
                netd.bandwidthSetGlobalAlert(originalBytes);
                throw new java.io.IOException("unprivileged global registration succeeded");
            } catch (SecurityException expected) {
                emit("denied-arm", new JSONObject().put("exception", expected.getClass().getName()));
            }
            try {
                netd.registerUnsolicitedEventListener(listener);
                throw new java.io.IOException("unprivileged listener registration succeeded");
            } catch (SecurityException expected) {
                emit("denied-listener", new JSONObject().put("exception", expected.getClass().getName()));
            }
            System.exit(0);
        }
        if ("restore".equals(args[1])) {
            require(Process.myUid() == 0 && netd.isAlive(), "root restoration required");
            netd.bandwidthSetGlobalAlert(originalBytes);
            emit("restored", new JSONObject().put("bytes", originalBytes));
            System.exit(0);
        }
        require("monitor".equals(args[1]) && Process.myUid() == 0 && netd.isAlive(), "root observer required");
        boolean registered = false;
        int status = 1;
        try {
            netd.registerUnsolicitedEventListener(listener);
            registered = true;
            emit("ready", new JSONObject().put("aidl_version", netd.getInterfaceVersion()).put("netd_pid", netdPid));
            try (BufferedReader input = new BufferedReader(new InputStreamReader(System.in))) {
                int previous = 0;
                for (String line; (line = input.readLine()) != null;) {
                    require(line.length() <= 128, "command too long");
                    String[] fields = line.split(" ", -1);
                    require(fields.length == 4 && nonce.equals(fields[0]), "command identity");
                    int sequence = Integer.parseInt(fields[1]);
                    long bytes = Long.parseLong(fields[3]);
                    require(sequence > previous && sequence <= 100, "command sequence");
                    previous = sequence;
                    String operation = fields[2];
                    int errorCode = 0;
                    if ("arm".equals(operation)) {
                        require(bytes > 0, "positive threshold required");
                        netd.bandwidthSetGlobalAlert(bytes);
                    } else if ("invalid".equals(operation)) {
                        require(bytes <= 0, "invalid-value control required");
                        try {
                            netd.bandwidthSetGlobalAlert(bytes);
                            throw new java.io.IOException("invalid threshold accepted");
                        } catch (ServiceSpecificException expected) {
                            require(expected.errorCode == OsConstants.ERANGE, "unexpected invalid-value cause");
                            errorCode = expected.errorCode;
                        }
                    } else require(("status".equals(operation) || "stop".equals(operation)) && bytes == 0,
                                   "unknown command");
                    synchronized (GlobalAlertProbe.class) {
                        emit("command", new JSONObject().put("sequence", sequence).put("operation", operation)
                                .put("bytes", bytes).put("callbacks", callbacks).put("error_code", errorCode));
                    }
                    if ("stop".equals(operation)) { status = 0; break; }
                }
            }
        } finally {
            if (registered) {
                netd.bandwidthSetGlobalAlert(originalBytes);
                emit("restored", new JSONObject().put("bytes", originalBytes));
            }
        }
        // Binder death removes only this observer, not the framework listeners.
        System.exit(status);
    }
}
