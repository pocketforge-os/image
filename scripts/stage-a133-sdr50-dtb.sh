#!/usr/bin/env bash
# Stage the A133 Odyssey SDR50 opt-in DTB on the owned-SPL FAT p4 boot-resource
# (tsp-mc9m.60.29.33.16).
#
# The owned U-Boot bootcmd loads ::/dtb.bin and nothing else, so this file is
# inert at boot: a kit swaps it in for the SD UHS proof (snapshot dtb.bin, copy
# dtb-sdr50.bin over it, reboot, restore). This helper fails closed:
#   - the built DTB must exist, be non-empty and carry the FDT magic;
#   - the U-Boot payload-layout checker must accept it at the generated fdt address;
#   - the destination must be a new file, never ::/dtb.bin, and must not exist yet;
#   - the FAT copy is read back and must equal the built DTB byte for byte;
#   - ::/dtb.bin must still equal the default DTB and differ from the SDR50 DTB.
#
# usage: stage-a133-sdr50-dtb.sh --fat <boot-resource.vfat> --dtb <sdr50.dtb>
#          --dest ::/<name> --default-dtb <dtb.bin> --layout-check <checker.py>
#          --uboot-config <config> --image <Image> --initrd <initrd.gz>
set -euo pipefail

die() { echo "stage-a133-sdr50-dtb.sh: FATAL: reason=$1${2:+ $2}" >&2; exit 1; }

FAT="" DTB="" DEST="" DEFAULT_DTB="" LAYOUT_CHECK="" UBOOT_CONFIG="" IMAGE="" INITRD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fat)          FAT="$2"; shift 2 ;;
        --dtb)          DTB="$2"; shift 2 ;;
        --dest)         DEST="$2"; shift 2 ;;
        --default-dtb)  DEFAULT_DTB="$2"; shift 2 ;;
        --layout-check) LAYOUT_CHECK="$2"; shift 2 ;;
        --uboot-config) UBOOT_CONFIG="$2"; shift 2 ;;
        --image)        IMAGE="$2"; shift 2 ;;
        --initrd)       INITRD="$2"; shift 2 ;;
        *) echo "stage-a133-sdr50-dtb.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done
for v in FAT DTB DEST DEFAULT_DTB LAYOUT_CHECK UBOOT_CONFIG IMAGE INITRD; do
    [ -n "${!v}" ] || { echo "stage-a133-sdr50-dtb.sh: missing required argument for ${v}" >&2; exit 2; }
done

[ -f "${DTB}" ] && [ -s "${DTB}" ] || die sdr50_dtb_missing "path=${DTB}"
magic="$(head -c4 "${DTB}" | od -An -tx1 | tr -d ' \n')"
[ "${magic}" = "d00dfeed" ] || die sdr50_dtb_not_fdt "path=${DTB} magic=${magic}"
[ -f "${FAT}" ] || die fat_image_missing "path=${FAT}"
[ -f "${DEFAULT_DTB}" ] || die default_dtb_missing "path=${DEFAULT_DTB}"
[ -f "${LAYOUT_CHECK}" ] || die layout_check_missing "path=${LAYOUT_CHECK}"
case "${DEST}" in
    ::/dtb.bin|::dtb.bin) die would_replace_default_dtb "dest=${DEST}" ;;
    ::/?*.bin) ;;
    *) die bad_dest "dest=${DEST}" ;;
esac
if cmp -s "${DTB}" "${DEFAULT_DTB}"; then
    die sdr50_dtb_equals_default "path=${DTB}"
fi
if mdir -b -i "${FAT}" "${DEST}" >/dev/null 2>&1; then
    die dest_exists "dest=${DEST}"
fi

# Same gate as the default dtb.bin: the opt-in DTB is swapped in at the same
# U-Boot fdt load address, so its extent must fit the generated layout too.
python3 "${LAYOUT_CHECK}" \
    --config "${UBOOT_CONFIG}" \
    --image "${IMAGE}" \
    --fdt "${DTB}" \
    --initrd "${INITRD}" || die sdr50_layout_check_failed "path=${DTB}"

mcopy -i "${FAT}" "${DTB}" "${DEST}" || die mcopy_failed "dest=${DEST}"

readback="$(mktemp)"
trap 'rm -f "${readback}"' EXIT
mcopy -n -o -i "${FAT}" "${DEST}" "${readback}" || die readback_failed "dest=${DEST}"
cmp -s "${DTB}" "${readback}" || die sdr50_readback_mismatch "dest=${DEST}"
mcopy -n -o -i "${FAT}" "::/dtb.bin" "${readback}" || die default_dtb_not_staged
cmp -s "${DEFAULT_DTB}" "${readback}" || die default_dtb_changed

echo "  boot-resource: SDR50 opt-in DTB staged at ${DEST} ($(stat -c%s "${DTB}") B, sha256 $(sha256sum "${DTB}" | cut -d' ' -f1)); ::/dtb.bin unchanged"
