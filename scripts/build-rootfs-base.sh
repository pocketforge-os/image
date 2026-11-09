#!/usr/bin/env bash
# =============================================================================
# build-rootfs-base.sh - the cached a133 rootfs base (tsp-hqm1p.182.13)
# =============================================================================
# Runs the rootfs apt solve, mmdebstrap's 17-minute qemu pass, exactly once per
# solve input. The Dockerfile rootfs-base stage keys it only on those inputs:
# the package lists, snapshot-date.txt, the local debs that join the solve, the
# profile facts that select packages, and this recipe. build-rootfs.sh then
# replays the base under the customize hook (pf_rootfs_overlay_opts), so an
# image-only change runs no apt.
#
# The solve options are the single pass's own (scripts/rootfs-package-list.sh),
# minus the customize hook, plus --skip=cleanup: the overlay's mmdebstrap run
# performs the whole cleanup once over the final tree, as the single pass does.
# The base is normalized so it does not depend on the fetch transport. The
# persisted snapshot source is rewritten to https and the persisted proxy aptopt
# stripped, with the same scripts and in the same way the single pass applies
# after extraction (both are idempotent there).
#
# Out: OUT_DIR/rootfs-base.tar (xattrs kept, name-sorted, numeric owners) and
#      OUT_DIR/rootfs-base.manifest (pf_rootfs_base_identity + tar_sha256).
#
# SOURCE_DATE_EPOCH here is the snapshot date's own instant, not the image's:
# the base must not change with image commits. The assembly re-clamps every
# mtime to the image epoch. Content that embeds the epoch (shadow lastchg of
# users created by package maintainer scripts) carries the snapshot instant.
#
# Usage: build-rootfs-base.sh --variant dev|release
set -euo pipefail

SRC_DIR="${SRC_DIR:-/work/src}"
OUT_DIR="${OUT_DIR:-/out}"
VARIANT=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --variant) VARIANT="${2:-}"; shift 2 ;;
        *) echo "FATAL: unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "${VARIANT}" in
    dev|release) ;;
    *) echo "FATAL: --variant must be 'dev' or 'release', got '${VARIANT}'" >&2; exit 2 ;;
esac
PF_GPU_MODEL="${PF_GPU_MODEL:-ddk}"
case "${PF_GPU_MODEL}" in
    ddk|open|none) ;;
    *) echo "FATAL: PF_GPU_MODEL must be ddk|open|none, got '${PF_GPU_MODEL}'" >&2; exit 2 ;;
esac
PF_DEVICE_ID="${PF_DEVICE_ID:?FATAL: PF_DEVICE_ID is required}"
PF_DISPLAY_PIPELINE="${PF_DISPLAY_PIPELINE:?FATAL: PF_DISPLAY_PIPELINE is required (fbdev|drm|none)}"
case "${PF_DISPLAY_PIPELINE}" in
    fbdev|drm) PF_HAS_DISPLAY=1 ;;
    none) PF_HAS_DISPLAY=0 ;;
    *) echo "FATAL: PF_DISPLAY_PIPELINE must be fbdev|drm|none, got '${PF_DISPLAY_PIPELINE}'" >&2; exit 2 ;;
esac
PF_GAMESCOPE_MODE="${PF_GAMESCOPE_MODE:-not-shipped}"
CLOUD_INIT_DIR="${CLOUD_INIT_DIR:-/work/cloud-init}"
GPU_UM_MESA_DIR="${GPU_UM_MESA_DIR:-/work/gpu-um-mesa}"
PF_APT_FIX_DIR="${PF_APT_FIX_DIR:-/opt/pocketforge/apt-cve-2026-109518}"
MMDEBSTRAP="${PF_MMDEBSTRAP:-mmdebstrap}"   # a test seam; the build uses the container's

# shellcheck source=scripts/rootfs-package-list.sh
source "${SRC_DIR}/scripts/rootfs-package-list.sh"
pf_rootfs_snapshot_url
[[ "${SNAPSHOT_DATE}" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]] \
    || { echo "FATAL: snapshot-date.txt is not YYYYMMDDTHHMMSSZ: ${SNAPSHOT_DATE}" >&2; exit 1; }
SOURCE_DATE_EPOCH="$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}Z" +%s)"
export SOURCE_DATE_EPOCH

pf_rootfs_package_list
pf_rootfs_local_package_opts
pf_rootfs_apt_proxy_opts
pf_rootfs_mmdebstrap_opts

WORK="$(mktemp -d)"
trap 'rm -rf --one-file-system "${WORK}"' EXIT
ROOT="${WORK}/root"
mkdir -p "${OUT_DIR}"
echo "=== rootfs base: mmdebstrap solve (snapshot ${SNAPSHOT_DATE}, epoch ${SOURCE_DATE_EPOCH}) ==="
POCKETFORGE_VARIANT="${VARIANT}" SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
"${MMDEBSTRAP}" \
    "${MMDEBSTRAP_SOLVE_OPTS[@]}" \
    --skip=cleanup \
    "${MMDEBSTRAP_DPKG_OPTS[@]}" \
    bookworm \
    "${ROOT}" \
    "${SNAPSHOT_URL}"

"${SRC_DIR}/scripts/rewrite-rootfs-apt-sources-https.sh" "${ROOT}"
"${SRC_DIR}/scripts/strip-rootfs-apt-proxy.sh" "${ROOT}" "${APT_PROXY_PERSISTED}"

tar --create --file="${OUT_DIR}/rootfs-base.tar" --directory="${ROOT}" \
    --xattrs --xattrs-include='*' \
    --sort=name --numeric-owner --one-file-system \
    --mtime="@${SOURCE_DATE_EPOCH}" --clamp-mtime \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    --format=posix .
{
    pf_rootfs_base_identity
    printf 'tar_sha256=%s\n' "$(sha256sum "${OUT_DIR}/rootfs-base.tar" | cut -d' ' -f1)"
} > "${OUT_DIR}/rootfs-base.manifest"
echo "=== rootfs base: $(stat -c%s "${OUT_DIR}/rootfs-base.tar") bytes ==="
cat "${OUT_DIR}/rootfs-base.manifest"
