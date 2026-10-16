package com.android.server.connectivity;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.InetAddresses;
import android.net.IpPrefix;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.NetworkAgent;
import android.net.NetworkAgentConfig;
import android.net.NetworkCapabilities;
import android.net.NetworkProvider;
import android.net.NetworkRequest;
import android.net.NetworkScore;
import android.net.RouteInfo;
import android.os.Handler;
import android.os.HandlerThread;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.util.Log;
import androidx.annotation.RequiresApi;

import java.io.FileReader;
import java.io.IOException;
import java.net.Inet4Address;
import java.net.InterfaceAddress;
import java.net.NetworkInterface;
import java.util.HashSet;
import java.util.Set;

/** Publishes OCI configuration, never provisions or takes ownership of the Linux interface. */
@RequiresApi(35)
public final class RoydOciNetwork {
    private static final String TAG = "RoydOciNetwork";
    private static final long POLL_MS = 5000;
    private static RoydOciNetwork sInstance;
    private final Context mContext;
    private final Handler mHandler;
    private final NetworkProvider mProvider;
    private final NetworkCapabilities mCapabilities;
    private final NetworkScore mScore = new NetworkScore.Builder().build();
    private final Set<NetworkRequest> mRequests = new HashSet<>();
    private NetworkProvider.NetworkOfferCallback mOffer;
    private LinkProperties mLink;
    private NetworkAgent mAgent;
    private String mError;

    public static synchronized void startIfContainer(Context context) {
        if (!"1".equals(System.getenv("ROYD_CONTAINER"))) return;
        try {
            Os.stat("/sys/fs/selinux/enforce");
            return;
        } catch (ErrnoException error) {
            if (error.errno != OsConstants.ENOENT) {
                Log.w(TAG, "ROYD: cannot establish OCI SELinux gate", error);
                return;
            }
        }
        if (sInstance == null) sInstance = new RoydOciNetwork(context);
    }

    private RoydOciNetwork(Context context) {
        mContext = context;
        HandlerThread thread = new HandlerThread(TAG);
        thread.start();
        mHandler = new Handler(thread.getLooper());
        mCapabilities = new NetworkCapabilities.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VCN_MANAGED)
                .build();
        // Leave metering conservative and validation entirely to NetworkMonitor.
        mProvider = new NetworkProvider(context, thread.getLooper(), TAG);
        mHandler.post(() -> {
            context.getSystemService(ConnectivityManager.class).registerNetworkProvider(mProvider);
            poll();
        });
    }

    private LinkProperties snapshot() throws IOException {
        NetworkInterface iface = NetworkInterface.getByName(RoydOciNetworkConfig.INTERFACE);
        if (iface == null || !iface.isUp()) throw new IOException("eth0 is absent or down");
        LinkProperties link = new LinkProperties();
        link.setInterfaceName(RoydOciNetworkConfig.INTERFACE);
        for (InterfaceAddress address : iface.getInterfaceAddresses()) {
            if (!(address.getAddress() instanceof Inet4Address)) continue;
            if (address.getAddress().isAnyLocalAddress() || address.getAddress().isLoopbackAddress()
                    || address.getAddress().isMulticastAddress()) continue;
            link.addLinkAddress(new LinkAddress(address.getAddress(), address.getNetworkPrefixLength()));
        }
        if (link.getLinkAddresses().isEmpty()) throw new IOException("eth0 has no IPv4 address");
        RoydOciNetworkConfig config;
        try (FileReader routes = new FileReader("/proc/net/route");
                FileReader dns = new FileReader("/etc/resolv.conf")) {
            config = RoydOciNetworkConfig.read(routes, dns);
        }
        for (String value : config.routes) {
            String[] fields = value.split(" ");
            link.addRoute(new RouteInfo(new IpPrefix(fields[0]),
                    InetAddresses.parseNumericAddress(fields[1]), RoydOciNetworkConfig.INTERFACE));
        }
        for (String server : config.dns) link.addDnsServer(InetAddresses.parseNumericAddress(server));
        link.setDomains(config.domains);
        // Unset MTU means ConnectivityService must not write OCI's existing interface MTU.
        return link;
    }

    private void poll() {
        try {
            LinkProperties next = snapshot();
            if (mOffer == null) {
                mLink = next;
                offer();
            } else if (!next.equals(mLink)) {
                mLink = next;
                if (mAgent != null) mAgent.sendLinkProperties(next);
                Log.i(TAG, "ROYD: updated OCI eth0 network configuration");
            }
            mError = null;
        } catch (IOException error) {
            withdraw();
            if (!error.toString().equals(mError)) {
                Log.w(TAG, "ROYD: OCI network unavailable: " + error);
                mError = error.toString();
            }
        } finally {
            mHandler.postDelayed(this::poll, POLL_MS);
        }
    }

    private void offer() {
        mOffer = new NetworkProvider.NetworkOfferCallback() {
            @Override public void onNetworkNeeded(NetworkRequest request) {
                if (mOffer != this) return;
                mRequests.add(request);
                connect();
            }
            @Override public void onNetworkUnneeded(NetworkRequest request) {
                if (mOffer != this) return;
                mRequests.remove(request);
                if (mRequests.isEmpty()) disconnect();
            }
        };
        mProvider.registerNetworkOffer(mScore, mCapabilities, task -> mHandler.post(task), mOffer);
        Log.i(TAG, "ROYD: offering OCI-owned eth0 IPv4 network");
    }

    private void connect() {
        if (mAgent != null || mLink == null) return;
        mAgent = new NetworkAgent(mContext, mHandler.getLooper(), TAG, mCapabilities, mLink,
                mScore, new NetworkAgentConfig.Builder()
                        .setLegacyType(ConnectivityManager.TYPE_ETHERNET)
                        .setLegacyTypeName("ETHERNET").setLegacyExtraInfo("royd OCI eth0").build(),
                mProvider) {
            @Override public void onNetworkUnwanted() {
                if (mAgent != this) return;
                disconnect();
            }
        };
        mAgent.register();
        mAgent.markConnected();
        Log.i(TAG, "ROYD: published OCI-owned eth0 network " + mAgent.getNetwork());
    }

    private void disconnect() {
        if (mAgent != null) {
            mAgent.unregister();
            mAgent = null;
        }
    }

    private void withdraw() {
        if (mOffer != null) {
            NetworkProvider.NetworkOfferCallback old = mOffer;
            mOffer = null;
            mProvider.unregisterNetworkOffer(old);
            mRequests.clear();
        }
        disconnect();
        mLink = null;
    }
}
