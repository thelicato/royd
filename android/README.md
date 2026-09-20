# Android runtime

This directory will contain the Android platform and image integration required to build royd.

The first implementation should start from a clearly documented upstream AOSP and ReDroid-compatible baseline, prove an unoptimised container boot, then introduce royd-specific Binder setup, logging, and low-memory changes incrementally.

Do not copy runtime debloating scripts into this directory as a substitute for a product-level Android configuration. Features that are intentionally omitted from an image profile should normally be removed or disabled through the Android build configuration where practical.
