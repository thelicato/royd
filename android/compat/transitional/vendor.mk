PRODUCT_VENDOR_PROPERTIES += \
    ro.config.low_ram=true \
    ro.hardware.egl=swiftshader \
    ro.opengles.version=196610 \
    debug.renderengine.backend=skiaglthreaded

PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.gralloc=royd \
    ro.hardware.hwcomposer=default

PRODUCT_DEFAULT_PROPERTY_OVERRIDES += ro.adb.secure=0
