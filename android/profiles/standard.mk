# Standard royd image profile. Keep the inherited AOSP package set intact.
$(call inherit-product, vendor/royd/profile_policy.mk)

PRODUCT_VENDOR_PROPERTIES += ro.vendor.royd.image_profile=standard
