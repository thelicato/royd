/*
 * Copyright (C) 2024 The Android Open Source Project
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

// Pinned Android 15 ProcessList freezer-method fixture, not a build input.
class ProcessList {
    private void freezeBinderAndPackageCgroup(List<Pair<ProcessRecord, Boolean>> procs,
                                                     int packageUID) {
        // Freeze all binder processes under the target UID (whose cgroup is about to be frozen).
        // Since we're going to kill these, we don't need to unfreze them later.
        // The procs list may not include all processes under the UID cgroup, but unincluded
        // processes (forks) should not be Binder users.
        int N = procs.size();
        for (int i = 0; i < N; i++) {
            final int pid = procs.get(i).first.getPid();
            int nRetries = 0;
            if (pid > 0) {
                try {
                    int rc;
                    do {
                        rc = mService.getFreezer().freezeBinder(pid, true, 10 /* timeout_ms */);
                    } while (rc == -EAGAIN && nRetries++ < 1);
                    if (rc != 0) Slog.e(TAG, "Unable to freeze binder for " + pid + ": " + rc);
                } catch (RuntimeException e) {
                    Slog.e(TAG, "Unable to freeze binder for " + pid + ": " + e);
                }
            }
        }

        // We freeze the entire UID (parent) cgroup so that newly-specialized processes also freeze
        // despite being added to a child cgroup created after this call that would otherwise be
        // unfrozen.
        freezePackageCgroup(packageUID, true);
    }

}
