PRODUCT_VENDOR_PROPERTIES += \
    ro.config.low_ram=true \
    ro.lmk.use_psi=true \
    ro.lmk.use_minfree_levels=false \
    ro.hardware.egl=swiftshader \
    ro.opengles.version=196610 \
    debug.renderengine.backend=skiaglthreaded

PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.gralloc=royd \
    ro.hardware.hwcomposer=default

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += ro.adb.secure=0
