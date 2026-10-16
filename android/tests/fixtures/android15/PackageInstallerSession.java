// Pinned markAsSealed FRP section, retained for executable and sync contracts.
            boolean isSecureFrpEnabled;
            if (android.security.Flags.frpEnforcement()) {
                PersistentDataBlockManager pdbManager =
                        mContext.getSystemService(PersistentDataBlockManager.class);
                if (pdbManager == null) {
                    // Some devices may not support FRP. In that case, we can't block the install
                    // accordingly.
                    isSecureFrpEnabled = false;
                } else {
                    isSecureFrpEnabled = pdbManager.isFactoryResetProtectionActive();
                }
            } else {
                isSecureFrpEnabled = Global.getInt(mContext.getContentResolver(),
                        Global.SECURE_FRP_MODE, 0) == 1;
            }

            if (isSecureFrpEnabled
                    && !isSecureFrpInstallAllowed(mContext, Binder.getCallingUid())) {
                throw new SecurityException("Can't install packages while in secure FRP");
            }
