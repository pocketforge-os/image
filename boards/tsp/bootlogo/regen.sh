#!/usr/bin/env bash
# regen.sh — regenerate bootlogo.bmp.lzma from pocketforge-boot.png.
#
# The A133 boot splash is drawn by the vendor u-boot 2018.05 blob's
# sunxi_bmp_show(), which looks up an item named "bootlogo" inside
# boot_package.fex (packed by dragonsecboot -pack from boot_package.cfg).
# The payload MUST be an uncompressed 24-bit BI_RGB BMP at the framebuffer
# geometry (1280x720 landscape per boards/tsp/DTS-NOTES.md — the DE2.0
# rotates it to the 720x1280 OTM1289A portrait panel), lzma-compressed.
#
# Run this whenever pocketforge-boot.png changes. Commit both the .png
# (source of truth) and the produced .bmp.lzma (build input) together.
# The build (image/scripts/build-sd-image.sh) consumes bootlogo.bmp.lzma
# directly; it does NOT convert at build time (keeps the pf/build
# container free of imagemagick + honours the reproducible-build epoch).
#
# Deps on the host running this: python3 + Pillow (>=9.0), xz-utils.
# bd: tsp-myp1.5

set -euo pipefail
cd "$(dirname "$0")"

SRC=pocketforge-boot.png
OUT=bootlogo.bmp.lzma
TMP_BMP="$(mktemp -t bootlogo.XXXXXX.bmp)"
trap 'rm -f "$TMP_BMP"' EXIT

# 1) PNG -> 24bpp BI_RGB BMP at native FB geometry (1280x720).
python3 - "$SRC" "$TMP_BMP" <<'PY'
import sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
im = Image.open(src)
# Flatten alpha onto black (the panel behind the splash is unlit) so we
# never emit a 32bpp BMP -- vendor sunxi_bmp_show accepts 24-bit BI_RGB.
if im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info):
    bg = Image.new("RGB", im.size, (0, 0, 0))
    im = im.convert("RGBA")
    bg.paste(im, mask=im.split()[3])
    im = bg
else:
    im = im.convert("RGB")
if im.size != (1280, 720):
    im = im.resize((1280, 720), Image.LANCZOS)
im.save(dst, format="BMP")
PY

# 2) BMP -> .lzma (single-file legacy LZMA, matches vendor bootlogo convention).
#    -k keep source, -f overwrite, -6 default level (deterministic).
lzma -k -f -6 --stdout "$TMP_BMP" > "$OUT"

# 3) Emit provenance line for the reader.
png_sha="$(sha256sum "$SRC" | cut -d' ' -f1)"
bmp_sha="$(sha256sum "$TMP_BMP" | cut -d' ' -f1)"
out_sha="$(sha256sum "$OUT" | cut -d' ' -f1)"
{
    echo "# bootlogo provenance (regen.sh output)"
    echo "source_png:      $SRC sha256=$png_sha"
    echo "intermediate_bmp: 1280x720 24bpp BI_RGB sha256=$bmp_sha"
    echo "output_lzma:     $OUT sha256=$out_sha"
    echo "commit both $SRC and $OUT together."
} > PROVENANCE.txt
cat PROVENANCE.txt
