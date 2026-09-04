#!/usr/bin/env bash
# build-qemu-a133-initramfs.sh -- minimal, from-scratch initramfs for the QEMU `-M virt`
# virtio boot smoke of the open kernel-sunxi-6.x/a133-open line (bd tsp-mc9m.41.925.1,
# Odyssey L3 emulation). NOT part of the shipping image pipeline and NOT related to
# boards/tsp*/initrd/* (those are 4.9-vendor/PowerVR-blob tied) -- this is a standalone
# dev/CI harness that runs entirely under QEMU on modelmaker, never against a physical DUT.
#
# It statically cross-compiles busybox for aarch64 (pinned upstream source, sha256
# verified) and assembles a gzip'd newc cpio containing:
#   /init                    -- busybox ash script: mount proc/sys, exec pocketforge-menu
#   /bin/busybox (+ applet symlinks: sh, mount, umount, mkdir, cat, ls, echo, sleep,
#                  poweroff, halt, ps, dmesg, ln, chmod, mknod)
#   /opt/pocketforge/bin/pocketforge-menu  -- the caller-supplied static aarch64 binary
#
# Usage:
#   build-qemu-a133-initramfs.sh --menu-bin <path-to-aarch64-static-pocketforge-menu> \
#       --out <out.cpio.gz> [--cross <cross-prefix->] [--work <dir>]
#
# The menu binary itself is built the normal way (see apps/pocketforge-menu/Makefile),
# just cross-compiled + statically linked for aarch64, e.g.:
#   aarch64-linux-gnu-gcc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-unused-function \
#       -static -o pocketforge-menu apps/pocketforge-menu/src/main.c
#   aarch64-linux-gnu-strip pocketforge-menu
#
# Run on modelmaker (mm) -- see .claude/rules/model-policy.md "builds run on mm, never
# the laptop". Requires: aarch64-linux-gnu-gcc/-readelf (Ubuntu: gcc-aarch64-linux-gnu,
# binutils-aarch64-linux-gnu), curl, cpio, gzip. Re-runnable: busybox source is fetched
# once into --work and reused/verified by sha256 on subsequent runs.
set -euo pipefail

CROSS="${CROSS:-aarch64-linux-gnu-}"
BUSYBOX_VER="1.36.1"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2"
BUSYBOX_SHA256="b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314"
WORK=""
MENU_BIN=""
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --menu-bin) MENU_BIN="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --cross) CROSS="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "FATAL: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MENU_BIN" ] && [ -s "$MENU_BIN" ] || { echo "FATAL: --menu-bin <path> is required and must exist" >&2; exit 2; }
[ -n "$OUT" ] || { echo "FATAL: --out <path> is required" >&2; exit 2; }
"${CROSS}readelf" -h "$MENU_BIN" 2>/dev/null | grep -q AArch64 \
  || { echo "FATAL: --menu-bin is not an AArch64 ELF ($MENU_BIN)" >&2; exit 2; }
# Reject a dynamically-linked menu binary the same way busybox is checked below: this
# minimal initramfs ships NO dynamic loader or shared libs, so a dynamic binary would
# pass this ELF check, get copied in, and then fail to exec at boot with no useful
# diagnostic (ELF interpreter not found) -- fail loudly here instead.
if "${CROSS}readelf" -d "$MENU_BIN" 2>/dev/null | grep -q NEEDED; then
  echo "FATAL: --menu-bin has DT_NEEDED entries (dynamically linked, not static): $MENU_BIN" >&2
  exit 2
fi
if "${CROSS}readelf" -l "$MENU_BIN" 2>/dev/null | grep -q "^ *INTERP\b"; then
  echo "FATAL: --menu-bin has a PT_INTERP segment (dynamically linked, not static): $MENU_BIN" >&2
  exit 2
fi

WORK="${WORK:-$(mktemp -d /tmp/qemu-a133-initramfs.XXXXXX)}"
mkdir -p "$WORK"
# Stage under a FRESH mktemp dir, never a fixed "$WORK/root" -- --work accepts any
# caller-supplied path (e.g. a shared workspace, or even "/"), and a fixed subdir name
# combined with `rm -rf` on it is a destructive footgun (rm -rf "$WORK/root" against
# --work / would target /root). mktemp guarantees a unique, just-created directory, so
# there is nothing pre-existing to rm -rf in the first place.
ROOT="$(mktemp -d "$WORK/stage.XXXXXX")/root"
mkdir -p "$ROOT"/{bin,proc,sys,dev,opt/pocketforge/bin}

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

# Extract under a FRESH mktemp dir, never a fixed "$WORK/busybox-<ver>" name -- the same
# destructive-footgun class already fixed for ROOT above (--work accepts any
# caller-supplied path, and a fixed name immediately preceded by `rm -rf` can wipe
# unrelated content under a shared or malicious --work). mktemp guarantees a unique,
# just-created directory, so there is nothing pre-existing to rm -rf.
BB_STAGE="$(mktemp -d "$WORK/busybox-src.XXXXXX")"
tar -xjf "$TARBALL" -C "$BB_STAGE"
BB_SRC="$BB_STAGE/busybox-${BUSYBOX_VER}"

echo "=== cross-compiling busybox (static, aarch64) ==="
(
  cd "$BB_SRC"
  make defconfig >/dev/null
  # CONFIG_STATIC: static-link the applet binary (initramfs has no dynamic linker/libs).
  # CONFIG_TC off: the `tc` applet's networking/tc.c does not build against this cross
  # toolchain's (newer) kernel headers (undeclared TCA_CBQ_* / incomplete tc_cbq_* structs)
  # and `tc` is unused by this minimal boot-smoke init anyway.
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
for applet in sh mount umount mkdir cat ls echo sleep poweroff halt ps dmesg ln chmod mknod; do
  ln -sf busybox "$ROOT/bin/$applet"
done

cp "$MENU_BIN" "$ROOT/opt/pocketforge/bin/pocketforge-menu"
chmod 0755 "$ROOT/opt/pocketforge/bin/pocketforge-menu"

cat > "$ROOT/init" <<'INIT_EOF'
#!/bin/busybox sh
# Minimal PID 1 for the QEMU -M virt virtio boot smoke: mount proc/sys/dev, wait briefly
# for /dev/fb0 to appear (virtio-gpu's DRM fbdev probe is not synchronous with "Run /init
# as init process" -- it can lag a beat), then exec the menu so it runs as PID 1 (no
# supervisor needed for a one-shot smoke boot).
#
# NOTE: CONFIG_DEVTMPFS_MOUNT=y does NOT auto-mount devtmpfs onto an initramfs's /dev in
# practice on this kernel (confirmed empirically: /dev held only the kernel's static
# default_rootfs "console" node until devtmpfs was mounted explicitly here) -- mount it
# ourselves rather than relying on that config alone.
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t devtmpfs devtmpfs /dev
# On SOME machines (root-caused on the `-M pocketforge-a133` real-DT boot,
# tsp-mc9m.41.925.2.3: the DW-APB UART's permanent driver,
# drivers/tty/serial/8250/8250_dw.c, requires a resolvable clock rate and
# fails dw8250_probe() with no console/ttyS0 device ever created when its
# DT clock provider is a register-only stub with no real clk framework
# registration -- earlycon keeps working throughout because it talks to
# the UART directly, bypassing this driver entirely) neither /dev/console
# nor any /dev/ttyS* node ever comes to exist, so a menu binary's
# fprintf(stderr, ...) diagnostics (its "presented initial screen" marker
# included) would silently go nowhere even though it runs and renders
# fine. /dev/kmsg is the one output sink that is ALWAYS available
# regardless of which (if any) tty console driver bound -- writes to it
# land directly in the kernel ring buffer/dmesg, i.e. the same captured
# serial log, just with a leading kernel timestamp instead of a bare
# line (harmless: every marker this harness greps for is matched with a
# leading `.*`, so the extra prefix does not change any assertion).
/bin/busybox mknod -m 600 /dev/kmsg c 1 11 2>/dev/null
exec >/dev/kmsg 2>&1 </dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e /dev/fb0 ] && break
  /bin/busybox sleep 0.5
done
echo "qemu-a133-virt: initramfs up, execing pocketforge-menu"
exec /opt/pocketforge/bin/pocketforge-menu
INIT_EOF
chmod 0755 "$ROOT/init"

echo "=== assembling cpio ($OUT) ==="
mkdir -p "$(dirname "$OUT")"
( cd "$ROOT" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$OUT"
echo "OK out=$OUT size=$(stat -c%s "$OUT") sha256=$(sha256sum "$OUT" | cut -d' ' -f1)"
