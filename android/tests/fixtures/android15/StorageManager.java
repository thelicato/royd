// Pinned android-15.0.0_r36 excerpts for production patch/decision contracts.
class StorageManager {
    /** {@hide} */
    public static Pair<String, Long> getPrimaryStoragePathAndSize() {
        return Pair.create(null,
                FileUtils.roundStorageSize(Environment.getDataDirectory().getTotalSpace()
                    + Environment.getRootDirectory().getTotalSpace()));
    }

    /** {@hide} */
    public long getPrimaryStorageSize() {
        return FileUtils.roundStorageSize(Environment.getDataDirectory().getTotalSpace()
                + Environment.getRootDirectory().getTotalSpace());
    }

    /** {@hide} */
    public long getInternalStorageBlockDeviceSize() {
        try {
        }
    }
}
