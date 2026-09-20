# Default portable graphics backend.
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.egl=swiftshader \
    ro.hardware.gralloc=royd \
    ro.hardware.hwcomposer=default \
    ro.opengles.version=196610 \
    ro.vendor.royd.graphics_backend=software

PRODUCT_PACKAGES += \
    gralloc.royd \
    hwcomposer.default \
    libEGL_swiftshader \
    libGLESv1_CM_swiftshader \
    libGLESv2_swiftshader
