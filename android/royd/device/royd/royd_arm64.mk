# royd arm64 product built only from AOSP plus files carried in this repository.
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_arm64.mk)
$(call inherit-product, vendor/royd/royd.mk)

PRODUCT_NAME := royd_arm64
PRODUCT_BRAND := royd
PRODUCT_MANUFACTURER := royd
PRODUCT_MODEL := royd Android arm64
