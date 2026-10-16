package com.android.server.connectivity;

import java.io.IOException;
import java.io.StringReader;

public final class RoydOciNetworkConfigTest {
    static final String HEADER = "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT\n";
    static final String DEFAULT = "eth0 00000000 010011AC 0003 0 0 0 00000000 0 0 0\n";
    static final String CONNECTED = "eth0 000011AC 00000000 0001 0 0 0 0000FFFF 0 0 0\n";
    static void check(boolean value) { if (!value) throw new AssertionError(); }
    static RoydOciNetworkConfig read(String routes, String dns) throws IOException {
        return RoydOciNetworkConfig.read(new StringReader(routes), new StringReader(dns));
    }
    static void reject(String routes, String dns) throws IOException {
        try { read(routes, dns); throw new AssertionError("accepted invalid OCI configuration"); }
        catch (IOException expected) { }
    }
    public static void main(String[] args) throws Exception {
        String routes = HEADER + DEFAULT + CONNECTED;
        String dns = "# Docker\nnameserver 172.17.0.1\nnameserver 127.0.0.11 # embedded\nsearch . example.test\n";
        var config = read(routes, dns);
        check(config.routes.size() == 2 && config.routes.contains("0.0.0.0/0 172.17.0.1"));
        check(config.routes.contains("172.17.0.0/16 0.0.0.0"));
        check(config.dns.size() == 2 && config.dns.get(1).equals("127.0.0.11"));
        check(config.domains.equals(". example.test"));
        check(read(routes, "nameserver 1.1.1.1\nnameserver 1.1.1.1\n").dns.size() == 1);
        check(read(routes + "eth1 000012AC 00000000 0001 0 0 0 0000FFFF 0 0 0\n", dns)
                .routes.equals(config.routes));
        for (String bad : new String[] {"", HEADER, HEADER + CONNECTED, routes + DEFAULT,
                routes.replace("0000FFFF", "00FF00FF"),
                routes.replace("000011AC", "010011AC"),
                routes.replace("0003", "0001"), routes.replace("0003", "0203"),
                routes.replace("0003", "0002"), routes.replace("0003", "xyz"),
                routes.replace("010011AC", "00000000"), routes.replace("eth0", "eth1"),
                routes.replace("010011AC", "INVALID0"), routes.replace("0 0 0\n", "0 0\n"),
                routes + "eth1 00000000 010012AC 0003 0 0 0 00000000 0 0 0\n"}) {
            reject(bad, dns);
        }
        for (String bad : new String[] {"", "# empty\n", "nameserver\n", "nameserver host.test\n",
                "nameserver ::1\n", "nameserver 0.0.0.0\n", "nameserver 224.0.0.1\n",
                "nameserver 256.1.1.1\n", "nameserver 01.1.1.1\n", "nameserver 1.1.1.1 extra\n",
                "nameserver 1.1.1.1\nsearch bad/name\n", "nameserver 1.1.1.1\n".repeat(257),
                "nameserver 1.1.1.1\n" + "#".repeat(4097),
                "nameserver 1.1.1.1\nnameserver 2.2.2.2\nnameserver 3.3.3.3\nnameserver 4.4.4.4\nnameserver 5.5.5.5\n"}) {
            reject(routes, bad);
        }
        reject(routes + CONNECTED.repeat(1024), dns);
        try { config.dns.add("8.8.8.8"); throw new AssertionError(); }
        catch (UnsupportedOperationException expected) { }
        java.lang.System.out.println("OCI IPv4 route/resolver executable contracts passed");
    }
}
