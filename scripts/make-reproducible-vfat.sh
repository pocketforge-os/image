#!/usr/bin/env bash
# =============================================================================
# make-reproducible-vfat.sh — create an empty, labelled FAT32 image whose bytes
# depend only on its arguments and SOURCE_DATE_EPOCH (bd tsp-mc9m.41.984.20.1).
#
#   SOURCE_DATE_EPOCH=<epoch> make-reproducible-vfat.sh <image> <size-MiB> <label> <volume-id>
#
# `mkfs.fat -n LABEL` leaves two per-run values in the volume:
#   - the volume serial (boot sector 0x43 and backup boot sector), random per run;
#   - the volume-label directory entry's timestamps, from the wall clock
#     (dosfstools 4.2 does not read SOURCE_DATE_EPOCH).
# Instead, `-i` sets the committed serial, and the label is written by mlabel.
# mtools stamps entries from SOURCE_DATE_EPOCH (as every later mcopy into the
# volume already does) and also writes the boot-sector label, so blkid reports
# LABEL and LABEL_FATBOOT exactly as `mkfs.fat -n` did. TZ=UTC pins the
# local-time conversion that FAT timestamps use.
#
# Test: tests/test-reproducible-assembly.sh.
# =============================================================================
set -euo pipefail

die() { echo "make-reproducible-vfat.sh: FATAL: $*" >&2; exit 1; }

[ "$#" -eq 4 ] || {
    echo "usage: SOURCE_DATE_EPOCH=<epoch> $0 <image> <size-MiB> <label> <volume-id>" >&2
    exit 2
}
IMAGE="$1"
SIZE_MIB="$2"
LABEL="$3"
VOLUME_ID="$4"

case "${SOURCE_DATE_EPOCH:-}" in
    ''|*[!0-9]*) die "reason=source_date_epoch_missing SOURCE_DATE_EPOCH must be a decimal epoch (got '${SOURCE_DATE_EPOCH:-}')" ;;
esac
case "${SIZE_MIB}" in
    ''|*[!0-9]*|0) die "reason=bad_size size must be a positive MiB count (got '${SIZE_MIB}')" ;;
esac
[[ "${VOLUME_ID}" =~ ^[0-9A-Fa-f]{8}$ ]] \
    || die "reason=bad_volume_id volume id must be 8 hex digits (got '${VOLUME_ID}')"
[[ "${LABEL}" =~ ^[A-Z0-9_-]{1,11}$ ]] \
    || die "reason=bad_label label must be 1-11 of A-Z 0-9 _ - (got '${LABEL}')"

rm -f "${IMAGE}"
dd if=/dev/zero of="${IMAGE}" bs=1M count="${SIZE_MIB}" status=none
mkdosfs -F 32 -i "${VOLUME_ID}" "${IMAGE}" >/dev/null
TZ=UTC SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" mlabel -i "${IMAGE}" "::${LABEL}"
