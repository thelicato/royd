// Pinned android-15.0.0_r36 excerpts for production patch/decision contracts.
public class StorageStatsService extends IStorageStatsManager.Stub {
    private static final String TAG = "StorageStatsService";

    private static final String PROP_STORAGE_CRATES = "fw.storage_crates";
    private static final String PROP_DISABLE_QUOTA = "fw.disable_quota";

    @Override
    public long getTotalBytes(String volumeUuid, String callingPackage) {
        // NOTE: No permissions required

        if (volumeUuid == StorageManager.UUID_PRIVATE_INTERNAL) {
            // As a safety measure, use the original implementation for the devices
            // with storage size <= 512GB to prevent any potential regressions
            final long roundedUserspaceBytes = mStorage.getPrimaryStorageSize();
            if (roundedUserspaceBytes <= DataUnit.GIGABYTES.toBytes(512)) {
                return roundedUserspaceBytes;
            }

            // Since 1TB devices can actually have either 1000GB or 1024GB,
            // get the block device size and do just a small rounding if any at all
            final long totalBytes = mStorage.getInternalStorageBlockDeviceSize();
            final long totalBytesRounded = FileUtils.roundStorageSize(totalBytes);
            // If the storage size is 997GB-999GB, round it to a 1000GB to show
            // 1TB in UI instead of 0.99TB. Same for 2TB, 4TB, 8TB etc.
            if (totalBytesRounded - totalBytes <= DataUnit.GIGABYTES.toBytes(3)) {
                return totalBytesRounded;
            } else {
                return totalBytes;
            }
        } else {
            final VolumeInfo vol = mStorage.findVolumeByUuid(volumeUuid);
            if (vol == null) {
                throw new ParcelableException(
                        new IOException("Failed to find storage device for UUID " + volumeUuid));
            }
            return FileUtils.roundStorageSize(vol.disk.size);
        }
    }
}
