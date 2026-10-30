PRODUCT_VENDOR_PROPERTIES += \
    ro.config.low_ram=true \
    ro.lmk.use_psi=true \
    ro.lmk.use_minfree_levels=false \
    debug.renderengine.backend=skiaglthreaded

ifeq ($(PLATFORM_SDK_VERSION),35)
# Fail closed if the container's pre-init resource properties are not loaded.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += ro.adb.secure=1
else
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += ro.adb.secure=0
endif
