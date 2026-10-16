    private final TelephonyManager mTelephonyManager;
    private final WifiManager mWifiManager;
    private final ConnectivityManager mCm;
    private final NetworkStackNotifier mNotifier;

    public NetworkMonitor(Context context, INetworkMonitorCallbacks cb, Network network,
            SharedLog validationLog, @NonNull NetworkStackServiceManager serviceManager) {
        this(context, cb, network, new IpConnectivityLog(), validationLog, serviceManager,

        mCleartextDnsNetwork = deps.getPrivateDnsBypassNetwork(network);
        mTelephonyManager = (TelephonyManager) context.getSystemService(Context.TELEPHONY_SERVICE);
        mWifiManager = (WifiManager) context.getSystemService(Context.WIFI_SERVICE);
        mCm = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        mNotifier = serviceManager.getNotifier();

            case NetworkCapabilities.TRANSPORT_WIFI:
                // TODO: Update it if status query in dual wifi is supported.
                final WifiInfo wifiInfo = mWifiManager.getConnectionInfo();
                stats.setWiFiData(wifiInfo);
                break;
