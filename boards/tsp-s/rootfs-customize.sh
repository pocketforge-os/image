#!/bin/bash
# =============================================================================
# boards/tsp-s/rootfs-customize.sh — A523 (tsp-s) mmdebstrap customize hook
# =============================================================================
# Runs OUTSIDE the chroot as root ($1 = rootfs path), invoked by
# scripts/build-rootfs-a523.sh via mmdebstrap --customize-hook.
#
# Deliberately LEANER than the A133 hook: NO PowerVR DDK, NO libSDL3, NO ALSA,
# NO xradio — the A523 GPU (tsp-vuo.2) / WiFi driver (tsp-vuo.3) are separate
# beads. This installs the SoC-agnostic substrate: owned kernel modules,
# sshd + the rsync iteration loop, the crun container + per-app cgroup slice
# (the headline of tsp-vuo.4), and the wifi.txt-on-FAT + [fetch] plumbing.
#
# NOTE: deliberately NO systemd template (foo<at>inst.service) units — two plain
# services instead. (The build harness redacts the email-like name@inst.service
# token, corrupting template names; plain names sidestep it.)
#
# Env: POCKETFORGE_VARIANT=dev|release ; bind mounts: /work/src (image repo),
#      /work/modules (kernel modules_install staging: lib/modules/<KREL>).
# =============================================================================
set -euo pipefail
ROOTFS="$1"
SRC=/work/src
MODSTAGE=/work/modules
OVERLAY="${SRC}/boards/tsp-s/overlay"
VARIANT="${POCKETFORGE_VARIANT:-dev}"
KREL="${KREL:-5.15.154}"

echo "[customize-a523] start (variant=${VARIANT}, KREL=${KREL})"

# --- users + groups ----------------------------------------------------------
chroot "$ROOTFS" groupadd -g 44 video   2>/dev/null || true
chroot "$ROOTFS" groupadd -g 105 input  2>/dev/null || true
chroot "$ROOTFS" groupadd -g 1000 gamer 2>/dev/null || true
chroot "$ROOTFS" useradd -u 1000 -g 1000 -m -d /home/gamer -s /bin/bash gamer
chroot "$ROOTFS" usermod -aG video,input gamer
chroot "$ROOTFS" passwd -l gamer
echo "[customize-a523] gamer: $(chroot "$ROOTFS" id gamer)"

# --- owned kernel modules ----------------------------------------------------
echo "[customize-a523] installing kernel modules ${KREL}..."
if [ -d "${MODSTAGE}/lib/modules/${KREL}" ]; then
    install -d "${ROOTFS}/lib/modules"
    cp -a "${MODSTAGE}/lib/modules/${KREL}" "${ROOTFS}/lib/modules/${KREL}"
    # The build container lacks depmod; generate modules.dep in the rootfs chroot.
    chroot "$ROOTFS" depmod "${KREL}"
    echo "[customize-a523] modules: $(find "${ROOTFS}/lib/modules/${KREL}" -name '*.ko' | wc -l) .ko, depmod ok"
else
    echo "[customize-a523] WARN: no module staging at ${MODSTAGE}/lib/modules/${KREL} — rootfs ships without /lib/modules"
fi

# --- hostname + hosts + fstab ------------------------------------------------
echo "pocketforge-s" > "${ROOTFS}/etc/hostname"
cat > "${ROOTFS}/etc/hosts" <<'EOF'
127.0.0.1	localhost
127.0.1.1	pocketforge-s
::1		localhost ip6-localhost ip6-loopback
EOF
# /boot = the FAT boot partition (user-editable wifi.txt + boot logs), ro.
cat >> "${ROOTFS}/etc/fstab" <<'EOF'
LABEL=POCKETFORGE  /boot  vfat  ro,noatime,nofail,x-systemd.device-timeout=10s,fmask=0133,dmask=0022  0  0
EOF

# --- overlay (systemd units, container slice/bundles, scripts) ---------------
echo "[customize-a523] applying overlay tree..."
cp -a "${OVERLAY}/." "${ROOTFS}/"
chmod 0755 "${ROOTFS}/usr/lib/pocketforge/container-memtest.sh"

# --- container demo rootfs (static busybox; shared by hello + memtest) -------
echo "[customize-a523] building OCI demo container rootfs (static busybox)..."
CROOT="${ROOTFS}/usr/lib/pocketforge/containers/_rootfs"
install -d "${CROOT}/bin" "${CROOT}/proc" "${CROOT}/dev" "${CROOT}/tmp" "${CROOT}/etc"
BBOX=""
for cand in "${ROOTFS}/bin/busybox" "${ROOTFS}/usr/bin/busybox"; do
    [ -x "$cand" ] && { BBOX="$cand"; break; }
done
[ -n "$BBOX" ] || { echo "FATAL: static busybox not found in rootfs (need busybox-static)"; exit 1; }
install -m 0755 "$BBOX" "${CROOT}/bin/busybox"
for ap in sh echo sleep cat ls cut grep tr head; do ln -sf busybox "${CROOT}/bin/${ap}"; done
printf 'root:x:0:0:root:/:/bin/sh\n' > "${CROOT}/etc/passwd"

# --- wifi.txt-on-FAT plumbing (driver-agnostic; AIC8800 driver is tsp-vuo.3) -
echo "[customize-a523] installing wifi.txt plumbing (smoke; wpa stack gated on tsp-vuo.3)..."
install -d "${ROOTFS}/usr/lib/pocketforge"
install -m 0755 "${SRC}/rootfs-overlay/usr/lib/pocketforge/wifi-setup.sh" \
    "${ROOTFS}/usr/lib/pocketforge/wifi-setup.sh"
cat > "${ROOTFS}/etc/systemd/system/pocketforge-wifi-setup.service" <<'EOF'
[Unit]
Description=PocketForge WiFi config from /boot/wifi.txt (A523 smoke; no driver yet)
After=local-fs.target
ConditionPathExists=/boot/wifi.txt

[Service]
Type=oneshot
ExecStart=/usr/lib/pocketforge/wifi-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# --- signed [fetch] contract (re-targeted; no A523 blobs until GPU/WiFi land) -
echo "[customize-a523] wiring signed [fetch] contract (no A523 blobs yet)..."
install -d "${ROOTFS}/usr/lib/pocketforge/fetch"
install -m 0755 "${SRC}/scripts/ipfs-fetch.sh" "${ROOTFS}/usr/lib/pocketforge/fetch/ipfs-fetch.sh"
cat > "${ROOTFS}/usr/lib/pocketforge/fetch/README" <<'EOF'
PocketForge signed [fetch] contract — re-targeted to the A523 (tsp-vuo.4).
The minisign+IPFS+SHA-256 manifest verifier (ipfs-fetch.sh) is SoC-agnostic and
carries over unchanged from the A133. The A523 has NO owned/closed blobs to fetch
yet (the GPU userland is tsp-vuo.2, the AIC8800 WiFi firmware is tsp-vuo.3); when
they land they get an `s/tsp-s/<group>/BLOBS.SHA256` entry in vendor-manifest and
travel this same signed path. Until then this is the wired-but-empty contract.
EOF

# --- hardware watchdog: direct keepalive daemon --------------------------------
# The A523 sunxi-wdt (2050000.watchdog, 16s, cannot be stopped) auto-arms at
# probe. systemd's native RuntimeWatchdog (RuntimeWatchdogSec=16 — the proven
# A133 fix, tsp-iuz.2.3) did NOT engage on the A523 5.15 kernel: no "Using
# hardware watchdog" log and the device reset ~16s after reaching login on the
# first tsp-vuo.4 boot. So we feed /dev/watchdog0 directly via a keepalive
# service (from the overlay), started in sysinit before the reset window.
# [follow-up: root-cause why systemd RuntimeWatchdog won't engage on the A523
#  and switch back to it for proper health-gated watchdog handling.]
echo "[customize-a523] enabling hardware watchdog keepalive..."
chmod 0755 "${ROOTFS}/usr/lib/pocketforge/watchdog-keepalive.sh"
install -d "${ROOTFS}/etc/systemd/system/sysinit.target.wants"
ln -sf /etc/systemd/system/pocketforge-watchdog-keepalive.service \
    "${ROOTFS}/etc/systemd/system/sysinit.target.wants/pocketforge-watchdog-keepalive.service"

# --- systemd service enablement (direct symlinks; reliable under qemu) --------
echo "[customize-a523] enabling services..."
SYSD="${ROOTFS}/etc/systemd/system"
install -d "${SYSD}/multi-user.target.wants" "${SYSD}/slices.target.wants"
# the per-app container slice
ln -sf /etc/systemd/system/pocketforge-apps.slice \
    "${SYSD}/slices.target.wants/pocketforge-apps.slice"
# steady-state: run the 'hello' container under the slice at boot, so first-boot
# serial SHOWS a crun container alive under an enforced cgroup cap. (memtest is
# NOT enabled at boot — it OOMs by design; container-memtest.sh starts it.)
ln -sf /etc/systemd/system/pocketforge-hello-container.service \
    "${SYSD}/multi-user.target.wants/pocketforge-hello-container.service"
ln -sf /etc/systemd/system/pocketforge-wifi-setup.service \
    "${SYSD}/multi-user.target.wants/pocketforge-wifi-setup.service"
ln -sf /lib/systemd/system/systemd-timesyncd.service \
    "${SYSD}/multi-user.target.wants/systemd-timesyncd.service"
# mask the random-seed blocker (haveged fills the pool) — mirrors A133.
ln -sf /dev/null "${SYSD}/systemd-random-seed.service"

# --- directory scaffolding ---------------------------------------------------
install -d "${ROOTFS}/opt/pocketforge/apps" "${ROOTFS}/var/lib/pocketforge"

# --- variant: dev (sshd + rsync loop + serial debug user) --------------------
if [ "${VARIANT}" = "dev" ]; then
    echo "[customize-a523] dev: sshd + rsync iteration loop + debug user..."
    # passwordless sudo for gamer (make deploy / rsync writes root paths)
    install -d "${ROOTFS}/etc/sudoers.d"
    printf 'gamer ALL=(ALL:ALL) NOPASSWD: ALL\n' > "${ROOTFS}/etc/sudoers.d/pocketforge-dev"
    chmod 0440 "${ROOTFS}/etc/sudoers.d/pocketforge-dev"

    # serial-console debug user (known pw; remove before release — mirrors A133)
    chroot "$ROOTFS" useradd -m -d /home/debug -s /bin/bash debug
    echo "debug:pocketforge" | chroot "$ROOTFS" chpasswd
    printf 'debug ALL=(ALL:ALL) NOPASSWD: ALL\n' >> "${ROOTFS}/etc/sudoers.d/pocketforge-dev"

    # sshd hardening drop-in (reuse the A133 one — PermitRootLogin no, no pw auth)
    install -d "${ROOTFS}/etc/ssh/sshd_config.d"
    install -m 0644 "${SRC}/rootfs-overlay/etc/ssh/sshd_config.d/pocketforge.conf" \
        "${ROOTFS}/etc/ssh/sshd_config.d/pocketforge.conf"

    # developer authorized_keys (the rsync loop needs key SSH) — same key dir as A133
    KEYS_DIR="${SRC}/device-config/dev/ssh/authorized_keys.d"
    install -d -o 1000 -g 1000 -m 0700 "${ROOTFS}/home/gamer/.ssh"
    : > "${ROOTFS}/home/gamer/.ssh/authorized_keys"
    KC=0
    for pub in "${KEYS_DIR}"/*.pub; do
        [ -f "$pub" ] || continue
        cat "$pub" >> "${ROOTFS}/home/gamer/.ssh/authorized_keys"; KC=$((KC+1))
    done
    chown 1000:1000 "${ROOTFS}/home/gamer/.ssh/authorized_keys"
    chmod 0600 "${ROOTFS}/home/gamer/.ssh/authorized_keys"
    install -d -m 0700 "${ROOTFS}/home/debug/.ssh"
    install -m 0600 "${ROOTFS}/home/gamer/.ssh/authorized_keys" "${ROOTFS}/home/debug/.ssh/authorized_keys"
    chroot "$ROOTFS" chown -R debug:debug /home/debug/.ssh
    chroot "$ROOTFS" systemctl enable ssh.service 2>/dev/null || \
        ln -sf /lib/systemd/system/ssh.service "${SYSD}/multi-user.target.wants/ssh.service"
    echo "[customize-a523] dev: ${KC} ssh key(s) installed; ssh.service enabled"
fi

echo "[customize-a523] complete."
