#!/bin/sh
set -eu

expected_axp717_model_sha256=b44940da920519986192f758eb4eb65eea5728179ebdd28393671be4c5557c5a
if [ "${1:-}" = --expected-axp717-model-sha256 ]; then
    expected_axp717_model_sha256="${2:?missing test fixture digest}"
    shift 2
fi
rootfs="${1:?usage: verify-rootfs-firmware.sh [--expected-axp717-model-sha256 SHA256] ROOTFS}"
[ "$#" -eq 1 ] || {
    echo 'FATAL: rootfs firmware: unexpected verifier arguments' >&2
    exit 2
}
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
for artifact in fw_xr829.bin boot_xr829.bin sdd_xr829.bin fw_xr829_bt.bin; do
    if ! require_rootfs_file "lib/firmware/${artifact}"; then
        echo "FATAL: rootfs firmware: /lib/firmware/${artifact} is missing" >&2
        exit 1
    fi
done

# The generated gauge model must be exactly the custody-pinned 128-byte
# extraction.  A non-empty or same-sized substitute is unsafe calibration.
if ! require_rootfs_file "lib/firmware/x-powers/axp717-tsp-battery-model.bin"; then
    echo 'FATAL: rootfs firmware: AXP717 battery model is missing' >&2
    exit 1
fi
axp717_model="$resolved_rootfs_file"
if [ "$(stat -c %s -- "$axp717_model")" -ne 128 ]; then
    echo 'FATAL: rootfs firmware: AXP717 battery model is not 128 bytes' >&2
    exit 1
fi
actual_axp717_model_sha256="$(sha256sum -- "$axp717_model" | cut -d ' ' -f 1)"
if [ "$actual_axp717_model_sha256" != "$expected_axp717_model_sha256" ]; then
    echo 'FATAL: rootfs firmware: AXP717 battery model SHA-256 mismatch' >&2
    exit 1
fi

echo 'rootfs-firmware=PASS regulatory.db=wireless-regdb_2026.02.04-1~deb12u1-upstream xr829=EMBEDDED:fw_xr829.bin,boot_xr829.bin,sdd_xr829.bin,fw_xr829_bt.bin axp717-model=PINNED:128'
