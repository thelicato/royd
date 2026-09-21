# Default portable graphics backend.
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.egl=swiftshader \
    ro.opengles.version=196610 \
    ro.vendor.royd.graphics_backend=software

ifeq ($(ROYD_GRAPHICS_ALLOCATOR),aidl2-stablec5-memfd)
PRODUCT_PACKAGES += \
    android.hardware.graphics.allocator-service.royd \
    mapper.royd
else
PRODUCT_VENDOR_PROPERTIES += ro.hardware.gralloc=royd
PRODUCT_PACKAGES += gralloc.royd
endif

ifeq ($(ROYD_GRAPHICS_COMPOSER),aidl3-client)
PRODUCT_PACKAGES += android.hardware.graphics.composer3-service.royd
else
PRODUCT_VENDOR_PROPERTIES += ro.hardware.hwcomposer=default
PRODUCT_PACKAGES += hwcomposer.default
endif

PRODUCT_PACKAGES += \
    libEGL_swiftshader \
    libGLESv1_CM_swiftshader \
    libGLESv2_swiftshader
