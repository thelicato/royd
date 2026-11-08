/**
 * Copyright (C) 2015 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy
 * of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations
 * under the License.
 */

// Exact nested classes; the contract supplies their outer class.
// Provenance: NetworkStatsUsageCallback.json.
    public static abstract class UsageCallback {
        /**
         * Called when data usage has reached the given threshold.
         *
         * Called by {@code NetworkStatsService} when the registered threshold is reached.
         * If a caller implements {@link #onThresholdReached(NetworkTemplate)}, the system
         * will not call {@link #onThresholdReached(int, String)}.
         *
         * @param template The {@link NetworkTemplate} that associated with this callback.
         * @hide
         */
        @SystemApi(client = MODULE_LIBRARIES)
        public void onThresholdReached(@NonNull NetworkTemplate template) {
            // Backward compatibility for those who didn't override this function.
            final int networkType = networkTypeForTemplate(template);
            if (networkType != ConnectivityManager.TYPE_NONE) {
                final String subscriberId = template.getSubscriberIds().isEmpty() ? null
                        : template.getSubscriberIds().iterator().next();
                onThresholdReached(networkType, subscriberId);
            }
        }

        /**
         * Called when data usage has reached the given threshold.
         */
        public abstract void onThresholdReached(int networkType, @Nullable String subscriberId);

        /**
         * @hide used for internal bookkeeping
         */
        private DataUsageRequest request;

        /**
         * Get network type from a template if feasible.
         *
         * @param template the target {@link NetworkTemplate}.
         * @return legacy network type, only supports for the types which is already supported in
         *         {@link #registerUsageCallback(int, String, long, UsageCallback, Handler)}.
         *         {@link ConnectivityManager#TYPE_NONE} for other types.
         */
        private static int networkTypeForTemplate(@NonNull NetworkTemplate template) {
            switch (template.getMatchRule()) {
                case NetworkTemplate.MATCH_MOBILE:
                    return ConnectivityManager.TYPE_MOBILE;
                case NetworkTemplate.MATCH_WIFI:
                    return ConnectivityManager.TYPE_WIFI;
                default:
                    return ConnectivityManager.TYPE_NONE;
            }
        }
    }

    private static class UsageCallbackWrapper extends IUsageCallback.Stub {
        // Null if unregistered.
        private volatile UsageCallback mCallback;

        private final Executor mExecutor;

        UsageCallbackWrapper(@NonNull Executor executor, @NonNull UsageCallback callback) {
            mCallback = callback;
            mExecutor = executor;
        }

        @Override
        public void onThresholdReached(DataUsageRequest request) {
            // Copy it to a local variable in case mCallback changed inside the if condition.
            final UsageCallback callback = mCallback;
            if (callback != null) {
                mExecutor.execute(() -> callback.onThresholdReached(request.template));
            } else {
                Log.e(TAG, "onThresholdReached with released callback for " + request);
            }
        }

        @Override
        public void onCallbackReleased(DataUsageRequest request) {
            if (DBG) Log.d(TAG, "callback released for " + request);
            mCallback = null;
        }
    }
