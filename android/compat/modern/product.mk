$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/handheld_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_product.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/base_vendor.mk)

PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS := relaxed
PRODUCT_USE_DYNAMIC_PARTITION_SIZE := true
# royd uses the host kernel and does not package a guest kernel or boot image.
PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false
# royd runs Android with kernel SELinux disabled. Compressed APEX extraction
# requires SELinux file-labelling operations, so use ordinary APEX packages.
PRODUCT_COMPRESSED_APEX := false
