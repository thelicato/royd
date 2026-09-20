# royd x86_64 product built only from AOSP plus files carried in this repository.
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_x86_64.mk)
$(call inherit-product, vendor/royd/royd.mk)

PRODUCT_NAME := royd_x86_64
PRODUCT_BRAND := royd
PRODUCT_MANUFACTURER := royd
PRODUCT_MODEL := royd Android x86_64
