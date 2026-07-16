#!/usr/bin/env bash
# =============================================================================
# build-sd-image.sh — Compose the PocketForge SD image (TrimUI Smart Pro)
# =============================================================================
# Orchestrates the full SD image build pipeline:
#   1. Build the initrd (delegates to build-initrd.sh)
#   2. Compile the DTB from tracked .dts
#   3. Pack boot_package.fex via dragonsecboot -pack
#   4. Create boot.img via abootimg (kernel + initrd + cmdline)
#   5. Compose the SD image via genimage (partition layout)
#   6. Compress with xz + compute SHA-256
#
# Runs INSIDE the pocketforge/build container. Inputs via bind mounts:
#   /work/src     (ro) - this image repo
#   /work/blobs   (ro) - blobs repo checkout
#   /work/libsdl3 (ro) - libSDL3-pocketforge.so.0 release artifact
#   /work/out     (rw) - build output
#
# Usage:
#   build-sd-image.sh [--m1b-mode] [--variant dev|release]
#
# bd: tsp-iuz.1.7
# =============================================================================
set -euo pipefail

# ---- configuration ----------------------------------------------------------
BOARD="tsp"
SRC_DIR="${SRC_DIR:-/work/src}"
BLOBS_DIR="${BLOBS_DIR:-/work/blobs}"
OUT_DIR="${OUT_DIR:-/work/out}"
BOARD_DIR="${SRC_DIR}/boards/${BOARD}"
TOOLS_DIR="${SRC_DIR}/tools"

# Parse arguments
M1B_MODE=0
BOOT_ONLY=0
VARIANT="dev"
SUBSTRATE="owned"
# Boot chain (tsp-147u.13): "vendor" (default) = vendor boot0 in the 0x20000 slot + Android
# boot.img loaded by vendor u-boot (the SHIPPED a133 path, unchanged). "owned-spl" = the owned
# mainline u-boot-sunxi-with-spl.bin (from the bootchain stage) in the 0x20000 slot, replacing
# vendor boot0, and Image/dtb.bin/initrd.gz staged on the FAT p4 boot-resource for the owned
# u-boot's `booti` from mmc 0:4. Same GPT layout either way (boot-resource stays p4).
BOOT_CHAIN="vendor"
UBOOT_SPL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --m1b-mode)    M1B_MODE=1; shift ;;
        --boot-only)   BOOT_ONLY=1; shift ;;
        --variant)     VARIANT="$2"; shift 2 ;;
        --substrate)   SUBSTRATE="$2"; shift 2 ;;
        --boot-chain)  BOOT_CHAIN="$2"; shift 2 ;;
        --uboot-spl)   UBOOT_SPL="$2"; shift 2 ;;
        *) echo "build-sd-image.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done
case "${BOOT_CHAIN}" in
    vendor|owned-spl) ;;
    *) echo "build-sd-image.sh: --boot-chain must be vendor|owned-spl (got '${BOOT_CHAIN}')" >&2; exit 2 ;;
esac
if [ "${BOOT_CHAIN}" = "owned-spl" ]; then
    [ -n "${UBOOT_SPL}" ] && [ -f "${UBOOT_SPL}" ] || {
        echo "FATAL: --boot-chain owned-spl requires --uboot-spl <u-boot-sunxi-with-spl.bin> (got '${UBOOT_SPL}')" >&2
        exit 1; }
fi

# Owned-substrate paths (bind-mounted by the build container)
KERNEL_TSP_DIR="${KERNEL_TSP_DIR:-/work/kernel-tsp}"
GPU_KM_TSP_DIR="${GPU_KM_TSP_DIR:-/work/gpu-km-tsp}"

[ -f "${KERNEL_TSP_DIR}/arch/arm64/boot/Image" ] || { echo "FATAL: kernel-tsp Image not found at ${KERNEL_TSP_DIR}/arch/arm64/boot/Image" >&2; exit 1; }
[ -f "${GPU_KM_TSP_DIR}/pvrsrvkm.ko" ] || { echo "FATAL: gpu-km-tsp pvrsrvkm.ko not found at ${GPU_KM_TSP_DIR}/pvrsrvkm.ko" >&2; exit 1; }

# Reproducible timestamp from git head commit
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    if git -C "${SRC_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        SOURCE_DATE_EPOCH="$(git -C "${SRC_DIR}" log -1 --format=%ct)"
    else
        SOURCE_DATE_EPOCH=1700000000
    fi
fi
export SOURCE_DATE_EPOCH

# Load committed UUIDs for reproducible filesystem generation
# (only needed for steps 5/6 — genimage + ext4 creation)
if [ "$BOOT_ONLY" != 1 ]; then
    # shellcheck source=boards/tsp/fs-uuids.env
    source "${BOARD_DIR}/fs-uuids.env"
fi

# Working directory for intermediate artifacts
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "========================================================================"
echo "PocketForge SD image builder"
echo "========================================================================"
echo "  board:     ${BOARD}"
echo "  variant:   ${VARIANT}"
echo "  substrate: ${SUBSTRATE}"
echo "  m1b-mode:  $([ "$M1B_MODE" = 1 ] && echo 'yes (busybox shell)' || echo 'no (switch_root)')"
echo "  boot-only: $([ "$BOOT_ONLY" = 1 ] && echo 'yes (initrd + boot.img only)' || echo 'no (full image)')"
echo "  epoch:     ${SOURCE_DATE_EPOCH}"
echo "  src:       ${SRC_DIR}"
echo "  blobs:     ${BLOBS_DIR}"
echo "  kernel-tsp: ${KERNEL_TSP_DIR}"
echo "  gpu-km-tsp: ${GPU_KM_TSP_DIR}"
echo "  out:       ${OUT_DIR}"
echo "========================================================================"

mkdir -p "${OUT_DIR}"

# ---- step 1: build the initrd ----------------------------------------------
echo ""
echo "=== Step 1/6: Build initrd ==="
INITRD_ARGS=(--src "${SRC_DIR}" --blobs "${BLOBS_DIR}" --out "${WORK}/initrd.gz" --variant "${VARIANT}")
if [ "$M1B_MODE" = 1 ]; then
    INITRD_ARGS+=(--m1b-mode)
fi
INITRD_ARGS+=(--kernel-tsp-dir "${KERNEL_TSP_DIR}" --gpu-km-dir "${GPU_KM_TSP_DIR}")
bash "${BOARD_DIR}/initrd/build-initrd.sh" "${INITRD_ARGS[@]}"

# ---- step 2: compile DTB ---------------------------------------------------
# (boot.img does NOT depend on DTB; only boot_package.fex does.
#  Skip in --boot-only mode.)
if [ "$BOOT_ONLY" != 1 ]; then
echo ""
echo "=== Step 2/6: Compile DTB ==="
# Use the pre-built DTB from kernel-tsp (compiled alongside the kernel)
KERNEL_DTB="${KERNEL_TSP_DIR}/arch/arm64/boot/dts/sunxi/pocketforge_tsp.dtb"
[ -f "${KERNEL_DTB}" ] || { echo "FATAL: kernel-tsp DTB not found at ${KERNEL_DTB}" >&2; exit 1; }
DTB_FILE="${WORK}/dtb.bin"
cp "${KERNEL_DTB}" "${DTB_FILE}"
echo "  dtb: copied from kernel-tsp (pre-compiled)"

DTB_SIZE="$(stat -c%s "${DTB_FILE}")"
DTB_SHA="$(sha256sum "${DTB_FILE}" | cut -d' ' -f1)"
echo "  dtb:    ${DTB_FILE} (${DTB_SIZE} bytes, sha256: ${DTB_SHA})"

# ---- step 3: pack boot_package.fex -----------------------------------------
echo ""
echo "=== Step 3/6: Pack boot_package.fex ==="
BOOTPKG_DIR="${WORK}/bootpkg"
mkdir -p "${BOOTPKG_DIR}"

# Copy vendor boot chain components into the working directory
cp "${BLOBS_DIR}/sunxi/a133/boot-chain/u-boot.bin"  "${BOOTPKG_DIR}/u-boot.bin"
cp "${BLOBS_DIR}/sunxi/a133/boot-chain/monitor.bin" "${BOOTPKG_DIR}/monitor.bin"
cp "${BLOBS_DIR}/sunxi/a133/boot-chain/scp.bin"     "${BOOTPKG_DIR}/scp.bin"
cp "${DTB_FILE}"                              "${BOOTPKG_DIR}/dtb.bin"
cp "${BOARD_DIR}/boot_package.cfg"            "${BOOTPKG_DIR}/boot_package.cfg"
# tsp-myp1.5: PocketForge boot logo. Pre-generated .bmp.lzma is committed
# next to its .png source (regen via boards/tsp/bootlogo/regen.sh when the
# PNG changes). The `bootlogo` item in boot_package.cfg pulls it into
# boot_package.fex; vendor u-boot 2018.05 LZMA-decompresses + draws it.
cp "${BOARD_DIR}/bootlogo/bootlogo.bmp.lzma"  "${BOOTPKG_DIR}/bootlogo.bmp.lzma"

# DEV-ONLY (obj-3, tsp-bcx.31): u-boot charger-shutdown-defeat. For the DEV variant,
# apply the deterministic committed blob patch to u-boot.bin BEFORE the pack, so
# dragonsecboot recomputes the boot_package checksum over the PATCHED u-boot (a surgical
# post-pack byte-patch is rejected by boot0's boot_package integrity check — proven on HW).
# This lets a dev image boot to the OS on VBUS/AC (relay) power instead of the vendor
# charger auto-shutdown. Gated on the DEV variant (release is never touched — a shipped
# device keeps stock charger behavior). Safe for non-charger boots: the patch makes the
# charger-shutdown branch unconditional, and for a non-charger reason the vendor code
# already took that branch, so battery/normal boots are byte-for-byte unchanged.
if [ "${VARIANT}" = dev ]; then
    command -v python3 >/dev/null 2>&1 || { echo "FATAL: dev charger-defeat needs python3 in the build image" >&2; exit 1; }
    CHARGER_PATCH="${BLOBS_DIR}/sunxi/a133/boot-chain/patches/uboot-charger-boot/apply-uboot-charger-boot.py"
    [ -f "${CHARGER_PATCH}" ] || { echo "FATAL: charger-defeat apply script not found: ${CHARGER_PATCH} (blobs patches text tree must be staged into the build)" >&2; exit 1; }
    echo "  DEV-ONLY: applying u-boot charger-shutdown-defeat patch (tsp-bcx.31) before pack"
    # apply-uboot-charger-boot.py verifies the vendor u-boot SHA before patching (tripwire),
    # then writes the patched bytes in place (reads fully first, so same-path is safe).
    python3 "${CHARGER_PATCH}" --vendor "${BOOTPKG_DIR}/u-boot.bin" --out "${BOOTPKG_DIR}/u-boot.bin"
    echo "  patched u-boot.bin sha256: $(sha256sum "${BOOTPKG_DIR}/u-boot.bin" | cut -d' ' -f1) (expect 2793aeb5…)"
fi

export PATH="${TOOLS_DIR}/dragonsecboot:${PATH}"

# dragonsecboot embeds wall-clock timestamps; use faketime for reproducibility.
# M1.B: measure-only (faketime makes it stable; M1.E validates).
(
    cd "${BOOTPKG_DIR}"
    if command -v faketime >/dev/null 2>&1; then
        faketime "$(date -d "@${SOURCE_DATE_EPOCH}" -u '+%Y-%m-%d %H:%M:%S')" \
            dragonsecboot -pack boot_package.cfg
    else
        echo "WARN: faketime not available; boot_package.fex will embed live timestamps" >&2
        dragonsecboot -pack boot_package.cfg
    fi
)

BOOTPKG_FILE="${BOOTPKG_DIR}/boot_package.fex"
[ -f "${BOOTPKG_FILE}" ] || { echo "FATAL: dragonsecboot did not produce boot_package.fex" >&2; exit 1; }
BOOTPKG_SIZE="$(stat -c%s "${BOOTPKG_FILE}")"
BOOTPKG_SHA="$(sha256sum "${BOOTPKG_FILE}" | cut -d' ' -f1)"
echo "  boot_package.fex: ${BOOTPKG_SIZE} bytes, sha256: ${BOOTPKG_SHA}"

fi  # end of BOOT_ONLY != 1 (steps 2-3)

# ---- step 4: create boot.img -----------------------------------------------
echo ""
echo "=== Step 4/6: Create boot.img (abootimg) ==="
KERNEL_IMAGE="${KERNEL_TSP_DIR}/arch/arm64/boot/Image"
echo "  kernel: owned-substrate (kernel-tsp)"
CMDLINE_FILE="${BOARD_DIR}/cmdline.txt"
BOOTIMG_FILE="${WORK}/boot.img"

[ -f "${KERNEL_IMAGE}" ] || { echo "FATAL: kernel Image not found at ${KERNEL_IMAGE}" >&2; exit 1; }
[ -f "${CMDLINE_FILE}" ] || { echo "FATAL: cmdline.txt not found at ${CMDLINE_FILE}" >&2; exit 1; }

# abootimg 0.6 (Debian bookworm): page size and load addresses must be passed
# as -c config entries, NOT as -p/-b shorthand flags (which don't exist in 0.6).
# Load addresses from vendor bootimg.cfg (tsp-blobs-extracted memory):
#   kerneladdr=0x40080000, ramdiskaddr=0x42000000, tagsaddr=0x40000100
abootimg --create "${BOOTIMG_FILE}" \
    -k "${KERNEL_IMAGE}" \
    -r "${WORK}/initrd.gz" \
    -c "$(cat "${CMDLINE_FILE}")" \
    -c "pagesize=0x800" \
    -c "kerneladdr=0x40080000" \
    -c "ramdiskaddr=0x42000000" \
    -c "tagsaddr=0x40000100"

BOOTIMG_SIZE="$(stat -c%s "${BOOTIMG_FILE}")"
BOOTIMG_SHA="$(sha256sum "${BOOTIMG_FILE}" | cut -d' ' -f1)"
echo "  boot.img: ${BOOTIMG_SIZE} bytes, sha256: ${BOOTIMG_SHA}"

# Verify ANDROID! magic
MAGIC="$(xxd -l 8 -p "${BOOTIMG_FILE}")"
if [ "${MAGIC}" != "414e44524f494421" ]; then
    echo "FATAL: boot.img does not have ANDROID! magic (got: ${MAGIC})" >&2
    exit 1
fi
echo "  boot.img: ANDROID! magic verified"

# ---- boot-only exit --------------------------------------------------------
if [ "$BOOT_ONLY" = 1 ]; then
    cp "${BOOTIMG_FILE}" "${OUT_DIR}/boot.img"
    FINAL_SHA="$(sha256sum "${OUT_DIR}/boot.img" | cut -d' ' -f1)"
    echo ""
    echo "========================================================================"
    echo "BOOT-ONLY BUILD COMPLETE"
    echo "========================================================================"
    echo "  ${OUT_DIR}/boot.img"
    echo "  size:   ${BOOTIMG_SIZE} bytes"
    echo "  sha256: ${FINAL_SHA}"
    echo ""
    echo "${FINAL_SHA}  boot.img" > "${OUT_DIR}/boot.img.sha256"
    # Chown to caller when running as container root
    if [ -n "${CALLER_UID:-}" ] && [ -n "${CALLER_GID:-}" ] && [ "$(id -u)" = "0" ]; then
        chown "${CALLER_UID}:${CALLER_GID}" "${OUT_DIR}/boot.img" "${OUT_DIR}/boot.img.sha256"
    fi
    exit 0
fi

# ---- step 5: compose SD image with genimage --------------------------------
echo ""
echo "=== Step 5/6: Compose SD image (genimage) ==="
GENIMAGE_CFG="${BOARD_DIR}/genimage.cfg"
GENIMAGE_TMP="${WORK}/genimage-tmp"
GENIMAGE_INPUT="${WORK}/genimage-input"
GENIMAGE_OUTPUT="${WORK}/genimage-output"
GENIMAGE_ROOT="${WORK}/genimage-root"

mkdir -p "${GENIMAGE_TMP}" "${GENIMAGE_INPUT}" "${GENIMAGE_OUTPUT}" "${GENIMAGE_ROOT}"

# Stage all input images in the genimage input directory.
# The boot0 slot @0x20000 (genimage.cfg partition boot0): vendor boot0.img by default, OR the
# owned u-boot-sunxi-with-spl.bin for --boot-chain owned-spl (tsp-147u.13). The A133 BROM loads
# whatever eGON.BT0 image sits at 0x20000, so swapping the slot content is the owned-SPL flip;
# the vendor boot_package/env slots below stay as inert placeholders (keep the GPT numbering, so
# boot-resource remains p4 = the owned u-boot's `mmc 0:4`).
if [ "${BOOT_CHAIN}" = "owned-spl" ]; then
    cp "${UBOOT_SPL}"                        "${GENIMAGE_INPUT}/boot0.img"
    echo "  boot0 slot @0x20000: OWNED u-boot-sunxi-with-spl.bin ($(stat -c%s "${UBOOT_SPL}") B, sha256 $(sha256sum "${UBOOT_SPL}" | cut -d' ' -f1)) — vendor boot0 replaced"
else
    cp "${BLOBS_DIR}/sunxi/a133/boot-chain/boot0.img"  "${GENIMAGE_INPUT}/boot0.img"
fi
cp "${BOOTPKG_FILE}"                         "${GENIMAGE_INPUT}/boot_package.fex"
cp "${BOOTIMG_FILE}"                         "${GENIMAGE_INPUT}/boot.img"
cp "${BLOBS_DIR}/sunxi/a133/boot-chain/env.img"     "${GENIMAGE_INPUT}/env.img"

# Create the empty FAT32 boot-resource partition image.
# genimage's vfat{} handler runs 'mcopy rootpath/* ::' which fails when rootpath
# is empty; we create the FAT image ourselves and feed it to genimage as raw.
echo "  Creating FAT32 boot-resource image (64 MiB, label POCKETFORGE)..."
dd if=/dev/zero of="${GENIMAGE_INPUT}/boot-resource.vfat" bs=1M count=64 2>/dev/null
mkdosfs -F 32 -n POCKETFORGE "${GENIMAGE_INPUT}/boot-resource.vfat" >/dev/null

# Copy any files from boards/tsp/boot-resource/ into the FAT image.
# wifi.txt is generated at build time by 'make generate-wifi-config' from
# the system keyring (secret-tool). The file is gitignored.
BOOT_RES_DIR="${SRC_DIR}/boards/tsp/boot-resource"
if [ -d "${BOOT_RES_DIR}" ] && ls "${BOOT_RES_DIR}"/* >/dev/null 2>&1; then
    for f in "${BOOT_RES_DIR}"/*; do
        [ -f "$f" ] || continue
        mcopy -i "${GENIMAGE_INPUT}/boot-resource.vfat" "$f" "::/$(basename "$f")"
        echo "  boot-resource: added $(basename "$f")"
    done
fi

# Owned-SPL boot payload (tsp-147u.13): the owned u-boot's CONFIG_BOOTCOMMAND does
#   load mmc 0:4 <Image> && load mmc 0:4 <dtb.bin> && load mmc 0:4 <initrd.gz> && booti ...
# so the FAT p4 (this boot-resource partition, = mmc 0:4) must carry Image/dtb.bin/initrd.gz.
# The vendor path leaves them out (it boots the Android boot.img via vendor u-boot instead).
# Exact filenames are load-bearing — they match the merged tg5040_defconfig bootcmd.
if [ "${BOOT_CHAIN}" = "owned-spl" ]; then
    [ -f "${KERNEL_IMAGE}" ] || { echo "FATAL: owned-spl: kernel Image not found at ${KERNEL_IMAGE}" >&2; exit 1; }
    [ -f "${DTB_FILE}" ]     || { echo "FATAL: owned-spl: dtb not found at ${DTB_FILE}" >&2; exit 1; }
    [ -f "${WORK}/initrd.gz" ] || { echo "FATAL: owned-spl: initrd not found at ${WORK}/initrd.gz" >&2; exit 1; }
    mcopy -i "${GENIMAGE_INPUT}/boot-resource.vfat" "${KERNEL_IMAGE}"   "::/Image"
    mcopy -i "${GENIMAGE_INPUT}/boot-resource.vfat" "${DTB_FILE}"       "::/dtb.bin"
    mcopy -i "${GENIMAGE_INPUT}/boot-resource.vfat" "${WORK}/initrd.gz" "::/initrd.gz"
    echo "  boot-resource: owned-SPL boot payload staged on FAT p4 (mmc 0:4) — Image ($(stat -c%s "${KERNEL_IMAGE}") B), dtb.bin ($(stat -c%s "${DTB_FILE}") B), initrd.gz ($(stat -c%s "${WORK}/initrd.gz") B)"
fi

# tsp-myp1.5 (charger-boot logo): vendor u-boot 2018.05 chooses splash by boot
# reason. The `bootlogo` item in boot_package.fex is drawn ONLY on the normal-boot
# path; on `boot reason=charger` (VBUS-powered — the harness and any real user who
# boots with the cable plugged in) u-boot instead tries `bat/battery_charge.bmp`
# from THIS FAT partition, and `fastbootlogo.bmp` from the FAT root in fastboot
# mode. Empirical trace (2026-07-12, pf-node-01):
#   [05.262]sunxi bmp info error : unable to open logo file bat\battery_charge.bmp
# Without these files u-boot falls to a white screen. Cover every code path with
# the same PocketForge logo (uncompressed 24bpp BI_RGB 1280x720 — matches the FB
# geometry, and u-boot does NOT lzma-decode these FAT-partition BMPs, only the
# `bootlogo` item inside boot_package.fex).
BOOTLOGO_BMP="${BOARD_DIR}/bootlogo/bootlogo.bmp"
if [ -f "${BOOTLOGO_BMP}" ]; then
    mmd -i "${GENIMAGE_INPUT}/boot-resource.vfat" ::/bat 2>/dev/null || true
    mcopy -i "${GENIMAGE_INPUT}/boot-resource.vfat" "${BOOTLOGO_BMP}" ::/bat/battery_charge.bmp
    mcopy -i "${GENIMAGE_INPUT}/boot-resource.vfat" "${BOOTLOGO_BMP}" ::/bat/bat0.bmp
    mcopy -i "${GENIMAGE_INPUT}/boot-resource.vfat" "${BOOTLOGO_BMP}" ::/bat/low_pwr.bmp
    mcopy -i "${GENIMAGE_INPUT}/boot-resource.vfat" "${BOOTLOGO_BMP}" ::/fastbootlogo.bmp
    echo "  boot-resource: added PocketForge logo BMPs (bat/battery_charge.bmp, bat/bat0.bmp, bat/low_pwr.bmp, fastbootlogo.bmp)"
else
    echo "WARN: bootlogo.bmp missing at ${BOOTLOGO_BMP} — charger-boot path will fall through to white" >&2
fi

# Create the userdata (rootfs) partition image.
if [ "$M1B_MODE" = 1 ]; then
    # M1.B mode: empty 64 MiB ext4 (no rootfs — initrd falls through to shell)
    echo "  Creating empty ext4 userdata image (64 MiB, label POCKETFORGE_DATA)..."
    dd if=/dev/zero of="${GENIMAGE_INPUT}/userdata.ext4" bs=1M count=64 2>/dev/null
    mke2fs -t ext4 -L POCKETFORGE_DATA \
        -U "${USERDATA_FS_UUID}" \
        -E "hash_seed=${USERDATA_HASH_SEED}" \
        -m 0 -O "^metadata_csum,^metadata_csum_seed,^orphan_file,^64bit" \
        "${GENIMAGE_INPUT}/userdata.ext4" >/dev/null 2>&1
else
    # M1.C+: full Debian rootfs built by build-rootfs.sh
    # If a pre-built userdata.ext4 exists in OUT_DIR, use it; otherwise build.
    if [ -f "${OUT_DIR}/userdata.ext4" ]; then
        echo "  Using pre-built userdata.ext4 from ${OUT_DIR}..."
        cp "${OUT_DIR}/userdata.ext4" "${GENIMAGE_INPUT}/userdata.ext4"
    else
        echo "  Building full Debian rootfs (this may take several minutes)..."
        # When running as container root (mmdebstrap needs it), pass the
        # caller's original uid:gid so build-rootfs.sh can chown output files.
        # CALLER_UID/CALLER_GID are set by the Makefile's docker run -e flags.
        ROOTFS_OWNER="${CALLER_UID:-$(id -u)}:${CALLER_GID:-$(id -g)}"
        bash "${SRC_DIR}/scripts/build-rootfs.sh" \
            --variant "${VARIANT}" \
            --owner "${ROOTFS_OWNER}" \
            --substrate "${SUBSTRATE}"
        cp "${OUT_DIR}/userdata.ext4" "${GENIMAGE_INPUT}/userdata.ext4"
    fi
    USERDATA_SIZE="$(stat -c%s "${GENIMAGE_INPUT}/userdata.ext4")"
    echo "  userdata.ext4: ${USERDATA_SIZE} bytes ($(( USERDATA_SIZE / 1024 / 1024 )) MiB)"
fi

# Verify env.img bootcmd does NOT directly reference eMMC.
# The env contains mmc_root=/dev/mmcblk0p7 and setargs_mmc, but those are
# never invoked: bootcmd uses setargs_nand + boot_normal. Our boot.img cmdline
# overrides bootargs at bootm time anyway.
# Extract the bootcmd value from the binary env (null-terminated key=value pairs
# after a 4-byte CRC header).
echo "  Checking env.img bootcmd..."
BOOTCMD_LINE="$(dd if="${GENIMAGE_INPUT}/env.img" bs=1 skip=4 2>/dev/null | tr '\0' '\n' | grep '^bootcmd=' || true)"
echo "  bootcmd: ${BOOTCMD_LINE}"
if echo "${BOOTCMD_LINE}" | grep -q 'setargs_mmc'; then
    echo "FATAL: env.img bootcmd invokes setargs_mmc — would resolve mmc_root to eMMC" >&2
    exit 1
fi
echo "  env.img: bootcmd safe (uses setargs_nand; our boot.img cmdline overrides)"

genimage \
    --inputpath "${GENIMAGE_INPUT}" \
    --outputpath "${GENIMAGE_OUTPUT}" \
    --rootpath "${GENIMAGE_ROOT}" \
    --tmppath "${GENIMAGE_TMP}" \
    --config "${GENIMAGE_CFG}"

SD_IMAGE="${GENIMAGE_OUTPUT}/pocketforge-tsp.img"
[ -f "${SD_IMAGE}" ] || { echo "FATAL: genimage did not produce pocketforge-tsp.img" >&2; exit 1; }
SD_SIZE="$(stat -c%s "${SD_IMAGE}")"
echo "  pocketforge-tsp.img: ${SD_SIZE} bytes ($(( SD_SIZE / 1024 / 1024 )) MiB)"

# Verify SPL magic at sector 256 (128 KiB offset)
SPL_MAGIC="$(xxd -s $((128 * 1024)) -l 16 "${SD_IMAGE}" | head -1)"
echo "  SPL @ 128 KiB: ${SPL_MAGIC}"
if ! echo "${SPL_MAGIC}" | grep -q '6547 4f4e 2e42 5430'; then
    echo "FATAL: eGON.BT0 magic not found at 128 KiB offset" >&2
    exit 1
fi
echo "  SPL: eGON.BT0 magic verified"

# Owned-SPL structural spot-check (tsp-147u.13): eGON.BT0 alone does NOT distinguish the OWNED
# SPL from vendor boot0 (both carry it), so assert the OWNED u-boot's SPL landed at 0x20000 by
# matching the exact bytes we staged into the boot0 slot against the image at 128 KiB. This
# catches an assemble bug where the vendor blob (or nothing) ended up in the slot before we ever
# burn a DUT. Also confirm the owned u-boot's booti payload is present on the FAT p4 boot-resource.
if [ "${BOOT_CHAIN}" = "owned-spl" ]; then
    SPL_LEN="$(stat -c%s "${UBOOT_SPL}")"
    # 128 KiB offset = 128 1-KiB blocks; read ceil(SPL_LEN/1024) blocks then trim to exact length.
    IMG_SPL_SHA="$(dd if="${SD_IMAGE}" bs=1024 skip=128 count=$(( (SPL_LEN + 1023) / 1024 )) 2>/dev/null | head -c "${SPL_LEN}" | sha256sum | cut -d' ' -f1)"
    OWNED_SPL_SHA="$(sha256sum "${UBOOT_SPL}" | cut -d' ' -f1)"
    if [ "${IMG_SPL_SHA}" != "${OWNED_SPL_SHA}" ]; then
        echo "FATAL: owned-spl: bytes at 0x20000 (sha ${IMG_SPL_SHA}) do NOT match the owned u-boot-sunxi-with-spl.bin (sha ${OWNED_SPL_SHA}) — wrong SPL in the boot0 slot" >&2
        exit 1
    fi
    echo "  SPL: OWNED u-boot-sunxi-with-spl.bin verified @0x20000 (${SPL_LEN} B, sha ${OWNED_SPL_SHA})"
    FAT_LIST="$(mdir -b -i "${GENIMAGE_INPUT}/boot-resource.vfat" ::/ 2>/dev/null || true)"
    for bf in Image dtb.bin initrd.gz; do
        printf '%s\n' "${FAT_LIST}" | grep -qiE "(^|/)${bf}\$" \
            || { echo "FATAL: owned-spl: FAT p4 boot-resource is missing ${bf} (the owned u-boot booti's it from mmc 0:4)" >&2; exit 1; }
    done
    echo "  boot-resource p4: owned-SPL booti payload verified (Image, dtb.bin, initrd.gz present)"
fi

# ---- step 6: compress + checksum -------------------------------------------
echo ""
echo "=== Step 6/6: Compress + checksum ==="
FINAL_NAME="pocketforge-tsp"
if [ "${VARIANT}" = "dev" ]; then
    FINAL_NAME="pocketforge-tsp-dev"
fi
if [ "${M1B_MODE}" = 1 ]; then
    FINAL_NAME="${FINAL_NAME}-m1b"
fi

FINAL_IMG="${OUT_DIR}/${FINAL_NAME}.img"
FINAL_XZ="${OUT_DIR}/${FINAL_NAME}.img.xz"

cp "${SD_IMAGE}" "${FINAL_IMG}"

# Release: single-threaded xz for bit-for-bit reproducibility (G-reproducible).
# Dev: parallel xz at lowest scheduling priority for faster builds.
#
# --block-size is load-bearing for -T0: xz parallelizes across independent
# blocks, one per thread, and at -9 the default block size is 192 MiB (3x the
# 64 MiB dict). Our ~1.1 GiB image therefore splits into only ~6 blocks, so no
# more than ~6 threads ever engage regardless of core count. Forcing 32 MiB
# blocks yields ~36 blocks, saturating 16-32-core build hosts, for a ~1-2%
# ratio penalty (per-block dictionary reset). Do NOT add this to the release
# branch: multithreaded/blocked output is not bit-for-bit vs -T1.
if [ "${VARIANT}" = "release" ]; then
    xz -9 --threads=1 --force "${FINAL_IMG}"
else
    nice -n 19 xz -9 -T0 --block-size=32MiB --force "${FINAL_IMG}"
fi

FINAL_SHA="$(sha256sum "${FINAL_XZ}" | cut -d' ' -f1)"
FINAL_SIZE="$(stat -c%s "${FINAL_XZ}")"

echo ""
echo "========================================================================"
echo "BUILD COMPLETE"
echo "========================================================================"
echo "  ${FINAL_XZ}"
echo "  size:   ${FINAL_SIZE} bytes ($(( FINAL_SIZE / 1024 / 1024 )) MiB)"
echo "  sha256: ${FINAL_SHA}"
echo ""
echo "Flash command:"
echo "  xz -dc ${FINAL_XZ} | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress"
echo ""

# Write SHA manifest
echo "${FINAL_SHA}  $(basename "${FINAL_XZ}")" > "${OUT_DIR}/${FINAL_NAME}.img.xz.sha256"
echo "  SHA manifest: ${OUT_DIR}/${FINAL_NAME}.img.xz.sha256"

# Chown output files to the caller's uid:gid when running as container root.
# CALLER_UID/CALLER_GID are set by the Makefile's docker run -e flags.
if [ -n "${CALLER_UID:-}" ] && [ -n "${CALLER_GID:-}" ] && [ "$(id -u)" = "0" ]; then
    chown "${CALLER_UID}:${CALLER_GID}" "${FINAL_XZ}" "${OUT_DIR}/${FINAL_NAME}.img.xz.sha256"
    echo "  chown: ${CALLER_UID}:${CALLER_GID}"
fi
