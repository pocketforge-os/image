#!/usr/bin/env bash
# finalize-elf-debuginfo.sh — the cr-symbols step the image builders run on the
# assembled rootfs tree (bd tsp-ihne1.33): gate, split, manifest, publish.
#
#   usage: finalize-elf-debuginfo.sh ROOTFS OUT_DIR
#
#   1. Gate   — fail the build unless every ELF in ROOTFS outside the closed
#      vendor dirs carries a GNU build-id (pf-elf-buildid.py check). Closed
#      vendored binaries (PowerVR/Mali userland) are exempt and NEVER nameable.
#   2. Split  — split DWARF-carrying ELFs: the debuginfo lands in the
#      debuginfod-compatible store under OUT_DIR/pf-debuginfo/buildid/aa/rest/
#      debuginfo; the shipped binaries keep their build-id and lose DWARF.
#   3. Manifest — emit the image build-id manifest to OUT_DIR and install the
#      on-device copy (+sha256) at /usr/share/pocketforge/elf-build-id-manifest.tsv
#      so the on-device collector can decide which modules it may name.
#
# The store/manifest in OUT_DIR ride the export stage of `pf build` (the v1
# symbol store is private to cr-server; hosting is wired by tsp-ihne1.34).
# Binutils: PF_OBJCOPY / PF_STRIP (env) or /opt/arm-10.3-2021.07/bin cross
# tools, else `objcopy`/`strip` from PATH.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "usage: finalize-elf-debuginfo.sh ROOTFS OUT_DIR [--closed-paths DIR ...]" >&2
    exit 2
}

[ "$#" -ge 2 ] || usage
ROOTFS="$1"
OUT_DIR="$2"
shift 2
[ "${1:-}" != "--closed-paths" ] || shift
CLOSED_PATHS=("$@")
if [ "${#CLOSED_PATHS[@]}" -eq 0 ]; then
    # Default closed-vendor roots: PowerVR rogue UM (a133), closed libmali
    # (a523), and unmodified redistributable PowerVR firmware staged from the
    # vendor-manifest/CAR input. Firmware is not an owned link product even
    # when its opaque payload happens to begin with the ELF magic bytes.
    CLOSED_PATHS=(
        "${ROOTFS}/usr/lib/pvr-rogue"
        "${ROOTFS}/usr/lib/mali"
        "${ROOTFS}/usr/lib/firmware/powervr"
    )
fi

[ -d "$ROOTFS" ] || { echo "finalize: ROOTFS $ROOTFS is not a directory" >&2; exit 2; }
mkdir -p "$OUT_DIR"

PY="$SCRIPT_DIR/pf-elf-buildid.py"
[ -f "$PY" ] || { echo "finalize: $PY missing" >&2; exit 2; }

echo "[elf-buildid] gate: every ELF outside closed vendor dirs must carry a GNU build-id"
python3 "$PY" check "$ROOTFS" --closed-paths "${CLOSED_PATHS[@]}"

STORE="$OUT_DIR/pf-debuginfo"
echo "[elf-buildid] split: DWARF-carrying ELFs -> $STORE (debuginfod layout)"
python3 "$PY" split "$ROOTFS" "$STORE" --closed-paths "${CLOSED_PATHS[@]}"

echo "[elf-buildid] manifest: image build-id manifest"
python3 "$PY" manifest "$ROOTFS" --closed-paths "${CLOSED_PATHS[@]}" \
    > "$OUT_DIR/pf-elf-build-id-manifest.tsv"

install -d "$ROOTFS/usr/share/pocketforge"
install -m 0644 "$OUT_DIR/pf-elf-build-id-manifest.tsv" \
    "$ROOTFS/usr/share/pocketforge/elf-build-id-manifest.tsv"
( cd "$ROOTFS/usr/share/pocketforge" && sha256sum elf-build-id-manifest.tsv \
    > elf-build-id-manifest.tsv.sha256 )

echo "[elf-buildid] finalize complete: gate passed, store=$STORE, manifest installed"
