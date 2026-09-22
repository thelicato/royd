# Experimental host GPU backend for generic DRM render nodes.
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.egl=mesa \
    ro.hardware.gralloc=minigbm \
    ro.opengles.version=196608 \
    ro.vendor.royd.graphics_backend=host-gpu-generic

PRODUCT_PACKAGES += \
    gralloc.minigbm \
    libGLES_mesa

ifeq ($(ROYD_GRAPHICS_COMPOSER),aidl4-client)
PRODUCT_PACKAGES += android.hardware.graphics.composer3-service.royd
else
PRODUCT_VENDOR_PROPERTIES += ro.hardware.hwcomposer=default
PRODUCT_PACKAGES += hwcomposer.default
endif
