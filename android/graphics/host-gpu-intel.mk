# Experimental host GPU backend for Intel i915/xe render nodes on x86_64.
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.egl=mesa \
    ro.hardware.gralloc=minigbm_intel \
    ro.opengles.version=196608 \
    ro.vendor.royd.graphics_backend=host-gpu-intel

PRODUCT_PACKAGES += \
    gralloc.minigbm_intel \
    libGLES_mesa

ifeq ($(ROYD_GRAPHICS_COMPOSER),aidl3-client)
PRODUCT_PACKAGES += android.hardware.graphics.composer3-service.royd
else
PRODUCT_VENDOR_PROPERTIES += ro.hardware.hwcomposer=default
PRODUCT_PACKAGES += hwcomposer.default
endif
