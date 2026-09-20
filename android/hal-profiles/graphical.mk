# Interactive software-rendered hardware profile.
PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.royd.hal_profile=graphical \
    ro.vendor.royd.display_mode=interactive

PRODUCT_PACKAGES += \
    gralloc.royd \
    hwcomposer.default \
    libEGL_swiftshader \
    libGLESv1_CM_swiftshader \
    libGLESv2_swiftshader
