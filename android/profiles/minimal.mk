# Minimal royd image profile.
# Keep core Android UI, package management, storage and ADB functionality, while
# removing optional components that are not required for container automation.
ROYD_MINIMAL_PACKAGES := \
    BasicDreams \
    EasterEgg \
    PrintRecommendationService \
    PrintSpooler

PRODUCT_PACKAGES := $(filter-out $(ROYD_MINIMAL_PACKAGES),$(PRODUCT_PACKAGES))
PRODUCT_PACKAGES_DEBUG := $(filter-out $(ROYD_MINIMAL_PACKAGES),$(PRODUCT_PACKAGES_DEBUG))
PRODUCT_VENDOR_PROPERTIES += ro.vendor.royd.image_profile=minimal
