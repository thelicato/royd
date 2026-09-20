# HAL profiles

royd separates Android image profiles from hardware-surface profiles. Image profiles control package slimming. HAL profiles control the container-oriented hardware surface and default display behaviour.

## `graphical`

`graphical` is the default HAL profile. It keeps the software graphics stack required for an interactive Android display:

- `gralloc.royd`
- `hwcomposer.default`
- AOSP SwiftShader EGL and GLES libraries
- the version-matched AOSP graphics composer service selected by the Android version matrix

The imported OCI image defaults to a 540 x 960 display at 240 dpi and 30 fps. Runtime display arguments can still override those values.

## `headless`

`headless` is a server-oriented profile, not a graphics-free Android build. Android still requires SurfaceFlinger and a functioning allocator/composer path for normal framework boot, so the profile keeps the same minimal software graphics foundation.

The profile changes the product identity to `ro.vendor.royd.hal_profile=headless`, marks the display mode as headless, removes a conservative set of optional user-facing hardware applications where they are present, and imports with a 64 x 64 display at 72 dpi and 5 fps by default.

The current removal list includes optional camera, Bluetooth, NFC, wallpaper, music, and audio-effect applications. It does not yet claim that all underlying framework services or HAL interfaces for those features are absent. Clean builds and runtime service inspection are required before expanding the list.

## Building

The default graphical image uses the existing commands:

```sh
make android-build-x86_64
make android-package-x86_64
make runtime-import-x86_64
```

Build the headless-oriented profile with:

```sh
make android-build-headless-x86_64
make android-package-headless-x86_64
make runtime-import-headless-x86_64
make runtime-smoke-test-headless
```

The same selection can be applied to version-specific commands by setting `ROYD_HAL_PROFILE=headless`.

## Image identity

The HAL profile is part of the canonical OCI tag and `/royd-release` metadata. For example:

```text
royd:15.0.0-r36-standard-graphical-amd64
royd:15.0.0-r36-standard-headless-amd64
```

The default graphical aliases remain short, such as `royd:dev`. Non-default HAL profiles are explicit, such as `royd:dev-headless`.
