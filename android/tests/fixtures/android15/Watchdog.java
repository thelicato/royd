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

package com.android.server;

public class Watchdog implements Dumpable {
    static final String TAG = "Watchdog";

    /** Debug flag. */
    public static final boolean DEBUG = false;

    private void run() {
        boolean waitedHalf = false;

        while (true) {
            List<HandlerChecker> blockedCheckers = Collections.emptyList();
            String subject = "";
            boolean allowRestart = true;
            int debuggerWasConnected = 0;
            boolean doWaitedPreDump = false;
            // The value of mWatchdogTimeoutMillis might change while we are executing the loop.
            // We store the current value to use a consistent value for all handlers.
            final long watchdogTimeoutMillis = mWatchdogTimeoutMillis;
            final long checkIntervalMillis = watchdogTimeoutMillis / PRE_WATCHDOG_TIMEOUT_RATIO;
            final ArrayList<Integer> pids;
            synchronized (mLock) {
                long timeout = checkIntervalMillis;
                // Make sure we (re)spin the checkers that have become idle within
                // this wait-and-check interval
                for (int i=0; i<mHandlerCheckers.size(); i++) {
                    HandlerCheckerAndTimeout hc = mHandlerCheckers.get(i);
                    // We pick the watchdog to apply every time we reschedule the checkers. The
                    // default timeout might have changed since the last run.
                    hc.checker().scheduleCheckLocked(hc.customTimeoutMillis()
                            .orElse(watchdogTimeoutMillis * Build.HW_TIMEOUT_MULTIPLIER));
                }

                if (debuggerWasConnected > 0) {
                    debuggerWasConnected--;
                }

                // NOTE: We use uptimeMillis() here because we do not want to increment the time we
                // wait while asleep. If the device is asleep then the thing that we are waiting
                // to timeout on is asleep as well and won't have a chance to run, causing a false
                // positive on when to kill things.
                long start = SystemClock.uptimeMillis();
                while (timeout > 0) {
                    if (Debug.isDebuggerConnected()) {
                        debuggerWasConnected = 2;
                    }
                    try {
                        mLock.wait(timeout);
                        // Note: mHandlerCheckers and mMonitorChecker may have changed after waiting
                    } catch (InterruptedException e) {
                        Log.wtf(TAG, e);
                    }
                    if (Debug.isDebuggerConnected()) {
                        debuggerWasConnected = 2;
                    }
                    timeout = checkIntervalMillis - (SystemClock.uptimeMillis() - start);
                }

                final int waitState = evaluateCheckerCompletionLocked();
                if (waitState == COMPLETED) {
                    // The monitors have returned; reset
                    waitedHalf = false;
                    continue;
                } else if (waitState == WAITING) {
                    // still waiting but within their configured intervals; back off and recheck
                    continue;
                } else if (waitState == WAITED_UNTIL_PRE_WATCHDOG) {
                    if (!waitedHalf) {
                        Slog.i(TAG, "WAITED_UNTIL_PRE_WATCHDOG");
                        waitedHalf = true;
                        // We've waited until the pre-watchdog, but we'd need to do the stack trace
                        // dump w/o the lock.
                        blockedCheckers = getCheckersWithStateLocked(WAITED_UNTIL_PRE_WATCHDOG);
                        subject = describeCheckersLocked(blockedCheckers);
                        pids = new ArrayList<>(mInterestingJavaPids);
                        doWaitedPreDump = true;
                    } else {
                        continue;
                    }
                } else {
                    // something is overdue!
                    blockedCheckers = getCheckersWithStateLocked(OVERDUE);
                    subject = describeCheckersLocked(blockedCheckers);
                    allowRestart = mAllowRestart;
                    pids = new ArrayList<>(mInterestingJavaPids);
                }
            } // END synchronized (mLock)

            // If we got here, that means that the system is most likely hung.
            //
            // First collect stack traces from all threads of the system process.
            //
            // Then, if we reached the full timeout, kill this process so that the system will
            // restart. If we reached pre-watchdog timeout, just log some information and continue.
            logWatchog(doWaitedPreDump, subject, pids);

            if (doWaitedPreDump) {
                // We have waited for only pre-watchdog timeout, we continue to wait for the
                // duration of the full timeout before killing the process.
                continue;
            }

            IActivityController controller;
            synchronized (mLock) {
                controller = mController;
            }
            if (controller != null) {
                Slog.i(TAG, "Reporting stuck state to activity controller");
                try {
                    Binder.setDumpDisabled("Service dumps disabled due to hung system process.");
                    // 1 = keep waiting, -1 = kill system
                    int res = controller.systemNotResponding(subject);
                    if (res >= 0) {
                        Slog.i(TAG, "Activity controller requested to coninue to wait");
                        waitedHalf = false;
                        continue;
                    }
                } catch (RemoteException e) {
                }
            }

            // Only kill the process if the debugger is not attached.
            if (Debug.isDebuggerConnected()) {
                debuggerWasConnected = 2;
            }
            if (debuggerWasConnected >= 2) {
                Slog.w(TAG, "Debugger connected: Watchdog is *not* killing the system process");
            } else if (debuggerWasConnected > 0) {
                Slog.w(TAG, "Debugger was connected: Watchdog is *not* killing the system process");
            } else if (!allowRestart) {
                Slog.w(TAG, "Restart not allowed: Watchdog is *not* killing the system process");
            } else {
                Slog.w(TAG, "*** WATCHDOG KILLING SYSTEM PROCESS: " + subject);
                WatchdogDiagnostics.diagnoseCheckers(blockedCheckers);
                Slog.w(TAG, "*** GOODBYE!");
                if (!Build.IS_USER && isCrashLoopFound()
                        && !WatchdogProperties.should_ignore_fatal_count().orElse(false)) {
                    breakCrashLoop();
                }
                Process.killProcess(Process.myPid());
                System.exit(10);
            }

            waitedHalf = false;
        }
    }

    private void doSysRq(char c) {
        try {
            FileWriter sysrq_trigger = new FileWriter("/proc/sysrq-trigger");
            sysrq_trigger.write(c);
            sysrq_trigger.close();
        } catch (IOException e) {
            Slog.w(TAG, "Failed to write to /proc/sysrq-trigger", e);
        }
    }

    @Override
    public void dump(@NonNull PrintWriter pw, @Nullable String[] args) {
        pw.print("WatchdogTimeoutMillis=");
        pw.println(mWatchdogTimeoutMillis);
    }
}
