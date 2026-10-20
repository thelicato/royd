    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    @Override
    public void setDataSaverEnabled(final boolean enable) {
        enforceNetworkStackOrSettingsPermission();
        try {
            final boolean ret = mNetd.bandwidthEnableDataSaver(enable);
            if (!ret) {
                throw new IllegalStateException("Error when changing iptables: " + enable);
            }
        } catch (RemoteException e) {
            // Lack of permission or binder errors.
            throw new IllegalStateException(e);
        }

        synchronized (mBlockedStatusTrackingUids) {
            try {
                mBpfNetMaps.setDataSaverEnabled(enable);
            } catch (ServiceSpecificException | UnsupportedOperationException e) {
                Log.e(TAG, "Failed to set data saver " + enable + " : " + e);
                return;
            }

            if (shouldTrackUidsForBlockedStatusCallbacks()) {
                updateTrackingUidsBlockedReasons();
            }
        }
    }
