#!/usr/bin/env bash
# =============================================================================
# build-rootfs-a523.sh — Build the A523 (tsp-s) Debian rootfs ext4
# =============================================================================
# The SoC-agnostic substrate pipeline re-targeted to the TrimUI Smart Pro S
# (A523 / sun55iw3), bead tsp-vuo.4. Creates a Debian 12 bookworm arm64 rootfs
# via mmdebstrap, runs boards/tsp-s/rootfs-customize.sh, and assembles a
# deterministic ext4 (LABEL=POCKETFORGE_DATA) using the committed board UUIDs.
#
# Separate from build-rootfs.sh (the A133 path) ON PURPOSE: the A523 ships none
# of the A133's PowerVR/libSDL3/xradio payload (those are tsp-vuo.2/.3), and the
# A133 build is near a public release — keeping the two paths apart avoids
# destabilising it. Shared mechanism (mmdebstrap invocation, Reproducible-Builds
# ext4 recipe) is mirrored, not refactored.
#
# Runs INSIDE the pocketforge/build container AS ROOT (mmdebstrap needs real
# chroot/mount for cross-arch). Bind mounts:
#   /work/src     (ro) — image repo
#   /work/modules (ro) — kernel modules_install staging (lib/modules/<KREL>)
#   /work/out     (rw) — output (userdata-a523.ext4)
#
# Usage: build-rootfs-a523.sh [--variant dev|release] [--owner UID:GID]
# =============================================================================
set -euo pipefail

SRC_DIR="${SRC_DIR:-/work/src}"
OUT_DIR="${OUT_DIR:-/work/out}"
BOARD_DIR="${SRC_DIR}/boards/tsp-s"
VARIANT="dev"
OWNER_UID=""; OWNER_GID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --variant) VARIANT="$2"; shift 2 ;;
        --owner)   OWNER_UID="${2%%:*}"; OWNER_GID="${2##*:}"; shift 2 ;;
        *) echo "build-rootfs-a523.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ "$VARIANT" = dev ] || [ "$VARIANT" = release ] || { echo "FATAL: --variant dev|release" >&2; exit 2; }

# shellcheck source=boards/tsp-s/board.env
source "${BOARD_DIR}/board.env"
# shellcheck source=boards/tsp-s/fs-uuids.env
source "${BOARD_DIR}/fs-uuids.env"

if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    if git -C "${SRC_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        SOURCE_DATE_EPOCH="$(git -C "${SRC_DIR}" log -1 --format=%ct)"
    else SOURCE_DATE_EPOCH=1700000000; fi
fi
export SOURCE_DATE_EPOCH

SNAPSHOT_DATE="$(cat "${SRC_DIR}/snapshot-date.txt")"
SNAPSHOT_URL="http://snapshot.debian.org/archive/debian/${SNAPSHOT_DATE}/"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${OUT_DIR}"

echo "=========================================================================="
echo "PocketForge A523 (tsp-s) rootfs builder"
echo "  variant=${VARIANT} epoch=${SOURCE_DATE_EPOCH} KREL=${KREL}"
echo "  snapshot=${SNAPSHOT_URL}"
echo "=========================================================================="

# --- package list ------------------------------------------------------------
PKG_FILE="${SRC_DIR}/rootfs-packages-a523.txt"
PKG_DEV_FILE="${SRC_DIR}/rootfs-packages-a523-dev.txt"
PKG_LIST="$(grep -vE '^\s*(#|$)' "${PKG_FILE}" | tr '\n' ',' | sed 's/,$//')"
if [ "${VARIANT}" = dev ] && [ -f "${PKG_DEV_FILE}" ]; then
    DEV_PKGS="$(grep -vE '^\s*(#|$)' "${PKG_DEV_FILE}" | tr '\n' ',' | sed 's/,$//')"
    PKG_LIST="${PKG_LIST},${DEV_PKGS}"
fi
echo "  packages: ${PKG_LIST}"

# --- mmdebstrap --------------------------------------------------------------
ROOTFS_TAR="${WORK}/rootfs.tar"
echo "=== mmdebstrap (arm64 bookworm minbase, under qemu) ==="
POCKETFORGE_VARIANT="${VARIANT}" KREL="${KREL}" \
mmdebstrap \
    --arch=arm64 --variant=minbase --mode=root \
    --aptopt='Acquire::Check-Valid-Until "false"' \
    --aptopt='APT::Sandbox::User "root"' \
    --include="${PKG_LIST}" \
    --customize-hook="env POCKETFORGE_VARIANT=${VARIANT} KREL=${KREL} ${BOARD_DIR}/rootfs-customize.sh \"\$1\"" \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-include=/usr/share/doc/*/copyright' \
    bookworm "${ROOTFS_TAR}" "${SNAPSHOT_URL}"

# --- deterministic ext4 (Reproducible-Builds recipe, committed UUIDs) --------
echo "=== deterministic ext4 assembly ==="
EXT="${WORK}/rootfs-extracted"; mkdir -p "${EXT}"
tar -xf "${ROOTFS_TAR}" -C "${EXT}"

# Re-assert user-home ownership in the extracted tree. In this build path the
# mmdebstrap tar landed /home/<user> as root:root (the A133 build-rootfs.sh path
# preserves it; this one didn't — tsp-vuo.4), so sshd StrictModes rejected the
# dev keys and the rsync iteration loop was blocked. mke2fs -d preserves the
# extract-dir ownership into the ext4 (verified), so fixing it here is reliable.
# Drive it off the rootfs's own passwd (uid>=1000 human users with /home homes).
echo "  re-asserting /home/<user> ownership from rootfs passwd..."
awk -F: '$3>=1000 && $3<65534 && $6 ~ /^\/home\//{print $3":"$4" "$6}' "${EXT}/etc/passwd" | \
while read -r ug home; do
    if [ -d "${EXT}${home}" ]; then
        chown -R "$ug" "${EXT}${home}"
        echo "    chown -R ${ug} ${home}"
    fi
done

ROOTFS_DU="$(du -sm "${EXT}" | cut -f1)"
EXT4_SIZE_MB=1024
[ "${ROOTFS_DU}" -gt 768 ] && EXT4_SIZE_MB=$(( ROOTFS_DU * 130 / 100 ))
echo "  rootfs ${ROOTFS_DU} MiB -> ext4 ${EXT4_SIZE_MB} MiB"

find "${EXT}" -depth -print0 | xargs -0 touch --no-dereference --date="@${SOURCE_DATE_EPOCH}" 2>/dev/null || true

OUT_EXT4="${OUT_DIR}/userdata-a523.ext4"
mke2fs -t ext4 -d "${EXT}" \
    -E "hash_seed=${USERDATA_HASH_SEED}" \
    -U "${USERDATA_FS_UUID}" \
    -L "POCKETFORGE_DATA" \
    -O "^metadata_csum,^metadata_csum_seed,^orphan_file,^64bit" \
    -m 0 \
    "${OUT_EXT4}" "$(( EXT4_SIZE_MB * 1024 ))"

EXT4_SHA="$(sha256sum "${OUT_EXT4}" | cut -d' ' -f1)"
echo "=========================================================================="
echo "A523 ROOTFS COMPLETE: ${OUT_EXT4}"
echo "  size=$(stat -c%s "${OUT_EXT4}") sha256=${EXT4_SHA} label=POCKETFORGE_DATA uuid=${USERDATA_FS_UUID}"
echo "=========================================================================="
echo "${EXT4_SHA}  userdata-a523.ext4" > "${OUT_DIR}/userdata-a523.ext4.sha256"
if [ -n "${OWNER_UID}" ] && [ -n "${OWNER_GID}" ]; then
    chown "${OWNER_UID}:${OWNER_GID}" "${OUT_EXT4}" "${OUT_DIR}/userdata-a523.ext4.sha256"
fi
