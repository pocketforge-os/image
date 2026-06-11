# PocketForge Image Builder

Builds the bootable SD card image for the TrimUI Smart Pro. Composes: Debian 12 bookworm arm64 rootfs (debootstrap) + PowerVR blob integration + `libSDL3-pocketforge.so.0` + Steam Link first-boot bootstrap + app install trees + SD-boot layout (vendor SPL/BL31/U-Boot at raw offsets, mkbootimg boot.img on named GPT partition).

Produces `pocketforge-tsp-YYYY.MM.img.xz` as a GitHub Release.

Populated in **Phase 1**. See the [pocketforge-os](https://github.com/pocketforge-os) org for the full repo set.
