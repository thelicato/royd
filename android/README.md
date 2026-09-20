# Android source integration

royd builds its Android userspace from pinned AOSP releases and installs repository-owned product and vendor projects into each synced tree.

Pinned versions live under [`versions/`](versions/). The matrix spans Android 8.1 through 17, with Android 15 as the default baseline. Version-family build and product differences live under [`compat/`](compat/). See [`../docs/android-versions.md`](../docs/android-versions.md) for the support matrix.

The build workflow is documented in [`../docs/building.md`](../docs/building.md).
