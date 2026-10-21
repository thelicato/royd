/*
 * Copyright (C) 2018 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.android.internal.os;

import static com.android.internal.os.KernelCpuProcStringReader.asLongs;

import android.annotation.Nullable;
import android.os.StrictMode;
import android.util.IntArray;
import android.util.Slog;
import android.util.SparseArray;

import com.android.internal.annotations.VisibleForTesting;
import com.android.internal.os.KernelCpuProcStringReader.ProcFileIterator;
import com.android.internal.os.KernelCpuUidBpfMapReader.BpfMapIterator;

import java.io.FileWriter;
import java.io.IOException;
import java.nio.CharBuffer;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Reads per-UID CPU time proc files. Concrete implementations are all nested inside.
 *
 * This class uses a throttler to reject any {@link #readDelta} or {@link #readAbsolute} call
 * within {@link #mMinTimeBetweenRead}. The throttler can be enable / disabled via a param in
 * the constructor.
 *
 * This class and its subclasses are NOT thread-safe and NOT designed to be accessed by more than
 * one caller since each caller has its own view of delta.
 *
 * @param <T> The type of CPU time for the callback.
 */
public abstract class KernelCpuUidTimeReader<T> {
    protected static final boolean DEBUG = false;
    private static final long DEFAULT_MIN_TIME_BETWEEN_READ = 1000L; // In milliseconds

    final String mTag = this.getClass().getSimpleName();
    final SparseArray<T> mLastTimes = new SparseArray<>();
    final KernelCpuProcStringReader mReader;
    final boolean mThrottle;
    protected boolean mBpfTimesAvailable;
    final KernelCpuUidBpfMapReader mBpfReader;
    private final Clock mClock;
    private long mMinTimeBetweenRead = DEFAULT_MIN_TIME_BETWEEN_READ;
    private long mLastReadTimeMs = 0;

    /**
     * Callback interface for processing each line of the proc file.
     *
     * @param <T> The type of CPU time for the callback function.
     */
    public interface Callback<T> {
        /**
         * @param uid  UID of the app
         * @param time Time spent. The exact data structure depends on subclass implementation.
         */
        void onUidCpuTime(int uid, T time);
    }

    KernelCpuUidTimeReader(KernelCpuProcStringReader reader,
            @Nullable KernelCpuUidBpfMapReader bpfReader, boolean throttle, Clock clock) {
        mReader = reader;
        mThrottle = throttle;
        mBpfReader = bpfReader;
        mClock = clock;
        mBpfTimesAvailable = (mBpfReader != null);
    }

    KernelCpuUidTimeReader(KernelCpuProcStringReader reader, boolean throttle, Clock clock) {
        this(reader, null, throttle, clock);
    }

    /**
     * Reads the proc file, calling into the callback with a delta of time for each UID.
     *
     * @param cb The callback to invoke for each line of the proc file. If null,the data is
     */
    public void readDelta(@Nullable Callback<T> cb) {
        readDelta(false, cb);
    }

    /**
     * Reads the proc file, calling into the callback with a delta of time for each UID.
     *
     * @param force Ignore the throttling and force read the delta.
     * @param cb The callback to invoke for each line of the proc file. If null,the data is
     */
    public void readDelta(boolean force, @Nullable Callback<T> cb) {
        if (!mThrottle) {
            readDeltaImpl(cb, force);
            return;
        }
        final long currTimeMs = mClock.elapsedRealtime();
        if (!force && currTimeMs < mLastReadTimeMs + mMinTimeBetweenRead) {
            if (DEBUG) {
                Slog.d(mTag, "Throttle readDelta");
            }
            return;
        }
        readDeltaImpl(cb, force);
        mLastReadTimeMs = currTimeMs;
    }

    /**
     * Reads the proc file, calling into the callback with cumulative time for each UID.
     *
     * @param cb The callback to invoke for each line of the proc file. It cannot be null.
     */
    public void readAbsolute(Callback<T> cb) {
        if (!mThrottle) {
            readAbsoluteImpl(cb);
            return;
        }
        final long currTimeMs = mClock.elapsedRealtime();
        if (currTimeMs < mLastReadTimeMs + mMinTimeBetweenRead) {
            if (DEBUG) {
                Slog.d(mTag, "Throttle readAbsolute");
            }
            return;
        }
        readAbsoluteImpl(cb);
        mLastReadTimeMs = currTimeMs;
    }

    abstract void readDeltaImpl(@Nullable Callback<T> cb, boolean forceRead);

    abstract void readAbsoluteImpl(Callback<T> callback);

    /**
     * Removes the UID from internal accounting data. This method, overridden in
     * {@link KernelCpuUidUserSysTimeReader}, also removes the UID from the kernel module.
     *
     * @param uid The UID to remove.
     * @see KernelCpuUidUserSysTimeReader#removeUid(int)
     */
    public void removeUid(int uid) {
        mLastTimes.delete(uid);

        if (mBpfTimesAvailable) {
            mBpfReader.removeUidsInRange(uid, uid);
        }
    }

    /**
     * Removes UIDs in a given range from internal accounting data. This method, overridden in
     * {@link KernelCpuUidUserSysTimeReader}, also removes the UIDs from the kernel module.
     *
     * @param startUid the first uid to remove.
     * @param endUid   the last uid to remove.
     * @see KernelCpuUidUserSysTimeReader#removeUidsInRange(int, int)
     */
    public void removeUidsInRange(int startUid, int endUid) {
        if (endUid < startUid) {
            Slog.e(mTag, "start UID " + startUid + " > end UID " + endUid);
            return;
        }
        mLastTimes.put(startUid, null);
        mLastTimes.put(endUid, null);
        int firstIndex = mLastTimes.indexOfKey(startUid);
        int lastIndex = mLastTimes.indexOfKey(endUid);
        mLastTimes.removeAtRange(firstIndex, lastIndex - firstIndex + 1);

        if (mBpfTimesAvailable) {
            mBpfReader.removeUidsInRange(startUid, endUid);
        }
    }

    /**
     * Set the minimum time in milliseconds between reads. If throttle is not enabled, this method
     * has no effect.
     *
     * @param minTimeBetweenRead The minimum time in milliseconds.
     */
    public void setThrottle(long minTimeBetweenRead) {
        if (mThrottle && minTimeBetweenRead >= 0) {
            mMinTimeBetweenRead = minTimeBetweenRead;
        }
    }

    /**
     * Reads /proc/uid_cputime/show_uid_stat which has the line format:
     *
     * uid: user_time_micro_seconds system_time_micro_seconds power_in_milli-amp-micro_seconds
     *
     * This provides the time a UID's processes spent executing in user-space and kernel-space.
     * The file contains a monotonically increasing count of time for a single boot. This class
     * maintains the previous results of a call to {@link #readDelta} in order to provide a proper
     * delta.
     *
     * The second parameter of the callback is a long[] with 2 elements, [user time in us, system
     * time in us].
     */
    public static class KernelCpuUidUserSysTimeReader extends KernelCpuUidTimeReader<long[]> {
        private static final String REMOVE_UID_PROC_FILE = "/proc/uid_cputime/remove_uid_range";

        // [uid, user_time, system_time, (maybe) power_in_milli-amp-micro_seconds]
        private final long[] mBuffer = new long[4];
        // A reusable array to hold [user_time, system_time] for the callback.
        private final long[] mUsrSysTime = new long[2];

        public KernelCpuUidUserSysTimeReader(boolean throttle) {
            this(throttle, Clock.SYSTEM_CLOCK);
        }

        public KernelCpuUidUserSysTimeReader(boolean throttle, Clock clock) {
            super(KernelCpuProcStringReader.getUserSysTimeReaderInstance(), throttle, clock);
        }

        @VisibleForTesting
        public KernelCpuUidUserSysTimeReader(KernelCpuProcStringReader reader, boolean throttle,
                Clock clock) {
            super(reader, throttle, clock);
        }

        @Override
        void readDeltaImpl(@Nullable Callback<long[]> cb, boolean forceRead) {
            try (ProcFileIterator iter = mReader.open(!mThrottle || forceRead)) {
                if (iter == null) {
                    return;
                }
                CharBuffer buf;
                while ((buf = iter.nextLine()) != null) {
                    if (asLongs(buf, mBuffer) < 3) {
                        Slog.wtf(mTag, "Invalid line: " + buf.toString());
                        continue;
                    }
                    final int uid = (int) mBuffer[0];
                    long[] lastTimes = mLastTimes.get(uid);
                    if (lastTimes == null) {
                        lastTimes = new long[2];
                        mLastTimes.put(uid, lastTimes);
                    }
                    final long currUsrTimeUs = mBuffer[1];
                    final long currSysTimeUs = mBuffer[2];
                    mUsrSysTime[0] = currUsrTimeUs - lastTimes[0];
                    mUsrSysTime[1] = currSysTimeUs - lastTimes[1];

                    if (mUsrSysTime[0] < 0 || mUsrSysTime[1] < 0) {
                        Slog.e(mTag, "Negative user/sys time delta for UID=" + uid
                                + "\nPrev times: u=" + lastTimes[0] + " s=" + lastTimes[1]
                                + " Curr times: u=" + currUsrTimeUs + " s=" + currSysTimeUs);
                    } else if (mUsrSysTime[0] > 0 || mUsrSysTime[1] > 0) {
                        if (cb != null) {
                            cb.onUidCpuTime(uid, mUsrSysTime);
                        }
                    }
                    lastTimes[0] = currUsrTimeUs;
                    lastTimes[1] = currSysTimeUs;
                }
            }
        }

        @Override
        void readAbsoluteImpl(Callback<long[]> cb) {
            try (ProcFileIterator iter = mReader.open(!mThrottle)) {
                if (iter == null) {
                    return;
                }
                CharBuffer buf;
                while ((buf = iter.nextLine()) != null) {
                    if (asLongs(buf, mBuffer) < 3) {
                        Slog.wtf(mTag, "Invalid line: " + buf.toString());
                        continue;
                    }
                    mUsrSysTime[0] = mBuffer[1]; // User time in microseconds
                    mUsrSysTime[1] = mBuffer[2]; // System time in microseconds
                    cb.onUidCpuTime((int) mBuffer[0], mUsrSysTime);
                }
            }
        }

        @Override
        public void removeUid(int uid) {
            super.removeUid(uid);
            removeUidsFromKernelModule(uid, uid);
        }

        @Override
        public void removeUidsInRange(int startUid, int endUid) {
            super.removeUidsInRange(startUid, endUid);
            removeUidsFromKernelModule(startUid, endUid);
        }

        /**
         * Removes UIDs in a given range from the kernel module and internal accounting data. Only
         * {@link BatteryStatsImpl} and its child processes should call this, as the change on
         * Kernel is
         * visible system wide.
         *
         * @param startUid the first uid to remove
         * @param endUid   the last uid to remove
         */
        private void removeUidsFromKernelModule(int startUid, int endUid) {
            Slog.d(mTag, "Removing uids " + startUid + "-" + endUid);
            final int oldMask = StrictMode.allowThreadDiskWritesMask();
            try (FileWriter writer = new FileWriter(REMOVE_UID_PROC_FILE)) {
                writer.write(startUid + "-" + endUid);
                writer.flush();
            } catch (IOException e) {
                Slog.e(mTag, "failed to remove uids " + startUid + " - " + endUid
                        + " from uid_cputime module", e);
            } finally {
                StrictMode.setThreadPolicyMask(oldMask);
            }
        }
    }
}
