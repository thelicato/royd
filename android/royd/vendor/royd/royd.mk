PRODUCT_PACKAGES += \
    royd-binder-alloc \
    royd-binder-info \
    royd-memfd-probe \
    royd-display-bootstrap

PRODUCT_COPY_FILES += \
    vendor/royd/init.royd.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.royd.rc \
    vendor/royd/bin/royd-binder-setup:$(TARGET_COPY_OUT_VENDOR)/bin/royd-binder-setup \
    vendor/royd/bin/royd-logcat:$(TARGET_COPY_OUT_VENDOR)/bin/royd-logcat \
    vendor/royd/bin/royd-hardware-setup:$(TARGET_COPY_OUT_VENDOR)/bin/royd-hardware-setup \
    vendor/royd/bin/royd-graphics-setup:$(TARGET_COPY_OUT_VENDOR)/bin/royd-graphics-setup \
    vendor/royd/bin/royd-health:$(TARGET_COPY_OUT_VENDOR)/bin/royd-health \
    vendor/royd/profile-packages.txt:$(TARGET_COPY_OUT_VENDOR)/etc/royd-profile-packages.txt

$(call inherit-product, vendor/royd/version.mk)

$(call inherit-product, vendor/royd/profile.mk)

$(call inherit-product, vendor/royd/hal_profile.mk)

$(call inherit-product, vendor/royd/graphics_backend.mk)
