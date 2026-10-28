package org.royd.networkprobe;

import android.app.ActivityManager;
import android.os.Process;
import android.os.SystemClock;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import org.json.JSONObject;

/** One socket and identity through real interface-quota changes. No privileged API. */
public final class QuotaProbe {
    private static final int SIZE = 1200;
    private static void require(boolean value, String message) throws Exception {
        if (!value) throw new java.io.IOException(message);
    }
    private static String read(File file, int maximum) throws Exception {
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] data = input.readNBytes(maximum + 1);
            require(data.length <= maximum, "input exceeds bound");
            return new String(data, StandardCharsets.UTF_8);
        }
    }
    static void publish(File dir, String name, JSONObject value) throws Exception {
        File temporary = new File(dir, name + ".tmp"), target = new File(dir, name + ".json");
        require(temporary.createNewFile(), "observation already exists");
        try (FileOutputStream output = new FileOutputStream(temporary)) {
            output.write(value.toString().getBytes(StandardCharsets.UTF_8));
        }
        Os.link(temporary.getPath(), target.getPath());
        require(temporary.delete(), "temporary cleanup failed");
    }
    private static int importance(boolean app) {
        if (!app) return -1;
        ActivityManager.RunningAppProcessInfo value = new ActivityManager.RunningAppProcessInfo();
        ActivityManager.getMyMemoryState(value);
        return value.importance;
    }
    static byte[] payload(byte[] nonce, int step, int uid, int sequence, int count, int kind) {
        byte[] value = new byte[SIZE];
        ByteBuffer.wrap(value).put(nonce).putInt(step).putInt(uid).putInt(sequence).putInt(count)
                .put((byte) kind);
        for (int i = 33; i < SIZE; i++) value[i] = (byte) (i + sequence + uid);
        return value;
    }
    public static void run(File directory, String address, String nonceText, boolean app) throws Exception {
        require(nonceText != null && nonceText.matches("[0-9a-f]{32}"), "invalid nonce");
        require(address != null && address.matches("[0-9.]+:[0-9]+"), "literal IPv4 required");
        int colon = address.lastIndexOf(':'), port = Integer.parseInt(address.substring(colon + 1));
        InetAddress remote = InetAddress.getByName(address.substring(0, colon));
        require(remote.getAddress().length == 4 && remote.isSiteLocalAddress() && port > 0 && port <= 65535,
                "private IPv4 fixture required");
        int uid = Process.myUid(), pid = Process.myPid();
        require(app ? uid >= 10000 && uid < 20000 : uid == 1000, "unexpected worker UID");
        require(directory.mkdir(), "probe directory already exists");
        byte[] nonce = new byte[16];
        for (int i = 0; i < 16; i++) nonce[i] = (byte) Integer.parseInt(nonceText.substring(i*2, i*2+2), 16);
        try (DatagramSocket socket = new DatagramSocket()) {
            socket.connect(remote, port);
            socket.setSoTimeout(500);
            long deadline = SystemClock.elapsedRealtime() + 15000;
            while (app && importance(true) != ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE) {
                require(SystemClock.elapsedRealtime() < deadline, "service importance timed out");
                Thread.sleep(20);
            }
            String local = socket.getLocalAddress().getHostAddress() + ":" + socket.getLocalPort();
            String status = read(new File("/proc/self/status"), 16384);
            String capabilities = "";
            for (String line : status.split("\n")) if (line.startsWith("CapEff:")) capabilities = line.substring(7).trim();
            publish(directory, "ready", new JSONObject().put("uid", uid).put("pid", pid)
                    .put("gid", Os.getgid()).put("nonce", nonceText).put("local", local).put("remote", address)
                    .put("cap_eff", capabilities).put("cgroup", read(new File("/proc/self/cgroup"), 4096))
                    .put("importance", importance(app)));
            final long lifetime = SystemClock.elapsedRealtime() + 600000;
            for (int step = 1; step <= 128; step++) {
                File command = new File(directory, "command-" + step);
                while (!command.exists()) {
                    require(SystemClock.elapsedRealtime() < lifetime, "worker lifetime exceeded");
                    Thread.sleep(20);
                }
                JSONObject request = new JSONObject(read(command, 1024));
                String op = request.getString("op");
                int count = request.getInt("count");
                require(request.length() == 5 && nonceText.equals(request.getString("nonce"))
                        && request.getInt("step") == step && request.getInt("uid") == uid,
                        "command identity mismatch");
                if ("stop".equals(op)) {
                    require(count == 0, "invalid stop");
                    publish(directory, "stopped", new JSONObject().put("uid", uid).put("pid", pid).put("step", step));
                    return;
                }
                require(("send".equals(op) || "receive".equals(op)) && count > 0 && count <= 64, "invalid operation");
                require(!app || importance(true) == ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE,
                        "worker left ordinary service state");
                long started = SystemClock.elapsedRealtimeNanos();
                long released = started;
                publish(directory, "started-" + step, request.put("ready_ns", started));
                int sent = 0, enobufs = 0, received = 0;
                boolean timedOut = false;
                if ("send".equals(op)) {
                    for (int sequence = 0; sequence < count; sequence++) {
                        byte[] data = payload(nonce, step, uid, sequence, count, 1);
                        try {
                            socket.send(new DatagramPacket(data, data.length));
                            sent++;
                        } catch (Exception error) {
                            boolean exact = false;
                            for (Throwable cause = error; cause != null; cause = cause.getCause()) {
                                if (cause instanceof ErrnoException && ((ErrnoException) cause).errno == OsConstants.ENOBUFS) exact = true;
                            }
                            if (!exact) throw error;
                            enobufs++;
                        }
                        Thread.sleep(2);
                    }
                } else {
                    // Queue the bounded host push before starting the socket quiet timer.
                    // Docker control round trips are independent of packet delivery time.
                    File release = new File(directory, "release-" + step);
                    while (!release.exists()) {
                        require(SystemClock.elapsedRealtime() < lifetime, "receive release timed out");
                        Thread.sleep(20);
                    }
                    require(read(release, 65).equals(nonceText + "\n"), "receive release identity");
                    released = SystemClock.elapsedRealtimeNanos();
                    boolean[] seen = new boolean[count];
                    try {
                        while (true) {
                            byte[] value = new byte[SIZE + 1];
                            DatagramPacket packet = new DatagramPacket(value, value.length);
                            socket.receive(packet);
                            int sequence = ByteBuffer.wrap(value).getInt(24);
                            require(packet.getLength() == SIZE && sequence >= 0 && sequence < count
                                    && !seen[sequence] && Arrays.equals(Arrays.copyOf(value, SIZE),
                                    payload(nonce, step, uid, sequence, count, 2)), "invalid or duplicate packet");
                            seen[sequence] = true;
                            received++;
                        }
                    } catch (SocketTimeoutException expected) { timedOut = true; }
                }
                publish(directory, "result-" + step, new JSONObject().put("uid", uid).put("pid", pid)
                        .put("nonce", nonceText).put("step", step).put("op", op).put("count", count)
                        .put("local", local).put("remote", address).put("send_successes", sent)
                        .put("send_enobufs", enobufs).put("received", received).put("receive_timeout", timedOut)
                        .put("ready_ns", started).put("released_ns", released)
                        .put("finished_ns", SystemClock.elapsedRealtimeNanos())
                        .put("importance", importance(app)));
            }
            throw new java.io.IOException("command bound exhausted");
        } catch (Exception error) {
            publish(directory, "error", new JSONObject().put("error", error.toString()));
            throw error;
        }
    }
    public static void main(String[] args) throws Exception {
        require(args.length == 3, "arguments");
        run(new File(args[0]), args[1], args[2], false);
        System.exit(0);
    }
}
