/*
 * Copyright (C) 2008 The Android Open Source Project
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

// Pinned android-15.0.0_r36 nested class, embedded by the timing contracts.
public static class HandlerChecker implements Runnable {
        private final Handler mHandler;
        private final String mName;
        private final ArrayList<Monitor> mMonitors = new ArrayList<Monitor>();
        private final ArrayList<Monitor> mMonitorQueue = new ArrayList<Monitor>();
        private long mWaitMaxMillis;
        private boolean mCompleted;
        private Monitor mCurrentMonitor;
        private long mStartTimeMillis;
        private int mPauseCount;
        private long mPauseEndTimeMillis;
        private Clock mClock;
        private Object mLock;

        HandlerChecker(Handler handler, String name, Object lock, Clock clock) {
            mHandler = handler;
            mName = name;
            mLock = lock;
            mCompleted = true;
            mClock = clock;
        }

        HandlerChecker(Handler handler, String name, Object lock) {
            this(handler, name, lock, SystemClock.uptimeClock());
        }

        void addMonitorLocked(Monitor monitor) {
            // We don't want to update mMonitors when the Handler is in the middle of checking
            // all monitors. We will update mMonitors on the next schedule if it is safe
            mMonitorQueue.add(monitor);
        }

        /**
         * Schedules a run on the handler thread.
         *
         * @param handlerCheckerTimeoutMillis the timeout to use for this run
         */
        public void scheduleCheckLocked(long handlerCheckerTimeoutMillis) {
            mWaitMaxMillis = handlerCheckerTimeoutMillis;

            if (mCompleted && !mMonitorQueue.isEmpty()) {
                // Safe to update monitors in queue, Handler is not in the middle of work
                mMonitors.addAll(mMonitorQueue);
                mMonitorQueue.clear();
            }

            long nowMillis = mClock.millis();
            boolean isPaused = mPauseCount > 0 || mPauseEndTimeMillis > nowMillis;
            if ((mMonitors.size() == 0 && isHandlerPolling()) || isPaused) {
                // Don't schedule until after resume OR
                // If the target looper has recently been polling, then
                // there is no reason to enqueue our checker on it since that
                // is as good as it not being deadlocked.  This avoid having
                // to do a context switch to check the thread. Note that we
                // only do this if we have no monitors since those would need to
                // be executed at this point.
                mCompleted = true;
                return;
            }
            if (!mCompleted) {
                // we already have a check in flight, so no need
                return;
            }

            mCompleted = false;
            mCurrentMonitor = null;
            mStartTimeMillis = nowMillis;
            mPauseEndTimeMillis = 0;
            mHandler.postAtFrontOfQueue(this);
        }

        boolean isHandlerPolling() {
            return mHandler.getLooper().getQueue().isPolling();
        }

        public int getCompletionStateLocked() {
            if (mCompleted) {
                return COMPLETED;
            } else {
                long latency = mClock.millis() - mStartTimeMillis;
                if (latency < mWaitMaxMillis / PRE_WATCHDOG_TIMEOUT_RATIO) {
                    return WAITING;
                } else if (latency < mWaitMaxMillis) {
                    return WAITED_UNTIL_PRE_WATCHDOG;
                }
            }
            return OVERDUE;
        }

        public Thread getThread() {
            return mHandler.getLooper().getThread();
        }

        public String getName() {
            return mName;
        }

        String describeBlockedStateLocked() {
            final String prefix;
            if (mCurrentMonitor == null) {
                prefix = "Blocked in handler";
            } else {
                prefix =  "Blocked in monitor " + mCurrentMonitor.getClass().getName();
            }
            long latencySeconds = (mClock.millis() - mStartTimeMillis) / 1000;
            return prefix + " on " + mName + " (" + getThread().getName() + ")"
                + " for " + latencySeconds + "s";
        }

        @Override
        public void run() {
            // Once we get here, we ensure that mMonitors does not change even if we call
            // #addMonitorLocked because we first add the new monitors to mMonitorQueue and
            // move them to mMonitors on the next schedule when mCompleted is true, at which
            // point we have completed execution of this method.
            final int size = mMonitors.size();
            for (int i = 0 ; i < size ; i++) {
                synchronized (mLock) {
                    mCurrentMonitor = mMonitors.get(i);
                }
                mCurrentMonitor.monitor();
            }

            synchronized (mLock) {
                mCompleted = true;
                mCurrentMonitor = null;
            }
        }

        /**
         * Pauses the checks for the given time.
         *
         * <p>The current run will be ignored and another run will be scheduled after
         * the given time.
         */
        public void pauseForLocked(int pauseMillis, String reason) {
            mPauseEndTimeMillis = mClock.millis() + pauseMillis;
            // Mark as completed, because there's a chance we called this after the watchog
            // thread loop called Object#wait after 'WAITED_UNTIL_PRE_WATCHDOG'. In that case we
            // want to ensure the next call to #getCompletionStateLocked for this checker returns
            // 'COMPLETED'
            mCompleted = true;
            Slog.i(TAG, "Pausing of HandlerChecker: " + mName + " for reason: "
                    + reason + ". Pause end time: " + mPauseEndTimeMillis);
        }

        /** Pause the HandlerChecker. */
        public void pauseLocked(String reason) {
            mPauseCount++;
            // Mark as completed, because there's a chance we called this after the watchog
            // thread loop called Object#wait after 'WAITED_UNTIL_PRE_WATCHDOG'. In that case we
            // want to ensure the next call to #getCompletionStateLocked for this checker returns
            // 'COMPLETED'
            mCompleted = true;
            Slog.i(TAG, "Pausing HandlerChecker: " + mName + " for reason: "
                    + reason + ". Pause count: " + mPauseCount);
        }

        /** Resume the HandlerChecker from the last {@link #pauseLocked}. */
        public void resumeLocked(String reason) {
            if (mPauseCount > 0) {
                mPauseCount--;
                Slog.i(TAG, "Resuming HandlerChecker: " + mName + " for reason: "
                        + reason + ". Pause count: " + mPauseCount);
            } else {
                Slog.wtf(TAG, "Already resumed HandlerChecker: " + mName);
            }
        }

        @Override
        public String toString() {
            return "CheckerHandler for " + mName;
        }
    }
