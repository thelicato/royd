class AlarmManagerService {
    boolean setTimeImpl(
            @CurrentTimeMillisLong long newSystemClockTimeMillis, @TimeConfidence int confidence,
            @NonNull String logMsg) {
        synchronized (mLock) {
            mInjector.setCurrentTimeMillis(newSystemClockTimeMillis, confidence, logMsg);

            // The native implementation of setKernelTime can return -1 even when the kernel
            // time was set correctly, so assume setting kernel time was successful and always
            // return true.
            return true;
        }
    }
}
