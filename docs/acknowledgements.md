# Acknowledgements

royd is an independent project built from AOSP and code maintained in this repository.

The project was inspired in part by [ReDroid](https://github.com/remote-android/redroid-doc), which demonstrated that Android userspace can be operated as a Linux container sharing the host kernel rather than requiring a VM. ReDroid is prior art and architectural inspiration for royd, but royd does not fetch, build against, patch from, or require ReDroid repositories.

The low-memory direction was also influenced by [avdslim](https://github.com/kdbhalala/avdslim), particularly its Android-side focus on reducing unnecessary services and memory pressure. royd does not use its QEMU-specific techniques.
