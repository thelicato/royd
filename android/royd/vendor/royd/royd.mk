PRODUCT_COPY_FILES += \
    vendor/royd/init.royd.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.royd.rc \
    vendor/royd/bin/royd-binder-setup:$(TARGET_COPY_OUT_VENDOR)/bin/royd-binder-setup \
    vendor/royd/bin/royd-logcat:$(TARGET_COPY_OUT_VENDOR)/bin/royd-logcat

# Start from Android's supported low-RAM behaviour. More aggressive tuning must be
# justified by repeatable measurements before it is added here.
PRODUCT_VENDOR_PROPERTIES += \
    ro.config.low_ram=true \
    ro.lmk.use_psi=true \
    ro.lmk.use_minfree_levels=false
