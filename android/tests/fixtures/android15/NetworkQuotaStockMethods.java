/*
 * Copyright (C) 2007 The Android Open Source Project
 * Copyright (C) 2011 The Android Open Source Project
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
// Pinned source excerpts for compilation inside the contract harness.
// NetworkManagementService.java

public void removeInterfaceQuota(String iface) {
        PermissionUtils.enforceNetworkStackPermission(mContext);

        synchronized (mQuotaLock) {
            if (!mActiveQuotas.containsKey(iface)) {
                // TODO: eventually consider throwing
                return;
            }

            mActiveQuotas.remove(iface);
            mActiveAlerts.remove(iface);

            try {
                // TODO: support quota shared across interfaces
                mNetdService.bandwidthRemoveInterfaceQuota(iface);
            } catch (RemoteException | ServiceSpecificException e) {
                throw new IllegalStateException(e);
            }
        }
    }

// NetworkPolicyManagerService.java

private void setInterfaceLimit(String iface, long limitBytes) {
        try {
            // For legacy design the data warning is covered by global alert, where the
            // kernel will notify upper layer for a small amount of change of traffic
            // statistics. Thus, passing warning is not needed.
            mNetworkManager.setInterfaceQuota(iface, limitBytes);
        } catch (IllegalStateException e) {
            Log.wtf(TAG, "problem setting interface quota", e);
        } catch (RemoteException e) {
            // ignored; service lives in system_server
        }
    }

private void removeInterfaceLimit(String iface) {
        try {
            mNetworkManager.removeInterfaceQuota(iface);
        } catch (IllegalStateException e) {
            Log.wtf(TAG, "problem removing interface quota", e);
        } catch (RemoteException e) {
            // ignored; service lives in system_server
        }
    }
