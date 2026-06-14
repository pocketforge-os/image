#!/usr/bin/env bash
# =============================================================================
# build-rootfs.sh — Build the PocketForge Debian rootfs (TrimUI Smart Pro)
# =============================================================================
# Creates a Debian 12 bookworm arm64 rootfs via mmdebstrap, installs all
# PocketForge-specific components (PowerVR DDK, kernel modules, firmware,
# libSDL3, configs), and assembles a deterministic ext4 filesystem image.
#
# Runs INSIDE the pocketforge/build container AS ROOT (mmdebstrap needs
# real chroot/mount privileges for cross-arch builds). The container
# provides the isolation boundary — this script never touches the host.
# Output files are chown'd to the caller's uid:gid at the end.
#
# Inputs via bind mounts:
#   /work/src       (ro)  — this image repo
#   /work/blobs     (ro)  — blobs repo checkout
#   /work/libsdl3   (ro)  — libSDL3-pocketforge.so.0 release artifact
#   /work/out       (rw)  — build output (userdata.ext4 written here)
#
# Usage:
#   build-rootfs.sh [--variant dev|release] [--owner UID:GID]
#
# Environment:
#   SOURCE_DATE_EPOCH  — reproducible timestamp (default: git head commit)
#
# bd: tsp-iuz.2.1
# =============================================================================
set -euo pipefail

# ---- configuration ----------------------------------------------------------
SRC_DIR="${SRC_DIR:-/work/src}"
BLOBS_DIR="${BLOBS_DIR:-/work/blobs}"
LIBSDL3_DIR="${LIBSDL3_DIR:-/work/libsdl3}"
OUT_DIR="${OUT_DIR:-/work/out}"
BOARD_DIR="${SRC_DIR}/boards/tsp"

VARIANT="dev"
OWNER_UID=""
OWNER_GID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --variant)  VARIANT="$2"; shift 2 ;;
        --owner)    OWNER_UID="${2%%:*}"; OWNER_GID="${2##*:}"; shift 2 ;;
        *) echo "build-rootfs.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ "$VARIANT" != "dev" ] && [ "$VARIANT" != "release" ]; then
    echo "FATAL: --variant must be 'dev' or 'release', got '${VARIANT}'" >&2
    exit 2
fi

# Reproducible timestamp
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    if git -C "${SRC_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        SOURCE_DATE_EPOCH="$(git -C "${SRC_DIR}" log -1 --format=%ct)"
    else
        SOURCE_DATE_EPOCH=1700000000
    fi
fi
export SOURCE_DATE_EPOCH

# Load committed UUIDs
# shellcheck source=boards/tsp/fs-uuids.env
source "${BOARD_DIR}/fs-uuids.env"

# Frozen snapshot mirror
SNAPSHOT_DATE="$(cat "${SRC_DIR}/snapshot-date.txt")"
SNAPSHOT_URL="http://snapshot.debian.org/archive/debian/${SNAPSHOT_DATE}/"

# Working directory
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "========================================================================"
echo "PocketForge rootfs builder"
echo "========================================================================"
echo "  variant:  ${VARIANT}"
echo "  epoch:    ${SOURCE_DATE_EPOCH}"
echo "  snapshot: ${SNAPSHOT_URL}"
echo "  blobs:    ${BLOBS_DIR}"
echo "  libsdl3:  ${LIBSDL3_DIR}"
echo "  out:      ${OUT_DIR}"
echo "========================================================================"

mkdir -p "${OUT_DIR}"

# ---- step 1: merge package list --------------------------------------------
echo ""
echo "=== Step 1/4: Merge package list ==="

PKG_FILE="${SRC_DIR}/rootfs-packages.txt"
PKG_DEV_FILE="${SRC_DIR}/rootfs-packages-dev.txt"

[ -f "${PKG_FILE}" ] || { echo "FATAL: ${PKG_FILE} not found" >&2; exit 1; }

# Strip comments and blank lines, merge into comma-delimited list
PKG_LIST="$(grep -v '^\s*#' "${PKG_FILE}" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')"

if [ "${VARIANT}" = "dev" ] && [ -f "${PKG_DEV_FILE}" ]; then
    DEV_PKGS="$(grep -v '^\s*#' "${PKG_DEV_FILE}" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')"
    PKG_LIST="${PKG_LIST},${DEV_PKGS}"
    echo "  variant=dev: added dev-only packages (${DEV_PKGS})"
fi

echo "  package list: ${PKG_LIST}"

# ---- step 2: verify prerequisites ------------------------------------------
echo ""
echo "=== Step 2/4: Verify prerequisites ==="

# Verify qemu-aarch64 binfmt is working (host kernel, propagated into container).
# The F flag on the host binfmt registration means the kernel handles dispatch
# transparently — /proc/sys/fs/binfmt_misc/ may not be visible inside the
# container, so we test actual arm64 execution instead of checking the proc entry.
if [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "  binfmt: qemu-aarch64 registered (proc entry visible)"
elif command -v qemu-aarch64-static >/dev/null 2>&1; then
    # Try running the baked-in arm64 busybox to verify binfmt dispatch works
    BB_ARM64="/opt/pocketforge/initrd-payload/busybox-arm64"
    if [ -f "${BB_ARM64}" ] && "${BB_ARM64}" true 2>/dev/null; then
        echo "  binfmt: arm64 execution verified (busybox-arm64 ran successfully)"
    else
        echo "  binfmt: qemu-aarch64-static present; assuming binfmt F-flag dispatch works"
    fi
else
    echo "FATAL: no arm64 binfmt support detected" >&2
    echo "  Install qemu-user-static + binfmt-support on the HOST and restart binfmt-support." >&2
    exit 1
fi

# Verify blobs exist
for f in \
    "${BLOBS_DIR}/tsp/22.102.54.38/lib/libEGL.so" \
    "${BLOBS_DIR}/tsp/22.102.54.38/modules/pvrsrvkm.ko" \
    "${BLOBS_DIR}/tsp/22.102.54.38/firmware/rgx.fw.22.102.54.38" \
    "${BLOBS_DIR}/tsp/kernel-4.9.191/modules/videobuf2-dma-contig.ko" \
    "${BLOBS_DIR}/tsp/kernel-4.9.191/firmware/fw_xr829.bin"; do
    [ -f "$f" ] || { echo "FATAL: required blob not found: $f" >&2; exit 1; }
done
echo "  blobs: spot-check passed"

# Verify libSDL3 artifact exists
LIBSDL3_SO="$(find "${LIBSDL3_DIR}" -name 'libSDL3-pocketforge.so*' -type f | head -1)"
[ -n "${LIBSDL3_SO}" ] || { echo "FATAL: libSDL3-pocketforge.so.* not found in ${LIBSDL3_DIR}" >&2; exit 1; }
echo "  libsdl3: ${LIBSDL3_SO}"

# ---- step 3: mmdebstrap + customize ----------------------------------------
echo ""
echo "=== Step 3/4: mmdebstrap rootfs build ==="

ROOTFS_TAR="${WORK}/rootfs.tar"

# The customize-hook script runs OUTSIDE the chroot — $1 is the rootfs path.
# This is critical: we can copy files from /work/blobs into the rootfs
# by targeting "$1/path/in/rootfs".
CUSTOMIZE_SCRIPT="${WORK}/customize-hook.sh"
cat > "${CUSTOMIZE_SCRIPT}" << 'CUSTOMIZE_EOF'
#!/bin/bash
set -euo pipefail
ROOTFS="$1"

echo "[customize] Starting PocketForge rootfs customization..."

# --- User + groups -----------------------------------------------------------
echo "[customize] Creating groups and gamer user..."
# audio=29 is vendor-pinned (stock ALSA nodes are root:audio 0660)
# video=44, plugdev=27 are Debian-conventional
# input=105, render=106 are our choice (no stock precedent)
# Note: some groups may already exist from Debian base packages (e.g. audio,
# video may come from base-passwd). We use --force for existing groups and
# --non-unique to allow re-specifying a GID if the group exists with a different one.
chroot "$ROOTFS" groupadd -g 29 audio   2>/dev/null || chroot "$ROOTFS" groupmod -g 29 audio   2>/dev/null || true
chroot "$ROOTFS" groupadd -g 44 video   2>/dev/null || chroot "$ROOTFS" groupmod -g 44 video   2>/dev/null || true
chroot "$ROOTFS" groupadd -g 27 plugdev 2>/dev/null || chroot "$ROOTFS" groupmod -g 27 plugdev 2>/dev/null || true
chroot "$ROOTFS" groupadd -g 105 input  2>/dev/null || true
chroot "$ROOTFS" groupadd -g 106 render 2>/dev/null || true
chroot "$ROOTFS" groupadd -g 1000 gamer 2>/dev/null || true
chroot "$ROOTFS" useradd -u 1000 -g 1000 -m -d /home/gamer -s /bin/bash gamer
chroot "$ROOTFS" usermod -aG audio,input,video,render,plugdev gamer
chroot "$ROOTFS" passwd -l gamer
echo "[customize] gamer user created: $(chroot "$ROOTFS" id gamer)"

# --- PowerVR DDK userspace install ------------------------------------------
echo "[customize] Installing PowerVR DDK userspace..."
install -d "${ROOTFS}/usr/lib/pvr-rogue"
for so in libEGL.so libGLESv2.so libGLES_CM.so libIMGegl.so \
          libsrv_um.so libusc.so libglslcompiler.so libpvrNULL_WSEGL.so; do
    install -m 0644 "/work/blobs/tsp/22.102.54.38/lib/${so}" "${ROOTFS}/usr/lib/pvr-rogue/${so}"
done
printf '/usr/lib/pvr-rogue\n' > "${ROOTFS}/etc/ld.so.conf.d/00-pvr.conf"
chroot "$ROOTFS" ldconfig
echo "[customize] PowerVR DDK: ldconfig done"

# Verify SONAME symlinks were created by checking the filesystem directly
# (ldconfig -p may not work reliably under qemu in all chroot configurations)
if [ ! -L "${ROOTFS}/usr/lib/pvr-rogue/libEGL.so.1" ]; then
    echo "FATAL: ldconfig did not create libEGL.so.1 symlink in /usr/lib/pvr-rogue/" >&2
    echo "  Contents of /usr/lib/pvr-rogue/:" >&2
    ls -la "${ROOTFS}/usr/lib/pvr-rogue/" >&2
    exit 1
fi
echo "[customize] PowerVR DDK: SONAME symlinks verified (libEGL.so.1 exists)"

# --- Kernel modules install --------------------------------------------------
echo "[customize] Installing kernel modules..."
install -d "${ROOTFS}/lib/modules/4.9.191"

# GPU modules (from DDK extraction)
install -m 0644 "/work/blobs/tsp/22.102.54.38/modules/pvrsrvkm.ko" "${ROOTFS}/lib/modules/4.9.191/"
install -m 0644 "/work/blobs/tsp/22.102.54.38/modules/dc_sunxi.ko" "${ROOTFS}/lib/modules/4.9.191/"

# DMA buffer plumbing (needed by dc_sunxi)
install -m 0644 "/work/blobs/tsp/kernel-4.9.191/modules/videobuf2-dma-contig.ko" "${ROOTFS}/lib/modules/4.9.191/"

# WiFi driver triplet
install -m 0644 "/work/blobs/tsp/kernel-4.9.191/modules/xradio_mac.ko" "${ROOTFS}/lib/modules/4.9.191/"
install -m 0644 "/work/blobs/tsp/kernel-4.9.191/modules/xradio_core.ko" "${ROOTFS}/lib/modules/4.9.191/"
install -m 0644 "/work/blobs/tsp/kernel-4.9.191/modules/xradio_wlan.ko" "${ROOTFS}/lib/modules/4.9.191/"

chroot "$ROOTFS" depmod 4.9.191
echo "[customize] Modules installed: $(ls "${ROOTFS}/lib/modules/4.9.191/"*.ko | wc -l) .ko files"

# Verify depmod produced output
if [ ! -s "${ROOTFS}/lib/modules/4.9.191/modules.dep" ]; then
    echo "FATAL: depmod 4.9.191 produced empty modules.dep" >&2
    exit 1
fi

# --- Firmware install --------------------------------------------------------
echo "[customize] Installing firmware..."
install -d "${ROOTFS}/lib/firmware"

# GPU firmware (both files required — missing rgx.sh.* causes firmware-load failures)
install -m 0644 "/work/blobs/tsp/22.102.54.38/firmware/rgx.fw.22.102.54.38" "${ROOTFS}/lib/firmware/"
install -m 0644 "/work/blobs/tsp/22.102.54.38/firmware/rgx.sh.22.102.54.38" "${ROOTFS}/lib/firmware/"

# WiFi firmware
install -m 0644 "/work/blobs/tsp/kernel-4.9.191/firmware/fw_xr829.bin" "${ROOTFS}/lib/firmware/"
install -m 0644 "/work/blobs/tsp/kernel-4.9.191/firmware/boot_xr829.bin" "${ROOTFS}/lib/firmware/"
install -m 0644 "/work/blobs/tsp/kernel-4.9.191/firmware/sdd_xr829.bin" "${ROOTFS}/lib/firmware/"

echo "[customize] Firmware: $(ls "${ROOTFS}/lib/firmware/" | wc -l) files"

# --- libSDL3 install ---------------------------------------------------------
echo "[customize] Installing libSDL3-pocketforge..."
install -d "${ROOTFS}/opt/pocketforge/lib"
# Find the libSDL3 artifact (may be named .so.0 or .so.0.5.0)
LIBSDL3_SRC="$(find /work/libsdl3 -name 'libSDL3-pocketforge.so*' -type f | head -1)"
install -m 0755 "${LIBSDL3_SRC}" "${ROOTFS}/opt/pocketforge/lib/libSDL3-pocketforge.so.0"

# --- Config files ------------------------------------------------------------
echo "[customize] Writing config files..."

# /etc/asound.conf — verbatim from stock (hardware-firmware-probes.md §12)
cat > "${ROOTFS}/etc/asound.conf" << 'ASOUND_EOF'
# A133
# audiocodec
# ac107

ctl.!default {
    type hw
    card audiocodec
}

pcm.!default {
    type asym
    playback.pcm "Playback"
    capture.pcm "CaptureAc107"
}

pcm.Playback {
    type plug
    slave.pcm {
        type softvol
        slave.pcm PlaybackDmix
        control {
            name "Soft Volume Master"
            card audiocodec
        }
        min_dB -51.0
        max_dB 0.0
        resolution 256
    }
}

pcm.PlaybackDmix {
    type plug
    slave.pcm {
        type dmix
        ipc_key 1111
        ipc_perm 0666
        slave {
            pcm "hw:audiocodec,0"
            format S16_LE
            rate 48000
            period_size 1024
            periods 4
        }
    }
}

pcm.Capture {
    type hw
    card audiocodec
}

pcm.CaptureAc107 {
    type hw
    card sndac10710036
}

pcm.CaptureDsnoop {
    type plug
    slave.pcm {
        type dsnoop
        ipc_key 1111
        ipc_perm 0666
        slave {
            pcm "hw:sndac10710036"
            format S16_LE
            rate 16000
            period_size 1024
            periods 4
        }
    }
}

pcm.PlaybackHpoutSpeaker {
    type hooks
    slave.pcm "PlaybackDmix"
    hooks.0 {
        type ctl_elems
        hook_args [
            {
                name "HpSpeaker Switch"
                optional true
                value 1
            }
        ]
    }
}

pcm.PlaybackLineoutSpeaker {
    type hooks
    slave.pcm "PlaybackDmix"
    hooks.0 {
        type ctl_elems
        hook_args [
            {
                name "LINEOUT Output Select"
                optional true
                value 1
            }
            {
                name "LINEOUT Switch"
                optional true
                value 1
            }
            {
                name "LINEOUT volume"
                optional true
                value 20
            }
        ]
    }
}

pcm.CaptureMic {
    type hooks
    slave.pcm "CaptureAc107"
    hooks.0 {
        type ctl_elems
        hook_args [
            {
                name "Channel 1 PGA Gain"
                optional true
                value 20
            }
            {
                name "Channel 2 PGA Gain"
                optional true
                value 20
            }
        ]
    }
}

pcm.CaptureReference {
    type hooks
    slave.pcm "Capture"
    hooks.0 {
        type ctl_elems
        hook_args [
            {
                name "ADCL Input MIC1 Boost Switch"
                optional true
                value 1
            }
            {
                name "ADCR Input MIC2 Boost Switch"
                optional true
                value 1
            }
            {
                name "MIC1 gain volume"
                optional true
                value 0
            }
            {
                name "MIC2 gain volume"
                optional true
                value 0
            }
        ]
    }
}

pcm.CaptureAec {
    type plug
    slave.pcm {
        type multi
        slaves {
            a { pcm "CaptureMic" channels 2 }
            b { pcm "CaptureReference" channels 2 }
        }
        bindings {
            0 { slave a channel 0 }
            1 { slave a channel 1 }
            2 { slave b channel 0 }
            3 { slave b channel 1 }
        }
    }
    ttable.0.0 1
    ttable.1.1 1
    ttable.2.2 1
    ttable.3.3 1
}
ASOUND_EOF

# /etc/pocketforge/display-env.sh — central display/env (build-int §12.4)
install -d "${ROOTFS}/etc/pocketforge"
cat > "${ROOTFS}/etc/pocketforge/display-env.sh" << 'DISPLAY_ENV_EOF'
# /etc/pocketforge/display-env.sh — central display/env for PocketForge apps
# Sourced by every app's launch script; owned by device-config.
export SDL3_DYNAMIC_API=/opt/pocketforge/lib/libSDL3-pocketforge.so.0
export LD_LIBRARY_PATH=/usr/lib/pvr-rogue${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
DISPLAY_ENV_EOF
chmod 0644 "${ROOTFS}/etc/pocketforge/display-env.sh"

# udev rules (build-int §12.3)
install -d "${ROOTFS}/etc/udev/rules.d"

cat > "${ROOTFS}/etc/udev/rules.d/60-pocketforge-dri.rules" << 'UDEV_DRI_EOF'
# GPU nodes for the kiosk user.
KERNEL=="card0",      SUBSYSTEM=="drm", MODE="0660", GROUP="video"
KERNEL=="renderD128", SUBSYSTEM=="drm", MODE="0660", GROUP="render"
UDEV_DRI_EOF

cat > "${ROOTFS}/etc/udev/rules.d/61-pocketforge-input.rules" << 'UDEV_INPUT_EOF'
# Input nodes (stock has these root-only).
SUBSYSTEM=="input", KERNEL=="event[0-9]*", MODE="0660", GROUP="input"
KERNEL=="js[0-9]*",                        MODE="0660", GROUP="input"
UDEV_INPUT_EOF

# --- WiFi + networking (bd: tsp-iuz.2.2) -------------------------------------
echo "[customize] Installing WiFi + networking configuration..."

# WiFi templater script (reads /boot/wifi.txt -> wpa_supplicant conf)
install -d "${ROOTFS}/usr/lib/pocketforge"
install -m 0755 "/work/src/rootfs-overlay/usr/lib/pocketforge/wifi-setup.sh" \
    "${ROOTFS}/usr/lib/pocketforge/wifi-setup.sh"

# WiFi templater systemd service (runs before wpa_supplicant@wlan0)
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pocketforge-wifi-setup.service" \
    "${ROOTFS}/etc/systemd/system/pocketforge-wifi-setup.service"

# Module autoload for the xradio WiFi triplet
install -d "${ROOTFS}/etc/modules-load.d"
install -m 0644 "/work/src/rootfs-overlay/etc/modules-load.d/pocketforge-wifi.conf" \
    "${ROOTFS}/etc/modules-load.d/pocketforge-wifi.conf"

# systemd-networkd DHCP configuration for wlan0
install -d "${ROOTFS}/etc/systemd/network"
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/network/20-wlan0.network" \
    "${ROOTFS}/etc/systemd/network/20-wlan0.network"

# /etc/fstab: mount the boot-resource FAT partition read-only at /boot.
# The kernel + initrd live inside boot.img (raw partition), not on /boot —
# /boot is free to serve as the user-editable config mount point (Raspberry
# Pi precedent). Read-only prevents accidental writes to the FAT partition.
# nofail: don't block boot if the partition is slow to appear or missing.
# x-systemd.device-timeout=10s: give udev 10s to enumerate the device node
# (default 90s would hit the 16s watchdog timeout).
cat >> "${ROOTFS}/etc/fstab" << 'FSTAB_EOF'
# Boot-resource FAT partition (user-editable WiFi config, boot logs)
LABEL=POCKETFORGE  /boot  vfat  ro,noatime,nofail,x-systemd.device-timeout=10s,fmask=0133,dmask=0022  0  0
FSTAB_EOF

# Hostname
echo "pocketforge" > "${ROOTFS}/etc/hostname"

# /etc/hosts — required for sudo and local name resolution
cat > "${ROOTFS}/etc/hosts" << 'HOSTS_EOF'
127.0.0.1	localhost
127.0.1.1	pocketforge
::1		localhost ip6-localhost ip6-loopback
HOSTS_EOF

# Enable services via symlinks (systemctl enable doesn't work under qemu
# in all chroot configurations — create the symlinks directly).
# wpa_supplicant@wlan0.service (template instance)
install -d "${ROOTFS}/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/wpa_supplicant@.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service"

# Mask the global wpa_supplicant.service — we use the template instance
# wpa_supplicant@wlan0.service instead. The global one fails without a
# config file and causes systemd to report "degraded" status.
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/wpa_supplicant.service"
echo "[customize] Masked global wpa_supplicant.service (template instance used instead)"

# pocketforge-wifi-setup.service
ln -sf /etc/systemd/system/pocketforge-wifi-setup.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/pocketforge-wifi-setup.service"

# systemd-networkd (DHCP for wlan0)
ln -sf /lib/systemd/system/systemd-networkd.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service"
# networkd needs its socket too
install -d "${ROOTFS}/etc/systemd/system/sockets.target.wants"
ln -sf /lib/systemd/system/systemd-networkd.socket \
    "${ROOTFS}/etc/systemd/system/sockets.target.wants/systemd-networkd.socket"

# systemd-timesyncd (NTP — prevents TLS certificate drift)
ln -sf /lib/systemd/system/systemd-timesyncd.service \
    "${ROOTFS}/etc/systemd/system/multi-user.target.wants/systemd-timesyncd.service"
# timesyncd also needs sysinit.target.wants for earliest possible start
install -d "${ROOTFS}/etc/systemd/system/sysinit.target.wants"
ln -sf /lib/systemd/system/systemd-timesyncd.service \
    "${ROOTFS}/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service"

# DNS: openresolv (not systemd-resolved) manages /etc/resolv.conf.
# systemd-networkd has built-in resolvconf integration — when it detects
# the `resolvconf` binary (provided by openresolv), it calls
# `resolvconf -a <iface>` with DHCP-provided nameservers. openresolv
# then generates /etc/resolv.conf from the contributed data. No resolved
# stub listener needed.
# Remove any stale resolv.conf left by mmdebstrap so openresolv owns it.
rm -f "${ROOTFS}/etc/resolv.conf"

echo "[customize] WiFi + networking: all config installed"

# --- Watchdog (bd: tsp-iuz.2.3) ----------------------------------------------
# The vendor kernel auto-starts sunxi-wdt at driver probe with a 16s timeout.
# Tell systemd PID 1 to take ownership and ping at half the interval (8s).
echo "[customize] Installing watchdog drop-in..."
install -d "${ROOTFS}/etc/systemd/system.conf.d"
install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system.conf.d/watchdog.conf" \
    "${ROOTFS}/etc/systemd/system.conf.d/watchdog.conf"
echo "[customize] Watchdog: systemd drop-in installed"

# --- Directory scaffolding ---------------------------------------------------
echo "[customize] Creating directory scaffolding..."
install -d "${ROOTFS}/etc/pocketforge/keys/release.d"
install -d "${ROOTFS}/opt/pocketforge/apps"
install -d "${ROOTFS}/var/lib/pocketforge/apps"

# --- Boot-time entropy + random-seed -----------------------------------------
# systemd-random-seed.service blocks boot on first boot (no saved seed, and
# getrandom() blocks until the entropy pool is initialized). haveged provides
# entropy from CPU timing jitter, but it starts too late to unblock the seed
# service on a first boot. Mask the service — haveged fills the pool instead.
ln -sf /dev/null "${ROOTFS}/etc/systemd/system/systemd-random-seed.service"
echo "[customize] Masked systemd-random-seed.service (haveged provides entropy)"

# --- Variant-conditional steps -----------------------------------------------
VARIANT="${POCKETFORGE_VARIANT:-dev}"
echo "[customize] Applying variant-specific config (variant=${VARIANT})..."

## -- Journald + coredump config (bd: tsp-iuz.2.8) ---
# Both variants get a journald drop-in; the file differs per variant.
install -d "${ROOTFS}/etc/systemd/journald.conf.d"
if [ "${VARIANT}" = "dev" ]; then
    # Dev: persistent journald (logs survive reboots for bug-report capture)
    install -m 0644 "/work/src/rootfs-overlay/etc/systemd/journald.conf.d/pocketforge-dev.conf" \
        "${ROOTFS}/etc/systemd/journald.conf.d/pocketforge.conf"
    echo "[customize] dev: journald Storage=persistent, SystemMaxUse=50M"

    # Dev: ensure /var/log/journal/ exists (systemd creates it on first boot
    # when Storage=persistent, but pre-creating it avoids a race with early
    # journal writes and lets us set group ownership at build time).
    install -d -m 2755 "${ROOTFS}/var/log/journal"
    echo "[customize] dev: /var/log/journal/ pre-created"

    # Dev: loosen /var/log/ permissions so gamer can read logs without sudo.
    # The default Debian mode is 0755/root:root which already allows read;
    # add group=adm explicitly and make gamer a member, matching the Debian
    # convention for log readers.
    chown root:adm "${ROOTFS}/var/log"
    chmod 0775 "${ROOTFS}/var/log"
    chroot "${ROOTFS}" usermod -a -G adm gamer
    echo "[customize] dev: /var/log/ group-readable (gamer added to adm group)"
else
    # Release: volatile journald (tmpfs only; defends against log-bomb DoS)
    install -m 0644 "/work/src/rootfs-overlay/etc/systemd/journald.conf.d/pocketforge-release.conf" \
        "${ROOTFS}/etc/systemd/journald.conf.d/pocketforge.conf"
    echo "[customize] release: journald Storage=volatile, RuntimeMaxUse=16M"
fi

if [ "${VARIANT}" = "dev" ]; then
    # Dev: passwordless sudo for gamer (make deploy writes root-owned paths)
    install -d "${ROOTFS}/etc/sudoers.d"
    printf 'gamer ALL=(ALL:ALL) NOPASSWD: ALL\n' > "${ROOTFS}/etc/sudoers.d/pocketforge-dev"
    chmod 0440 "${ROOTFS}/etc/sudoers.d/pocketforge-dev"
    echo "[customize] dev: sudoers drop-in installed"

    # Dev: serial-console debug user for bring-up diagnostics.
    # This user has a known password and can sudo to gamer or root.
    # MUST BE REMOVED BEFORE RELEASE — tracked by bead tsp-iuz.2.9.
    chroot "$ROOTFS" useradd -m -d /home/debug -s /bin/bash debug
    echo "debug:pocketforge" | chroot "$ROOTFS" chpasswd
    printf 'debug ALL=(ALL:ALL) NOPASSWD: ALL\n' >> "${ROOTFS}/etc/sudoers.d/pocketforge-dev"
    echo "[customize] dev: debug user created (password: pocketforge) — serial console access"

    # Dev: sshd hardening (PermitRootLogin no, PasswordAuthentication no)
    install -d "${ROOTFS}/etc/ssh/sshd_config.d"
    install -m 0644 "/work/src/rootfs-overlay/etc/ssh/sshd_config.d/pocketforge.conf" \
        "${ROOTFS}/etc/ssh/sshd_config.d/pocketforge.conf"
    echo "[customize] dev: sshd hardening drop-in installed"

    # Dev: multi-developer authorized_keys from device-config/dev/ssh/authorized_keys.d/*.pub
    # OpenSSH does not natively read from a directory — concatenate all .pub files
    # into a single authorized_keys at build time. One file per developer for clean
    # git blame and easy add/remove.
    KEYS_DIR="/work/src/device-config/dev/ssh/authorized_keys.d"
    install -d -o 1000 -g 1000 -m 0700 "${ROOTFS}/home/gamer/.ssh"
    KEY_COUNT=0
    : > "${ROOTFS}/home/gamer/.ssh/authorized_keys"
    for pub in "${KEYS_DIR}"/*.pub; do
        [ -f "${pub}" ] || continue
        cat "${pub}" >> "${ROOTFS}/home/gamer/.ssh/authorized_keys"
        KEY_COUNT=$((KEY_COUNT + 1))
        echo "[customize] dev: added SSH key $(basename "${pub}")"
    done
    chown 1000:1000 "${ROOTFS}/home/gamer/.ssh/authorized_keys"
    chmod 0600 "${ROOTFS}/home/gamer/.ssh/authorized_keys"
    echo "[customize] dev: authorized_keys installed (${KEY_COUNT} keys)"

    # Dev: enable sshd (Debian's openssh-server postinst typically enables it,
    # but be explicit for belt-and-suspenders clarity)
    chroot "${ROOTFS}" systemctl enable ssh.service
    echo "[customize] dev: ssh.service enabled"
elif [ "${VARIANT}" = "release" ]; then
    # Release: strip libSDL3 + future supervisor binary
    if command -v aarch64-none-linux-gnu-strip >/dev/null 2>&1; then
        aarch64-none-linux-gnu-strip --strip-unneeded \
            "${ROOTFS}/opt/pocketforge/lib/libSDL3-pocketforge.so.0" || true
        echo "[customize] release: libSDL3 stripped"
    elif command -v aarch64-linux-gnu-strip >/dev/null 2>&1; then
        aarch64-linux-gnu-strip --strip-unneeded \
            "${ROOTFS}/opt/pocketforge/lib/libSDL3-pocketforge.so.0" || true
        echo "[customize] release: libSDL3 stripped (gnu strip)"
    else
        echo "[customize] WARN: no aarch64 strip available; skipping"
    fi
fi

echo "[customize] Customization complete."
CUSTOMIZE_EOF
chmod +x "${CUSTOMIZE_SCRIPT}"

# Run mmdebstrap with the customize hook.
# --mode=root because this script runs as root inside the container
# (mmdebstrap needs chroot/mount for cross-arch; container provides isolation).
# --aptopt disables valid-until checking (snapshot mirrors have stale headers).
# SOURCE_DATE_EPOCH is inherited for reproducibility.
echo "  Running mmdebstrap (this may take several minutes under qemu...)..."
POCKETFORGE_VARIANT="${VARIANT}" \
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" \
mmdebstrap \
    --arch=arm64 \
    --variant=minbase \
    --mode=root \
    --aptopt='Acquire::Check-Valid-Until "false"' \
    --aptopt='APT::Sandbox::User "root"' \
    --include="${PKG_LIST}" \
    --customize-hook="env POCKETFORGE_VARIANT=${VARIANT} ${CUSTOMIZE_SCRIPT} \"\$1\"" \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --dpkgopt='path-include=/usr/share/doc/*/copyright' \
    bookworm \
    "${ROOTFS_TAR}" \
    "${SNAPSHOT_URL}"

ROOTFS_SIZE="$(stat -c%s "${ROOTFS_TAR}")"
echo "  rootfs.tar: ${ROOTFS_SIZE} bytes ($(( ROOTFS_SIZE / 1024 / 1024 )) MiB)"

# ---- step 4: deterministic ext4 assembly -----------------------------------
echo ""
echo "=== Step 4/4: Deterministic ext4 assembly ==="

ROOTFS_EXTRACTED="${WORK}/rootfs-extracted"
mkdir -p "${ROOTFS_EXTRACTED}"

# Extract the rootfs tar
tar -xf "${ROOTFS_TAR}" -C "${ROOTFS_EXTRACTED}"

# Report rootfs size
ROOTFS_DU="$(du -sm "${ROOTFS_EXTRACTED}" | cut -f1)"
echo "  rootfs extracted: ${ROOTFS_DU} MiB"

# Size the ext4 image: rootfs size + 25% headroom, minimum 1024 MiB
EXT4_SIZE_MB=1024
if [ "${ROOTFS_DU}" -gt 768 ]; then
    EXT4_SIZE_MB=$(( ROOTFS_DU * 125 / 100 ))
    echo "  rootfs exceeds 768 MiB — auto-sizing ext4 to ${EXT4_SIZE_MB} MiB"
fi
EXT4_SIZE_BLOCKS=$(( EXT4_SIZE_MB * 1024 ))   # 1K blocks for mke2fs
echo "  ext4 target: ${EXT4_SIZE_MB} MiB (${EXT4_SIZE_BLOCKS} x 1K blocks)"

# Pre-stage: clamp mtimes for reproducibility (Reproducible-Builds recipe).
# We operate on the extracted directory tree directly — mke2fs -d <directory>
# is more reliable than -d <tar> (avoids locale-dependent tar parsing issues).
echo "  Clamping mtimes to SOURCE_DATE_EPOCH for reproducibility..."
find "${ROOTFS_EXTRACTED}" -depth -print0 | \
    xargs -0 touch --no-dereference --date="@${SOURCE_DATE_EPOCH}" 2>/dev/null || true

# Build the ext4 from the directory with committed, stable UUIDs.
# The -d <directory> form gives deterministic inode order when the directory
# entries are already sorted (the mmdebstrap tar is sorted by default).
USERDATA_EXT4="${OUT_DIR}/userdata.ext4"
mke2fs -t ext4 \
    -d "${ROOTFS_EXTRACTED}" \
    -E "hash_seed=${USERDATA_HASH_SEED}" \
    -U "${USERDATA_FS_UUID}" \
    -L "POCKETFORGE_DATA" \
    -O "^metadata_csum" \
    -m 0 \
    "${USERDATA_EXT4}" ${EXT4_SIZE_BLOCKS}

EXT4_SIZE="$(stat -c%s "${USERDATA_EXT4}")"
EXT4_SHA="$(sha256sum "${USERDATA_EXT4}" | cut -d' ' -f1)"

echo ""
echo "========================================================================"
echo "ROOTFS BUILD COMPLETE"
echo "========================================================================"
echo "  ${USERDATA_EXT4}"
echo "  size:      ${EXT4_SIZE} bytes ($(( EXT4_SIZE / 1024 / 1024 )) MiB)"
echo "  sha256:    ${EXT4_SHA}"
echo "  variant:   ${VARIANT}"
echo "  label:     POCKETFORGE_DATA"
echo "  fs-uuid:   ${USERDATA_FS_UUID}"
echo "  hash-seed: ${USERDATA_HASH_SEED}"
echo ""

# Chown output to the caller's uid:gid if specified
if [ -n "${OWNER_UID}" ] && [ -n "${OWNER_GID}" ]; then
    chown "${OWNER_UID}:${OWNER_GID}" "${USERDATA_EXT4}"
    echo "  chown: ${OWNER_UID}:${OWNER_GID}"
fi

# Write SHA manifest
echo "${EXT4_SHA}  userdata.ext4" > "${OUT_DIR}/userdata.ext4.sha256"
if [ -n "${OWNER_UID}" ] && [ -n "${OWNER_GID}" ]; then
    chown "${OWNER_UID}:${OWNER_GID}" "${OUT_DIR}/userdata.ext4.sha256"
fi
