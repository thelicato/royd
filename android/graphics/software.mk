# Default portable graphics backend.
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.egl=swiftshader \
    ro.hardware.hwcomposer=default \
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

PRODUCT_PACKAGES += \
    hwcomposer.default \
    libEGL_swiftshader \
    libGLESv1_CM_swiftshader \
    libGLESv2_swiftshader
