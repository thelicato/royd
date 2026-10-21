// Pinned android-15.0.0_r36 excerpts used by patch and decision contracts.
package com.android.networkstack.tethering;

import android.content.Context;
import android.content.pm.PackageManager;

import com.android.networkstack.tethering.util.PrefixUtils;
import com.android.networkstack.tethering.util.VersionedBroadcastListener;
import com.android.networkstack.tethering.wear.WearableConnectionManager;

import java.io.FileDescriptor;
import java.io.PrintWriter;
import java.net.InetAddress;

public class Tethering {
    private boolean mRndisEnabled;       // track the RNDIS function enabled state
    private boolean mNcmEnabled;         // track the NCM function enabled state
    private Network mTetherUpstream;
    private boolean mDataSaverEnabled = false;
    private String mWifiP2pTetherInterface = null;
    private int mOffloadStatus = TETHER_HARDWARE_OFFLOAD_STOPPED;

    void stopTetheringInternal(int type) {
        mActiveTetheringRequests.remove(type);

        enableTetheringInternal(type, false /* disabled */, null, null);
        mEntitlementMgr.stopProvisioningIfNeeded(type);
    }

    /**
     * Enables or disables tethering for the given type. If provisioning is required, it will
     * schedule provisioning rechecks for the specified interface.
     */
    private void enableTetheringInternal(int type, boolean enable,
            String iface, final IIntResultListener listener) {
    }

    private int setEthernetTethering(final boolean enable) {
        final EthernetManager em = (EthernetManager) mContext.getSystemService(
                Context.ETHERNET_SERVICE);
        if (enable) {
            if (mEthernetCallback != null) {
                Log.d(TAG, "Ethernet tethering already started");
                return TETHER_ERROR_NO_ERROR;
            }

            mEthernetCallback = new EthernetCallback();
            mEthernetIfaceRequest = em.requestTetheredInterface(mExecutor, mEthernetCallback);
        } else {
            stopEthernetTethering();
        }
        return TETHER_ERROR_NO_ERROR;
    }

    private void stopEthernetTethering() {
        if (mConfiguredEthernetIface != null) {
            ensureIpServerStopped(mConfiguredEthernetIface);
            mConfiguredEthernetIface = null;
        }
        if (mEthernetCallback != null) {
            mEthernetIfaceRequest.release();
            mEthernetCallback = null;
            mEthernetIfaceRequest = null;
        }
    }

    private void disableUsbIpServing(boolean forNcmFunction) {
    }

    private boolean isEthernetSupported() {
        return mContext.getSystemService(Context.ETHERNET_SERVICE) != null;
    }

    void setUsbTethering(boolean enable, IIntResultListener listener) {
        mHandler.post(() -> {
        });
    }

    private boolean hasSystemFeature(final String feature) {
        return mContext.getPackageManager().hasSystemFeature(feature);
    }
}
