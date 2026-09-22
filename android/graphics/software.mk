# Default portable graphics backend.
PRODUCT_VENDOR_PROPERTIES += \
    ro.opengles.version=196610 \
    ro.vendor.royd.graphics_backend=software

# Android 15 moved GLES-over-software to ANGLE backed by SwiftShader's Vulkan
# implementation. angle_default.mk selects ANGLE, while vulkan.pastel provides
# the CPU Vulkan backend. Other pinned releases keep the existing SwiftShader
# GLES contract until their software graphics path is validated.
ifeq ($(ROYD_SOFTWARE_EGL),angle)
$(call inherit-product, $(SRC_TARGET_DIR)/product/angle_default.mk)
PRODUCT_VENDOR_PROPERTIES += ro.hardware.vulkan=pastel
PRODUCT_PACKAGES += vulkan.pastel
else
PRODUCT_VENDOR_PROPERTIES += ro.hardware.egl=swiftshader
PRODUCT_PACKAGES += \
    libEGL_swiftshader \
    libGLESv1_CM_swiftshader \
    libGLESv2_swiftshader
endif

ifeq ($(ROYD_GRAPHICS_ALLOCATOR),aidl2-stablec5-memfd)
PRODUCT_PACKAGES += \
    android.hardware.graphics.allocator-service.royd \
    mapper.royd
else
PRODUCT_VENDOR_PROPERTIES += ro.hardware.gralloc=royd
PRODUCT_PACKAGES += gralloc.royd
endif

ifeq ($(ROYD_GRAPHICS_COMPOSER),aidl4-client)
PRODUCT_PACKAGES += android.hardware.graphics.composer3-service.royd
else
PRODUCT_VENDOR_PROPERTIES += ro.hardware.hwcomposer=default
PRODUCT_PACKAGES += hwcomposer.default
endif
