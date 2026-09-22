#!/bin/sh
set -eu

rootfs="${1:?usage: verify-rootfs-firmware.sh ROOTFS}"
rootfs="$(realpath -m -- "$rootfs")"

require_rootfs_file() {
    path="$1"
    candidate="${rootfs}/${path}"
    depth=0

    while [ -L "$candidate" ]; do
        depth=$((depth + 1))
        if [ "$depth" -gt 40 ]; then
            return 1
        fi

        target="$(readlink -- "$candidate")"
        case "$target" in
            /*) candidate="${rootfs}${target}" ;;
            *) candidate="$(dirname -- "$candidate")/${target}" ;;
        esac
        candidate="$(realpath -ms -- "$candidate")"
        case "$candidate" in
            "$rootfs"/*) ;;
            *) return 1 ;;
        esac
    done

    [ -f "$candidate" ] && [ -s "$candidate" ]
}

for path in \
    lib/firmware/regulatory.db \
    lib/firmware/regulatory.db.p7s; do
    # Follow Debian's absolute update-alternatives links inside the extracted
    # rootfs, with a bounded chain, and require non-empty final artifacts.
    if ! require_rootfs_file "$path"; then
        echo "FATAL: rootfs firmware: /${path} is missing (wireless-regdb 2026.02.04-1~deb12u1)" >&2
        exit 1
    fi
done

# vendor-manifest@3c8c5c53 classifies the preserved XR829 firmware group as
# "Proprietary (Allwinner/Xradio XR829 WiFi/BT firmware; non-redistributable)".
# Keep the BT blob in vendor custody; unlike the three Wi-Fi files already used
# by this image, it must not enter the distributable rootfs without new license
# evidence and a redistributable vendor-manifest group.
if [ -e "${rootfs}/lib/firmware/fw_xr829_bt.bin" ] || \
   [ -L "${rootfs}/lib/firmware/fw_xr829_bt.bin" ]; then
    echo "FATAL: rootfs firmware: non-redistributable /lib/firmware/fw_xr829_bt.bin was shipped" >&2
    exit 1
fi

echo 'rootfs-firmware=PASS regulatory.db=wireless-regdb_2026.02.04-1~deb12u1 xr829_bt=NOT-SHIPPED'
