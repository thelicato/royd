package com.android.server.connectivity;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.Reader;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Strict, read-only IPv4 snapshot of OCI-owned main routes and resolver configuration. */
public final class RoydOciNetworkConfig {
    public static final String INTERFACE = "eth0";
    public final List<String> routes;
    public final List<String> dns;
    public final String domains;

    private RoydOciNetworkConfig(List<String> routes, List<String> dns, String domains) {
        this.routes = Collections.unmodifiableList(routes);
        this.dns = Collections.unmodifiableList(dns);
        this.domains = domains;
    }

    static String ipv4(String value) throws IOException {
        String[] parts = value.split("\\.", -1);
        if (parts.length != 4) throw new IOException("non-IPv4 resolver or route");
        StringBuilder result = new StringBuilder();
        for (String part : parts) {
            if (!part.matches("0|[1-9][0-9]{0,2}")) throw new IOException("invalid IPv4 literal");
            int number = Integer.parseInt(part);
            if (number > 255) throw new IOException("invalid IPv4 octet");
            if (result.length() != 0) result.append('.');
            result.append(number);
        }
        return result.toString();
    }

    private static String procAddress(String value) throws IOException {
        if (!value.matches("[0-9A-Fa-f]{8}")) throw new IOException("invalid main-route address");
        byte[] bytes = ByteBuffer.allocate(4).order(ByteOrder.nativeOrder())
                .putInt((int) Long.parseLong(value, 16)).array();
        return (bytes[0] & 255) + "." + (bytes[1] & 255) + "."
                + (bytes[2] & 255) + "." + (bytes[3] & 255);
    }

    private static long number(String address) throws IOException {
        long result = 0;
        for (String part : ipv4(address).split("\\.")) result = (result << 8) | Integer.parseInt(part);
        return result;
    }

    /** /proc/net/route exposes RT_TABLE_MAIN, not Android's per-network tables. */
    public static RoydOciNetworkConfig read(Reader routeReader, Reader dnsReader) throws IOException {
        BufferedReader input = new BufferedReader(routeReader);
        String line = input.readLine();
        if (line == null || !line.trim().startsWith("Iface\tDestination\tGateway")) {
            throw new IOException("missing main-route header");
        }
        Map<String, String> routes = new LinkedHashMap<>();
        int defaults = 0;
        int count = 0;
        while ((line = input.readLine()) != null) {
            if (++count > 1024 || line.length() > 4096) throw new IOException("main routes too large");
            String[] fields = line.trim().split("\\s+");
            if (!INTERFACE.equals(fields[0])) {
                if (fields.length == 11 && fields[1].equals("00000000")
                        && fields[7].equals("00000000")) {
                    throw new IOException("default route on another interface");
                }
                continue;
            }
            if (fields.length != 11) throw new IOException("invalid eth0 main route");
            int flags;
            try { flags = Integer.parseInt(fields[3], 16); }
            catch (NumberFormatException error) { throw new IOException("invalid route flags", error); }
            if ((flags & 1) == 0 || (flags & 0x200) != 0) continue;
            String destination = procAddress(fields[1]);
            String gateway = procAddress(fields[2]);
            long mask = number(procAddress(fields[7]));
            int prefix = Long.bitCount(mask);
            long inverse = (~mask) & 0xffffffffL;
            if ((inverse & (inverse + 1)) != 0 || (number(destination) & inverse) != 0) {
                throw new IOException("non-prefix main route");
            }
            if (((flags & 2) != 0) == gateway.equals("0.0.0.0")) {
                throw new IOException("inconsistent main-route gateway");
            }
            String key = destination + "/" + prefix;
            // RouteInfo does not preserve Linux metrics. Never collapse competing routes.
            if (routes.put(key, gateway) != null) throw new IOException("competing eth0 routes");
            if (prefix == 0) {
                if (gateway.equals("0.0.0.0")) throw new IOException("gatewayless default route");
                defaults++;
            }
        }
        if (defaults != 1) throw new IOException("one eth0 IPv4 default route required");
        List<String> result = new ArrayList<>();
        for (Map.Entry<String, String> route : routes.entrySet()) {
            result.add(route.getKey() + " " + route.getValue());
        }
        input = new BufferedReader(dnsReader);
        Set<String> servers = new LinkedHashSet<>();
        String domains = "";
        count = 0;
        while ((line = input.readLine()) != null) {
            if (++count > 256 || line.length() > 4096) throw new IOException("resolver file too large");
            line = line.split("[#;]", 2)[0].trim();
            if (line.isEmpty()) continue;
            String[] fields = line.split("\\s+");
            if (fields[0].equals("nameserver")) {
                if (fields.length != 2) throw new IOException("invalid resolver entry");
                String address = ipv4(fields[1]);
                long value = number(address);
                if (value == 0 || value >= 0xe0000000L) throw new IOException("non-unicast resolver");
                servers.add(address);
                if (servers.size() > 4) throw new IOException("too many resolvers");
            } else if (fields[0].equals("search") || fields[0].equals("domain")) {
                StringBuilder search = new StringBuilder();
                for (int i = 1; i < fields.length; i++) {
                    if (!fields[i].matches("[A-Za-z0-9_.-]{1,253}")) {
                        throw new IOException("invalid resolver search domain");
                    }
                    if (search.length() != 0) search.append(' ');
                    search.append(fields[i]);
                }
                domains = search.toString();
            }
        }
        if (servers.isEmpty()) throw new IOException("no IPv4 OCI resolver");
        return new RoydOciNetworkConfig(result, new ArrayList<>(servers), domains);
    }
}
