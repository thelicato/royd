package org.royd.networkprobe;

import android.app.ActivityManager;
import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import android.os.Process;
import android.os.SystemClock;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.util.Log;
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

/** One ordinary UID, process and connected UDP socket through deny/restoration. */
public final class AccountingProbeService extends Service {
    private static final int COUNT = 64, SIZE = 1200;
    private boolean started;
    private File directory;
    @Override public IBinder onBind(Intent intent) { return null; }
    private static void require(boolean valid, String reason) throws Exception {
        if (!valid) throw new java.io.IOException(reason);
    }
    private static int importance() {
        ActivityManager.RunningAppProcessInfo info = new ActivityManager.RunningAppProcessInfo();
        ActivityManager.getMyMemoryState(info);
        return info.importance;
    }
    private void publish(String name, JSONObject observation) throws Exception {
        File temporary = new File(directory, name + ".tmp"), target = new File(directory, name + ".json");
        require(temporary.createNewFile(), "observation already exists");
        try (FileOutputStream output = new FileOutputStream(temporary)) {
            output.write(observation.toString().getBytes(StandardCharsets.UTF_8));
        }
        Os.link(temporary.getPath(), target.getPath());
        require(temporary.delete(), "temporary observation cleanup failed");
    }
    private static byte[] payload(byte[] nonce, int phase, int uid, int sequence) {
        byte[] data = new byte[SIZE];
        ByteBuffer.wrap(data).put(nonce).putInt(phase).putInt(uid).putInt(sequence).putInt(COUNT);
        for (int i = 33; i < SIZE; i++) data[i] = (byte) (i + sequence + uid);
        return data;
    }
    private void command(String nonce, int phase) throws Exception {
        File input = new File(directory, "command-" + phase);
        long deadline = SystemClock.elapsedRealtime() + 45000;
        while (!input.exists()) {
            require(SystemClock.elapsedRealtime() < deadline, "accounting command timed out");
            Thread.sleep(20);
        }
        try (FileInputStream stream = new FileInputStream(input)) {
            byte[] data = stream.readNBytes(65);
            require(new String(data, StandardCharsets.UTF_8).equals(nonce + "\n"), "command identity mismatch: bytes=" + data.length);
        }
    }
    private static String readSelf(String path, int maximum) throws Exception {
        try (FileInputStream input = new FileInputStream(path)) {
            byte[] data = input.readNBytes(maximum + 1);
            require(data.length <= maximum, "process metadata exceeds observation bound");
            return new String(data, StandardCharsets.UTF_8);
        }
    }
    private void runProbe(Intent intent) throws Exception {
        String nonceText = intent.getStringExtra("nonce"), address = intent.getStringExtra("address");
        String role = intent.getStringExtra("role");
        require(nonceText != null && nonceText.matches("[0-9a-f]{32}") && ("target".equals(role) || "control".equals(role)), "invalid probe identity");
        int colon = address.lastIndexOf(':');
        String host = address.substring(0, colon);
        require(host.matches("[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"), "literal IPv4 required");
        InetAddress remote = InetAddress.getByName(host);
        int port = Integer.parseInt(address.substring(colon + 1));
        require(remote.isSiteLocalAddress() && port > 0 && port <= 65535, "private fixture required");
        byte[] nonce = new byte[16];
        for (int i = 0; i < 16; i++) nonce[i] = (byte) Integer.parseInt(nonceText.substring(i * 2, i * 2 + 2), 16);
        directory = new File(getFilesDir(), "accounting-" + nonceText);
        require(directory.mkdir(), "accounting directory already exists");
        int uid = Process.myUid(), pid = Process.myPid();
        require(uid >= 10000 && uid < 20000, "ordinary user-0 application UID required");
        try (DatagramSocket socket = new DatagramSocket()) {
            socket.setReceiveBufferSize(1 << 20);
            socket.connect(remote, port);
            socket.setSoTimeout(1500);
            long deadline = SystemClock.elapsedRealtime() + 15000;
            while (importance() != ActivityManager.RunningAppProcessInfo.IMPORTANCE_SERVICE) {
                require(SystemClock.elapsedRealtime() < deadline, "ordinary service state timed out");
                Thread.sleep(20);
            }
            String local = socket.getLocalAddress().getHostAddress() + ":" + socket.getLocalPort();
            String status = readSelf("/proc/self/status", 16384);
            String capabilities = "";
            for (String line : status.split("\n")) if (line.startsWith("CapEff:")) capabilities = line.substring(7).trim();
            String cgroup = readSelf("/proc/self/cgroup", 4096);
            publish("ready", new JSONObject().put("event", "ready").put("uid", uid).put("pid", pid)
                    .put("gid", Os.getgid()).put("role", role).put("local", local).put("remote", address).put("nonce", nonceText)
                    .put("cap_eff", capabilities).put("cgroup", cgroup).put("importance", importance()));
            int first = "target".equals(role) ? 8 : 9;
            for (int phase = first; phase <= first + 4; phase += 2) {
                command(nonceText, phase);
                int sent = 0, denied = 0, received = 0;
                String denial = "";
                boolean timedOut = false;
                long start = SystemClock.elapsedRealtimeNanos();
                for (int sequence = 0; sequence < COUNT; sequence++) {
                    byte[] data = payload(nonce, phase, uid, sequence);
                    try {
                        socket.send(new DatagramPacket(data, data.length));
                        sent++;
                    } catch (Exception error) {
                        boolean eperm = false;
                        for (Throwable cause = error; cause != null; cause = cause.getCause()) {
                            if (cause instanceof ErrnoException && ((ErrnoException) cause).errno == OsConstants.EPERM) eperm = true;
                        }
                        if (!eperm) throw error;
                        denial = error.toString();
                        denied++;
                    }
                    Thread.sleep(1);
                }
                boolean[] seen = new boolean[COUNT];
                try {
                    for (int i = 0; i < COUNT; i++) {
                        byte[] data = new byte[SIZE + 1];
                        DatagramPacket reply = new DatagramPacket(data, data.length);
                        socket.receive(reply);
                        int sequence = ByteBuffer.wrap(data).getInt(24);
                        require(reply.getLength() == SIZE && sequence >= 0 && sequence < COUNT && !seen[sequence]
                                && Arrays.equals(Arrays.copyOf(data, SIZE), payload(nonce, phase, uid, sequence)), "invalid or duplicate UDP reply");
                        seen[sequence] = true;
                        received++;
                    }
                } catch (SocketTimeoutException expected) { timedOut = true; }
                publish("phase-" + phase, new JSONObject().put("event", "policy-complete").put("phase", phase)
                        .put("role", role).put("uid", uid).put("pid", pid).put("nonce", nonceText)
                        .put("local", local).put("remote", address).put("send_attempts", COUNT).put("send_successes", sent)
                        .put("send_eperm", denied).put("denial", denial).put("receive_packets", received).put("receive_timeout", timedOut)
                        .put("start_ns", start).put("end_ns", SystemClock.elapsedRealtimeNanos()).put("importance", importance()));
            }
            command(nonceText, 14);
        }
    }
    @Override public synchronized int onStartCommand(Intent intent, int flags, int startId) {
        if (started) return START_NOT_STICKY;
        started = true;
        new Thread(() -> {
            try { runProbe(intent); }
            catch (Exception error) {
                Log.e("RoydAccountingProbe", "accounting observation failed", error);
                if (directory != null) try { publish("error", new JSONObject().put("error", error.toString())); }
                catch (Exception publication) { Log.e("RoydAccountingProbe", "error publication failed", publication); }
            } finally { stopSelf(); }
        }, "royd-accounting").start();
        return START_NOT_STICKY;
    }
}
