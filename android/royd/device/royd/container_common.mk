# Version-specific AOSP userspace composition is installed by install-royd.sh.
$(call inherit-product, device/royd/container_version.mk)

ifeq ($(PLATFORM_SDK_VERSION),35)
# This product does not include the EmergencyInfo gesture provider.
PRODUCT_PACKAGE_OVERLAYS += device/royd/overlay/android15
# Merge the page into Settings so its localised app-resource references work.
PRODUCT_ENFORCE_RRO_EXCLUDED_OVERLAYS += device/royd/overlay/android15
endif
