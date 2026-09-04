#!/usr/bin/env bash
# build-qemu-a133-earlycon-initramfs.sh -- trivial from-scratch initramfs for the
# `-M pocketforge-a133` earlycon boot smoke (bd tsp-mc9m.41.925.2.1, Odyssey L3
# emulation Phase A). Unlike build-qemu-a133-initramfs.sh (which execs
# pocketforge-menu and waits on /dev/fb0), Phase A models NO virtio-gpu and NO
# CCU/pinctrl (those land in later phases) -- so this initramfs's only job is to
# prove userspace was reached at all (a clean signal distinct from earlycon's own
# output) and then halt, rather than wait on hardware this machine does not model.
#
# Not part of the shipping image pipeline; a standalone dev/CI harness that runs
# entirely under QEMU on modelmaker, never against a physical DUT.
#
# Usage:
#   build-qemu-a133-earlycon-initramfs.sh --out <out.cpio.gz> \
#       [--cross <cross-prefix->] [--work <dir>]
#
# Run on modelmaker (mm) -- see .claude/rules/model-policy.md "builds run on mm,
# never the laptop". Requires: aarch64-linux-gnu-gcc/-readelf, curl, cpio, gzip.
# Re-runnable: busybox source is fetched once into --work and reused/verified by
# sha256 on subsequent runs.
set -euo pipefail

CROSS="${CROSS:-aarch64-linux-gnu-}"
BUSYBOX_VER="1.36.1"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2"
BUSYBOX_SHA256="b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314"
WORK=""
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --cross) CROSS="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "FATAL: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || { echo "FATAL: --out <path> is required" >&2; exit 2; }

WORK="${WORK:-$(mktemp -d /tmp/qemu-a133-earlycon-initramfs.XXXXXX)}"
mkdir -p "$WORK"
# Stage under a FRESH mktemp dir, never a fixed "$WORK/root" -- see the identical
# rm -rf footgun note in build-qemu-a133-initramfs.sh; same fix applied here.
ROOT="$(mktemp -d "$WORK/stage.XXXXXX")/root"
mkdir -p "$ROOT"/{bin,proc,sys,dev}

echo "=== fetching busybox ${BUSYBOX_VER} (pinned sha256) ==="
TARBALL="$WORK/busybox-${BUSYBOX_VER}.tar.bz2"
need_fetch=1
if [ -s "$TARBALL" ] && echo "${BUSYBOX_SHA256}  ${TARBALL}" | sha256sum -c - >/dev/null 2>&1; then
  need_fetch=0
fi
if [ "$need_fetch" = 1 ]; then
  curl -fsSL -o "$TARBALL" "$BUSYBOX_URL"
fi
echo "${BUSYBOX_SHA256}  ${TARBALL}" | sha256sum -c -

BB_STAGE="$(mktemp -d "$WORK/busybox-src.XXXXXX")"
tar -xjf "$TARBALL" -C "$BB_STAGE"
BB_SRC="$BB_STAGE/busybox-${BUSYBOX_VER}"

echo "=== cross-compiling busybox (static, aarch64) ==="
(
  cd "$BB_SRC"
  make defconfig >/dev/null
  sed -i \
    -e 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
    -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
    .config
  grep -q '^CONFIG_STATIC=y' .config
  make CROSS_COMPILE="$CROSS" -j"$(nproc)" busybox
)
BB_BIN="$BB_SRC/busybox"
"${CROSS}readelf" -h "$BB_BIN" | grep -q AArch64 || { echo "FATAL: busybox is not AArch64" >&2; exit 1; }
if "${CROSS}readelf" -d "$BB_BIN" 2>/dev/null | grep -q NEEDED; then
  echo "FATAL: busybox has DT_NEEDED entries (not static)" >&2; exit 1
fi

cp "$BB_BIN" "$ROOT/bin/busybox"
chmod 0755 "$ROOT/bin/busybox"
for applet in sh mount umount cat echo poweroff halt dmesg; do
  ln -sf busybox "$ROOT/bin/$applet"
done

cat > "$ROOT/init" <<'INIT_EOF'
#!/bin/busybox sh
# Minimal PID 1 for the -M pocketforge-a133 Phase A earlycon boot smoke. Phase A
# models no virtio-gpu/input and no CCU/pinctrl (those are Phase B/C's job), so
# there is nothing device-backed worth waiting on here -- this init exists only
# to print a marker DISTINCT from any kernel earlycon line (proving userspace was
# actually reached, i.e. the kernel didn't merely print early boot text and then
# silently wedge before handing off to init) and then cleanly power off so the
# harness capturing the transcript does not need a hard timeout cutoff.
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
echo "pocketforge-a133: phase-a initramfs userspace reached" >/dev/console 2>&1 || true
exec /bin/busybox poweroff -f
INIT_EOF
chmod 0755 "$ROOT/init"

echo "=== assembling cpio ($OUT) ==="
mkdir -p "$(dirname "$OUT")"
( cd "$ROOT" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$OUT"
echo "OK out=$OUT size=$(stat -c%s "$OUT") sha256=$(sha256sum "$OUT" | cut -d' ' -f1)"
