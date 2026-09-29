#!/usr/bin/env bash
# =============================================================================
# install-alsa-config.sh: install the ALSA configuration for the profile's kernel
# =============================================================================
# The codec card id depends on the KERNEL, not the GPU model (bd tsp-f3fm.220):
#   kernel-sunxi-4.9           vendor BSP sun50iw10 codec, card id "audiocodec".
#                              Installs the stock /etc/asound.conf, byte for byte.
#   kernel-sunxi-6.x|7.x       mainline sun4i-codec ("allwinner,sun50i-a133-codec"
#                              -> H616 card "H616 Audio Codec"), card id "Codec",
#                              playback only. Installs the sun4i-codec asound.conf
#                              and the boot-time speaker-path mixer defaults.
# Any other value, including an empty one, is a build error: a silent default
# is how the open-kernel images shipped a config naming a card they do not have.
#
# Usage: install-alsa-config.sh <kernel-repo> <rootfs> [<src-dir>]
#   <kernel-repo>  the profile's kernel.repo (PF_KERNEL_REPO from pf build)
#   <rootfs>       the rootfs being customized
#   <src-dir>      image repository root (default: /work/src)
# =============================================================================
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "usage: install-alsa-config.sh <kernel-repo> <rootfs> [<src-dir>]" >&2
    exit 2
fi

kernel_repo="$1"
rootfs="$2"
src="${3:-/work/src}"

[ -d "${rootfs}" ] || { echo "FATAL: rootfs is not a directory: ${rootfs}" >&2; exit 2; }

alsa_family() {
    case "$1" in
        kernel-sunxi-4.9) echo sunxi-vendor ;;
        kernel-sunxi-6.x|kernel-sunxi-7.x) echo sun4i-codec ;;
        '') echo "FATAL: PF_KERNEL_REPO is empty; cannot choose the ALSA card configuration" >&2; return 1 ;;
        *) echo "FATAL: no ALSA card configuration for kernel repo '$1' (known: kernel-sunxi-4.9, kernel-sunxi-6.x, kernel-sunxi-7.x)" >&2; return 1 ;;
    esac
}

family="$(alsa_family "${kernel_repo}")"

install -D -m 0644 "${src}/device-config/alsa/asound.conf.${family}" "${rootfs}/etc/asound.conf"

case "${family}" in
    sunxi-vendor)
        echo "[customize] ALSA: stock /etc/asound.conf (card audiocodec) for ${kernel_repo}"
        ;;
    sun4i-codec)
        install -D -m 0644 "${src}/device-config/alsa/mixer-defaults.sun4i-codec" \
            "${rootfs}/usr/share/pocketforge/alsa/mixer-defaults.sun4i-codec"
        install -D -m 0755 "${src}/rootfs-overlay/usr/lib/pocketforge/audio-defaults.sh" \
            "${rootfs}/usr/lib/pocketforge/audio-defaults.sh"
        install -D -m 0644 "${src}/rootfs-overlay/etc/systemd/system/pocketforge-audio-defaults.service" \
            "${rootfs}/etc/systemd/system/pocketforge-audio-defaults.service"
        install -d "${rootfs}/etc/systemd/system/sound.target.wants"
        ln -sfn /etc/systemd/system/pocketforge-audio-defaults.service \
            "${rootfs}/etc/systemd/system/sound.target.wants/pocketforge-audio-defaults.service"
        echo "[customize] ALSA: sun4i-codec /etc/asound.conf (card Codec) + speaker mixer defaults for ${kernel_repo}"
        ;;
esac
