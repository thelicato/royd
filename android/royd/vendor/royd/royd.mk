PRODUCT_PACKAGES += \
    royd-binder-alloc

PRODUCT_COPY_FILES += \
    vendor/royd/init.royd.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.royd.rc \
    vendor/royd/bin/royd-binder-setup:$(TARGET_COPY_OUT_VENDOR)/bin/royd-binder-setup \
    vendor/royd/bin/royd-logcat:$(TARGET_COPY_OUT_VENDOR)/bin/royd-logcat \
    vendor/royd/bin/royd-display-setup:$(TARGET_COPY_OUT_VENDOR)/bin/royd-display-setup

PRODUCT_VENDOR_PROPERTIES += \
    ro.config.low_ram=true \
    ro.lmk.use_psi=true \
    ro.lmk.use_minfree_levels=false

$(call inherit-product, vendor/royd/profile.mk)
