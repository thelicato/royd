# Headless-oriented server profile. Android still needs a working software display
# stack for SurfaceFlinger, so this profile keeps the minimal royd graphics path.
PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.royd.hal_profile=headless \
    ro.vendor.royd.display_mode=headless

PRODUCT_PACKAGES += \
    gralloc.royd \
    hwcomposer.default \
    libEGL_swiftshader \
    libGLESv1_CM_swiftshader \
    libGLESv2_swiftshader

# Remove optional user-facing hardware applications where present. Missing names
# are harmless because filter-out only affects packages already selected upstream.
PRODUCT_PACKAGES := $(filter-out \
    AudioFX \
    Bluetooth \
    Camera2 \
    LiveWallpapers \
    LiveWallpapersPicker \
    Music \
    NfcNci \
    Tag \
    TestCamera2 \
    WallpaperPicker2, \
    $(PRODUCT_PACKAGES))
