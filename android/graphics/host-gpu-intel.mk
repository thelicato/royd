# Experimental host GPU backend for Intel i915/xe render nodes on x86_64.
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.egl=mesa \
    ro.hardware.gralloc=minigbm_intel \
    ro.hardware.hwcomposer=default \
    ro.opengles.version=196608 \
    ro.vendor.royd.graphics_backend=host-gpu-intel

PRODUCT_PACKAGES += \
    gralloc.minigbm_intel \
    hwcomposer.default \
    libGLES_mesa
