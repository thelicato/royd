# Experimental host GPU backend for generic DRM render nodes.
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.egl=mesa \
    ro.hardware.gralloc=minigbm \
    ro.hardware.hwcomposer=default \
    ro.opengles.version=196608 \
    ro.vendor.royd.graphics_backend=host-gpu-generic

PRODUCT_PACKAGES += \
    gralloc.minigbm \
    hwcomposer.default \
    libGLES_mesa
