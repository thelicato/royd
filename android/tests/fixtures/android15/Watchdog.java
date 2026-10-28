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

    private void fixturePreWatchdog() {
        while (true) {
                        blockedCheckers = getCheckersWithStateLocked(WAITED_UNTIL_PRE_WATCHDOG);
                        subject = describeCheckersLocked(blockedCheckers);
                        pids = new ArrayList<>(mInterestingJavaPids);
                        doWaitedPreDump = true;
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
