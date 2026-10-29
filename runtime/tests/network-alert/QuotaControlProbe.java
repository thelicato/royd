package org.royd.alertprobe;

import android.app.ActivityManager;
import android.net.INetd;
import android.net.INetdUnsolicitedEventListener;
import android.os.Binder;
import android.os.Process;
import android.os.ServiceManager;
import android.os.ServiceSpecificException;
import android.os.SystemClock;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileDescriptor;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import org.json.JSONArray;
import org.json.JSONObject;

/** Existing Binder operations and owned test-file IPC only. Never writes product maps. */
public final class QuotaControlProbe {
    private static final ArrayList<JSONObject> callbacks = new ArrayList<>();
    private static Listener listener;
    private static volatile String listenerNonce;
    private static final class Listener extends INetdUnsolicitedEventListener.Stub {
        @Override public void onQuotaLimitReached(String name, String iface) {
            try {
                int caller = Binder.getCallingUidOrThrow(), pid = Binder.getCallingPid();
                require(caller == 0 && pid == 0, "unexpected oneway Binder caller");
                synchronized (callbacks) {
                    require(callbacks.size() < 32, "callback bound exceeded");
                    callbacks.add(new JSONObject().put("nonce", listenerNonce).put("name", name)
                            .put("interface", iface).put("caller_uid", caller).put("caller_pid", pid)
                            .put("sequence", callbacks.size()+1).put("time_ns", SystemClock.elapsedRealtimeNanos()));
                }
            } catch (Exception failure) {
                failure.printStackTrace(System.err);System.exit(2);
            }
        }
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
    private static void require(boolean value, String reason) throws IOException {
        if (!value) throw new IOException(reason);
    }
    private static String read(File file, int bound) throws Exception {
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] value = input.readNBytes(bound+1);
            require(value.length <= bound, "file exceeds bound");
            return new String(value, StandardCharsets.UTF_8);
        }
    }
    private static String capabilities() throws Exception {
        for (String line : read(new File("/proc/self/status"), 16384).split("\n")) {
            if (line.startsWith("CapEff:")) {
                String value = line.substring(7).trim();
                require(value.matches("[0-9a-f]+"), "capability observation missing");
                return value;
            }
        }
        throw new IOException("capability observation missing");
    }
    private static JSONObject control(String nonce, String operation, long bytes, int expected) throws Exception {
        long started = SystemClock.elapsedRealtimeNanos();
        int error = 0;
        boolean denied = false;
        INetd netd = INetd.Stub.asInterface(ServiceManager.checkService("netd"));
        require(netd != null, "netd unavailable");
        try {
            if ("set".equals(operation)) netd.bandwidthSetInterfaceQuota("eth0", bytes);
            else if ("remove".equals(operation) && bytes == 0) netd.bandwidthRemoveInterfaceQuota("eth0");
            else if ("set-alert".equals(operation)) netd.bandwidthSetInterfaceAlert("eth0", bytes);
            else if ("remove-alert".equals(operation) && bytes == 0) netd.bandwidthRemoveInterfaceAlert("eth0");
            else throw new IOException("operation");
        } catch (ServiceSpecificException failure) { error = failure.errorCode; }
        catch (SecurityException failure) { denied = true; }
        require(expected == -1 ? denied && error == 0 : !denied && error == expected,
                "unexpected Binder result: denied=" + denied + " error=" + error);
        return new JSONObject().put("nonce", nonce).put("uid", Process.myUid()).put("pid", Process.myPid())
                .put("operation", operation).put("bytes", bytes).put("error", error).put("denied", denied)
                .put("cap_eff", capabilities()).put("started_ns", started)
                .put("finished_ns", SystemClock.elapsedRealtimeNanos());
    }
    private static File directory(JSONObject request, String nonce) throws Exception {
        File dir = new File(request.getString("directory"));
        String path = dir.getPath();
        require(path.equals("/data/user/0/org.royd.networkprobe/files/quota-" + nonce)
                || path.equals("/data/user/0/org.royd.networkcontrol/files/quota-" + nonce)
                || path.matches("/data/local/tmp/royd-quota-[0-9a-f]{32}/system-parent/probe"), "unowned directory path");
        require(OsConstants.S_ISDIR(Os.lstat(path).st_mode) && Os.stat(path).st_uid == request.getInt("uid"),
                "worker directory ownership");
        return dir;
    }
    private static JSONObject identity(JSONObject request) throws Exception {
        int pid = request.getInt("pid"), uid = request.getInt("uid");
        require(pid > 1 && uid >= 1000 && uid < 20000, "worker identity arguments");
        String path = "/proc/" + pid;
        JSONObject value = new JSONObject().put("uid", Os.stat(path).st_uid)
                .put("stat", read(new File(path + "/stat"), 16384))
                .put("status", read(new File(path + "/status"), 16384))
                .put("cgroup", read(new File(path + "/cgroup"), 4096));
        if (uid >= 10000) {
            String pkg = request.getString("package");
            require(pkg.equals("org.royd.networkprobe") || pkg.equals("org.royd.networkcontrol"), "worker package");
            ArrayList<Integer> pids = new ArrayList<>();
            File[] processes = new File("/proc").listFiles();
            require(processes != null, "cannot enumerate processes");
            for (File process : processes) {
                if (!process.getName().matches("[0-9]+")) continue;
                try {
                    if (Os.stat(process.getPath()).st_uid != uid) continue;
                    String cmd = read(new File(process, "cmdline"), 4096);
                    int end = cmd.indexOf(0);
                    if (pkg.equals(end < 0 ? cmd : cmd.substring(0, end))) pids.add(Integer.parseInt(process.getName()));
                } catch (ErrnoException race) {
                    if (race.errno != OsConstants.ENOENT && race.errno != OsConstants.ESRCH) throw race;
                } catch (java.io.FileNotFoundException race) {
                    // Confirm actual process exit. Every other open failure remains fatal.
                    try { Os.stat(process.getPath()); throw race; }
                    catch (ErrnoException gone) {
                        if (gone.errno != OsConstants.ENOENT && gone.errno != OsConstants.ESRCH) throw gone;
                    }
                }
            }
            value.put("pids", new JSONArray(pids))
                    .put("uid_state", ActivityManager.getService().getUidProcessState(uid, "android"));
        }
        return value;
    }
    private static JSONObject dispatch(JSONObject request, String nonce) throws Exception {
        String op = request.getString("op");
        if (op.equals("control")) return control(nonce, request.getString("operation"), request.getLong("bytes"), request.getInt("expected"));
        require(Process.myUid() == 0, "test-file/identity operations require root");
        if (op.equals("listen")) {
            require(listener == null, "listener already registered");
            INetd netd = INetd.Stub.asInterface(ServiceManager.checkService("netd"));
            require(netd != null && netd.isAlive(), "netd unavailable");
            listenerNonce = nonce;listener = new Listener();
            netd.registerUnsolicitedEventListener(listener);
            return new JSONObject().put("listening", true);
        }
        if (op.equals("callbacks")) {
            require(listener != null, "listener not registered");
            synchronized (callbacks) {
                return new JSONObject().put("callbacks", new JSONArray(callbacks))
                        .put("sampled_ns", SystemClock.elapsedRealtimeNanos());
            }
        }
        if (op.equals("identity")) return identity(request);
        File dir = directory(request, nonce);
        String name = request.getString("name");
        if (op.equals("publish")) {
            require(name.matches("(command|release)-[1-9][0-9]{0,2}"), "publication name");
            String data = request.getString("value") + "\n";
            byte[] bytes = data.getBytes(StandardCharsets.UTF_8);
            require(bytes.length <= 4096, "publication exceeds bound");
            File tmp = new File(dir, name + ".tmp");
            int uid = request.getInt("uid");
            FileDescriptor fd = Os.open(tmp.getPath(), OsConstants.O_WRONLY | OsConstants.O_CREAT
                    | OsConstants.O_EXCL | OsConstants.O_NOFOLLOW | OsConstants.O_CLOEXEC, 0600);
            try {
                android.system.StructStat created = Os.fstat(fd);
                Os.fchown(fd, uid, uid);
                for (int offset = 0; offset < bytes.length;) {
                    int count = Os.write(fd, bytes, offset, bytes.length-offset);
                    require(count > 0, "publication write failed");offset += count;
                }
                android.system.StructStat current = Os.lstat(tmp.getPath());
                require(current.st_ino == created.st_ino && current.st_dev == created.st_dev,
                        "publication file changed");
                File target = new File(dir, name);
                Os.link(tmp.getPath(), target.getPath());
                android.system.StructStat linked = Os.lstat(target.getPath());
                require(linked.st_ino == created.st_ino && linked.st_dev == created.st_dev,
                        "publication link changed");
            } finally { Os.close(fd); }
            require(tmp.delete(), "publication cleanup failed");
            return new JSONObject().put("published", name);
        }
        require(op.equals("read") && name.matches("ready|stopped|(started|result|refresh)-[1-9][0-9]{0,2}"), "read name");
        File result = new File(dir, name + ".json"), error = new File(dir, "error.json");
        long deadline = SystemClock.elapsedRealtime() + 20000;
        while (!result.isFile()) {
            require(!error.isFile(), error.isFile() ? "worker error: " + read(error, 16384) : "worker error");
            require(SystemClock.elapsedRealtime() < deadline, "worker result timed out");
            Thread.sleep(10);
        }
        require(!error.isFile(), "worker error");
        require(Os.stat(result.getPath()).st_uid == request.getInt("uid"), "worker result ownership");
        return new JSONObject(read(result, 16384));
    }
    private static void serve(String nonce, boolean root) throws Exception {
        require(root ? Process.myUid() == 0 : Process.myUid() >= 10000 && Process.myUid() < 20000,
                "test controller UID");
        Thread deadline = new Thread(() -> {
            SystemClock.sleep(600000);
            System.err.println("quota controller lifetime exceeded");System.exit(2);
        }, "quota-controller-deadline");
        deadline.setDaemon(true);deadline.start();
        System.out.println(new JSONObject().put("nonce", nonce).put("seq", 0).put("status", "ready")
                .put("uid", Process.myUid()).put("pid", Process.myPid()).put("cap_eff", capabilities()));
        System.out.flush();
        for (int sequence = 1; sequence <= 512; sequence++) {
            java.io.ByteArrayOutputStream bytes = new java.io.ByteArrayOutputStream();
            int c;
            while ((c = System.in.read()) != -1 && c != 10) {
                require(bytes.size() < 16384, "controller request exceeds bound");bytes.write(c);
            }
            if (c == -1 && bytes.size() == 0) return;
            require(c == 10, "incomplete controller request");
            JSONObject request = new JSONObject(bytes.toString(StandardCharsets.UTF_8));
            require(nonce.equals(request.getString("nonce")) && request.getInt("seq") == sequence, "controller request identity");
            boolean stop = request.getString("op").equals("stop");
            JSONObject value = stop ? new JSONObject().put("stopped", true) : dispatch(request, nonce);
            System.out.println(new JSONObject().put("nonce", nonce).put("seq", sequence).put("status", "pass").put("value", value));
            System.out.flush();
            if (stop) return;
        }
        throw new IOException("controller request bound exceeded");
    }
    public static void main(String[] args) throws Exception {
        require((args.length == 2 || args.length == 4) && args[0].matches("[0-9a-f]{32}"), "arguments");
        if (args.length == 2) {
            require(args[1].equals("serve") || args[1].equals("serve-control"), "mode");
            serve(args[0], args[1].equals("serve"));
        }
        else System.out.println(control(args[0], args[1], Long.parseLong(args[2]), Integer.parseInt(args[3])));
        System.exit(0);
    }
}
