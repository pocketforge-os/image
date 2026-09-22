#!/bin/sh
set -eu

rootfs="${1:?usage: verify-rootfs-firmware.sh ROOTFS}"
rootfs="$(realpath -m -- "$rootfs")"

require_rootfs_file() {
    rootfs_relative_path="$1"
    candidate="${rootfs}/${rootfs_relative_path}"
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

    [ -f "$candidate" ] && [ -s "$candidate" ] || return 1
    resolved_rootfs_file="$candidate"
}

# Verify lib/firmware/regulatory.db and its .p7s against the package's
# kernel.org-signed payload rather than merely accepting any alternatives target.
for artifact in regulatory.db regulatory.db.p7s; do
    # Follow Debian's absolute update-alternatives links inside the extracted
    # rootfs, with a bounded chain, and require non-empty final artifacts.
    if ! require_rootfs_file "lib/firmware/${artifact}"; then
        echo "FATAL: rootfs firmware: /lib/firmware/${artifact} is missing (wireless-regdb 2026.02.04-1~deb12u1)" >&2
        exit 1
    fi
    selected="$resolved_rootfs_file"

    if ! require_rootfs_file "lib/firmware/${artifact}-upstream"; then
        echo "FATAL: rootfs firmware: packaged upstream /lib/firmware/${artifact}-upstream is missing" >&2
        exit 1
    fi

    if ! cmp -s -- "$selected" "$resolved_rootfs_file"; then
        echo "FATAL: rootfs firmware: /lib/firmware/${artifact} does not select the upstream-signed variant" >&2
        exit 1
    fi
done

# Owner decision 2026-09-22 (tsp-mc9m.41.926.145.50.6.6.13.2): this image
# embeds vendor firmware from the preserved XR829 group. vendor-manifest's
# redistributable flag governs public byte custody in that repository and its
# gateway; image embedding is a separate policy question.
if ! require_rootfs_file "lib/firmware/fw_xr829_bt.bin"; then
    echo "FATAL: rootfs firmware: /lib/firmware/fw_xr829_bt.bin is missing" >&2
    exit 1
fi

echo 'rootfs-firmware=PASS regulatory.db=wireless-regdb_2026.02.04-1~deb12u1-upstream xr829_bt=EMBEDDED'
