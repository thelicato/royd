# royd arm64 product built from AOSP userspace plus repository-owned container integration.
$(call inherit-product, device/royd/container_common.mk)
$(call inherit-product, vendor/royd/royd.mk)

PRODUCT_NAME := royd_arm64
PRODUCT_DEVICE := royd_arm64
PRODUCT_BRAND := royd
PRODUCT_MANUFACTURER := royd
PRODUCT_MODEL := royd Android arm64
