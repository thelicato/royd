# Local AOSP patches

This directory is the only place for source patches that royd needs on top of a pinned AOSP tag.

Patches must be committed to this repository. The build must not download a patch repository or another Android device/vendor tree at synchronisation time.

Patch files are grouped by AOSP tag. `android/scripts/apply-patches.sh` applies `*.patch` files in lexical order when a matching directory exists. A version with no local patches does not need an empty directory.
