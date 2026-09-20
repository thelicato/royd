# Common Android userspace composition for royd containers.
# Keep this free of emulator-only product and vendor inheritance.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/handheld_system_ext.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_product.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/base_vendor.mk)

PRODUCT_ENFORCE_ARTIFACT_PATH_REQUIREMENTS := relaxed

# Container images do not have fixed flash partition capacities. Let the Android
# build size filesystem images from their contents instead of a virtual disk map.
PRODUCT_USE_DYNAMIC_PARTITION_SIZE := true
