PRODUCT_PACKAGES += \
    royd-binder-alloc \
    royd-memfd-probe \
    libEGL_swiftshader \
    libGLESv1_CM_swiftshader \
    libGLESv2_swiftshader

PRODUCT_COPY_FILES += \
    vendor/royd/init.royd.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.royd.rc \
    vendor/royd/bin/royd-binder-setup:$(TARGET_COPY_OUT_VENDOR)/bin/royd-binder-setup \
    vendor/royd/bin/royd-logcat:$(TARGET_COPY_OUT_VENDOR)/bin/royd-logcat \
    vendor/royd/bin/royd-display-setup:$(TARGET_COPY_OUT_VENDOR)/bin/royd-display-setup \
    vendor/royd/bin/royd-hardware-setup:$(TARGET_COPY_OUT_VENDOR)/bin/royd-hardware-setup

$(call inherit-product, vendor/royd/version.mk)

$(call inherit-product, vendor/royd/profile.mk)
