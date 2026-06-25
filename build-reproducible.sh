#!/usr/bin/env bash
# build-reproducible.sh — one-command reproducible owned-image build.
#
# Builds a flashable PocketForge SD image from COMMITTED GIT REFS ONLY, on any
# host with Docker (+ qemu-user-static binfmt) and read access to the private
# pocketforge-os repos. No host working trees, no rsync, no pre-staged blobs:
# everything is cloned fresh at a pinned ref and built in the pinned container.
#
# Stages (all containerised):
#   fetch   - vendor blobs: IPFS (signed vendor-manifest, --blobs ipfs) or a
#             clone of the private blobs repo (--blobs git, default until the
#             manifest is populated by tsp-iby).
#   build   - kernel-tsp (Image+dtbs+modules), gpu-km-tsp (pvrsrvkm.ko +
#             dc_sunxi.ko), libsdl3-sunxifb (libSDL3-pocketforge.so.0 + tests).
#   assemble- image/ `make build-image` -> work/out/pocketforge-tsp-<variant>.img.xz
#
# kubo/minisign run ONLY in the fetch stage (when --blobs ipfs); they never
# enter the built image. See BUILD_PIPELINE.md "Owned substrate & blob
# provenance" + beads tsp-cv7.6 / tsp-cv7.6.2 / tsp-iby.
#
# Auth: clones use https; set GH_TOKEN for a token-auth host, otherwise the
# host's git credential helper / ssh keys are used (GH_SSH=1 -> git@ URLs).
set -euo pipefail

# ---- config (all pinnable via env) ----
WORK="${WORK:-$(pwd)/repro-work}"
CONTAINER="${CONTAINER:-pocketforge/build:10.3-2021.07-bookworm}"
VARIANT="${VARIANT:-dev}"
BLOBS_SOURCE="${BLOBS_SOURCE:-git}"            # git | ipfs
IPFS_API="${IPFS_API:-/ip4/127.0.0.1/tcp/5001}"

GH_BASE_HTTPS="https://github.com/pocketforge-os"
GH_BASE_SSH="git@github.com:pocketforge-os"
KERNEL_REF="${KERNEL_REF:-main}"
GPUKM_REF="${GPUKM_REF:-main}"
SDL_REF="${SDL_REF:-phase0/sdl3-forward-port}"
IMAGE_REF="${IMAGE_REF:-main}"
BLOBS_REF="${BLOBS_REF:-main}"

log() { printf '\n=== %s ===\n' "$*"; }

clone_one() {
  # clone_one <repo> <ref>
  local repo="$1" ref="$2" url
  if [ "${GH_SSH:-0}" = "1" ]; then
    url="${GH_BASE_SSH}/${repo}.git"
  elif [ -n "${GH_TOKEN:-}" ]; then
    url="https://x-access-token:${GH_TOKEN}@github.com/pocketforge-os/${repo}.git"
  else
    url="${GH_BASE_HTTPS}/${repo}.git"
  fi
  git clone --depth 1 -b "$ref" "$url" "$WORK/$repo"
  printf '  %-16s %s @ %s\n' "$repo" "$ref" "$(git -C "$WORK/$repo" rev-parse --short HEAD)"
}

drun() { docker run --rm --user "$(id -u):$(id -g)" "$@"; }

# ---- preflight ----
command -v docker >/dev/null || { echo "FATAL: docker missing"; exit 1; }
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "FATAL: qemu-aarch64 binfmt not registered"; exit 1; }

log "clone committed refs -> $WORK"
rm -rf "$WORK"; mkdir -p "$WORK"
clone_one kernel-tsp       "$KERNEL_REF"
clone_one gpu-km-tsp       "$GPUKM_REF"
clone_one libsdl3-sunxifb  "$SDL_REF"
clone_one image            "$IMAGE_REF"

# ---- fetch: vendor blobs ----
case "$BLOBS_SOURCE" in
  ipfs)
    log "fetch blobs via IPFS (content-addressed vendor-manifest; kubo host/stage-local)"
    ( cd "$WORK/image" && make fetch-blobs IPFS_API="$IPFS_API" )
    BLOBS_DIR="$WORK/image/work/blobs" ;;
  local)
    # Offline / CI-cache: use a pre-staged stock-vendor blobs dir (content is
    # identical to git/IPFS). Validates the build mechanism without GitHub blob
    # auth or a local kubo. NOT the canonical source path.
    BLOBS_DIR="${LOCAL_BLOBS_PATH:?set LOCAL_BLOBS_PATH for BLOBS_SOURCE=local}"
    log "use local pre-staged blobs: $BLOBS_DIR" ;;
  git|*)
    log "fetch blobs via git clone (interim; prefer BLOBS_SOURCE=ipfs once a host/stage has kubo)"
    clone_one blobs "$BLOBS_REF"
    BLOBS_DIR="$WORK/blobs" ;;
esac

# ---- build: kernel ----
log "build kernel-tsp (Image + dtbs + modules)"
drun -v "$WORK/kernel-tsp:/work/kernel-tsp:rw" -w /work/kernel-tsp "$CONTAINER" \
  bash -lc 'export PATH=/opt/arm-10.3-2021.07/bin:$PATH ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- HOSTCFLAGS=-fcommon KCFLAGS=-Wno-error; make mrproper; make pocketforge_tsp_defconfig; make -j"$(nproc)" Image dtbs modules'

# ---- build: gpu kernel module ----
log "build gpu-km-tsp (pvrsrvkm.ko + dc_sunxi.ko)"
drun -v "$WORK/kernel-tsp:/work/kernel-tsp:rw" -v "$WORK/gpu-km-tsp:/work/gpu-km-tsp:rw" \
     -v "$WORK/image:/work/src/image:ro" -w /work/gpu-km-tsp "$CONTAINER" \
  bash -lc 'export PATH=/opt/arm-10.3-2021.07/bin:$PATH CROSS_COMPILE=aarch64-none-linux-gnu-; make -C /work/kernel-tsp M=/work/gpu-km-tsp ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- clean; ./build-sunxi-a133.sh /work/kernel-tsp'

# ---- build: libSDL3 (sunxifb backend + tests) ----
log "build libsdl3-sunxifb (libSDL3-pocketforge.so.0 + tests)"
SDL_OUT="$WORK/sdl-out"; mkdir -p "$SDL_OUT"
drun -v "$WORK/libsdl3-sunxifb:/work/src:ro" -v "$BLOBS_DIR:/work/blobs:ro" -v "$SDL_OUT:/work/out" \
     "$CONTAINER" bash /work/src/build/build-libsdl3.sh

# ---- assemble: image ----
log "assemble image ($VARIANT, owned substrate)"
cd "$WORK/image"
rm -f work/out/userdata.ext4 work/out/pocketforge-tsp-"$VARIANT".img work/out/pocketforge-tsp-"$VARIANT".img.xz work/out/pocketforge-tsp-"$VARIANT".img.xz.sha256 2>/dev/null || true
make build-image \
  VARIANT="$VARIANT" \
  SUBSTRATE=owned \
  LOCAL_BLOBS="$BLOBS_DIR" \
  LOCAL_LIBSDL3="$SDL_OUT" \
  LOCAL_KERNEL_TSP="$WORK/kernel-tsp" \
  LOCAL_GPU_KM_TSP="$WORK/gpu-km-tsp"

IMG="$WORK/image/work/out/pocketforge-tsp-${VARIANT}.img.xz"
log "DONE"
printf 'reproducible_image=%s\n' "$IMG"
[ -f "$IMG.sha256" ] && cat "$IMG.sha256"
printf 'refs: kernel-tsp@%s gpu-km-tsp@%s libsdl3@%s image@%s blobs=%s\n' \
  "$KERNEL_REF" "$GPUKM_REF" "$SDL_REF" "$IMAGE_REF" "$BLOBS_SOURCE"
