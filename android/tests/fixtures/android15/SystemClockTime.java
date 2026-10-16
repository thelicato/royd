class SystemClockTime {
    private static @TimeConfidence int sTimeConfidence = TIME_CONFIDENCE_LOW;

    private static final long sNativeData = init();

    private SystemClockTime() {
    }

    public static void setTimeAndConfidence(
            @CurrentTimeMillisLong long unixEpochMillis, int confidence, @NonNull String logMsg) {
        synchronized (SystemClockTime.class) {
            setTime(sNativeData, unixEpochMillis);
            sTimeConfidence = confidence;
            sTimeDebugLog.log(logMsg);
        }
    }
}
