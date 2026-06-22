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

# --- AIC8800D80 WiFi: driver autoload + firmware + wpa/DHCP (tsp-vuo.3) -------
# The aic8800 driver is SOURCE-BUILT in our owned kernel fork
# (pocketforge-os/kernel-tsp-a523 :: bsp/drivers/net/wireless/aic8800, the
# AICSemi aic-bsp snapshot rev 241c091M / 20231222 / 6.4.3.0, CONFIG_AIC8800_
# WLAN_SUPPORT=m) — the .ko's arrive via the modules-staging copy above. The
# FIRMWARE is a closed redistributable blob (AICSemi), provenance-matched to
# that exact driver rev from radxa-pkg/aic8800 src/SDIO/driver_fw/fw/aic8800D80/,
# staged as a build input (/work/firmware, NOT in image git). [debt: move the
# firmware onto the IPFS/minisign/vendor-manifest signed path like the A133
# PowerVR blobs — owned-substrate-blob provenance.]
echo "[customize-a523] installing AIC8800D80 WiFi (driver autoload + firmware + wpa/DHCP)..."

# (1) module autoload at boot: bsp patches the chip bootrom + loads firmware;
#     fdrv brings up the wlan0 fullmac netdev.
install -d "${ROOTFS}/etc/modules-load.d"
cat > "${ROOTFS}/etc/modules-load.d/pocketforge-wifi.conf" <<'EOF'
# AIC8800D80 SDIO combo radio (TrimUI Smart Pro S / A523).
# Source-built in pocketforge-os/kernel-tsp-a523 (aic-bsp rev 241c091M/20231222).
# aic8800_bsp first (bootrom patch + firmware download), then aic8800_fdrv (wlan0).
aic8800_bsp
aic8800_fdrv
EOF

# (2) firmware blob (closed; provenance recorded in build-a523-image.sh + bead).
FWSTAGE="${FWSTAGE:-/work/firmware}"
if [ -d "${FWSTAGE}/aic8800d80" ]; then
    install -d "${ROOTFS}/lib/firmware/aic8800d80"
    cp -a "${FWSTAGE}/aic8800d80/." "${ROOTFS}/lib/firmware/aic8800d80/"
    echo "[customize-a523] aic8800d80 firmware: $(find "${ROOTFS}/lib/firmware/aic8800d80" -type f | wc -l) file(s)"
else
    echo "[customize-a523] WARN: no firmware at ${FWSTAGE}/aic8800d80 — wlan0 will NOT associate"
fi

# (3) wifi.txt-on-FAT -> wpa_supplicant conf (driver-agnostic; reuses A133 script).
install -d "${ROOTFS}/usr/lib/pocketforge"
install -m 0755 "${SRC}/rootfs-overlay/usr/lib/pocketforge/wifi-setup.sh" \
    "${ROOTFS}/usr/lib/pocketforge/wifi-setup.sh"
cat > "${ROOTFS}/etc/systemd/system/pocketforge-wifi-setup.service" <<'EOF'
[Unit]
Description=PocketForge WiFi config from /boot/wifi.txt
After=local-fs.target
ConditionPathExists=/boot/wifi.txt

[Service]
Type=oneshot
ExecStart=/usr/lib/pocketforge/wifi-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# (4) wpa_supplicant for wlan0. PLAIN unit name (NOT the wpa_supplicant<at>wlan0
#     template) — the build harness redacts name<at>inst.service tokens. The
#     aic8800_fdrv is a fullmac cfg80211 driver, so the nl80211 backend applies.
cat > "${ROOTFS}/etc/systemd/system/pocketforge-wpa-wlan0.service" <<'EOF'
[Unit]
Description=PocketForge wpa_supplicant for wlan0 (AIC8800D80)
After=pocketforge-wifi-setup.service sys-subsystem-net-devices-wlan0.device
Wants=pocketforge-wifi-setup.service
ConditionPathExists=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf

[Service]
Type=simple
ExecStart=/usr/sbin/wpa_supplicant -c /etc/wpa_supplicant/wpa_supplicant-wlan0.conf -i wlan0 -D nl80211
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# (5) systemd-networkd DHCP for wlan0 (reuses the SoC-agnostic A133 .network).
install -d "${ROOTFS}/etc/systemd/network"
install -m 0644 "${SRC}/rootfs-overlay/etc/systemd/network/20-wlan0.network" \
    "${ROOTFS}/etc/systemd/network/20-wlan0.network"

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

# --- hardware watchdog: systemd-native RuntimeWatchdog (proper owner) ----------
# The A523 sunxi-wdt (2050000.watchdog, 16s) auto-arms at probe and cannot be
# stopped, so PID1 must own + feed it. RuntimeWatchdogSec=16 makes systemd open
# the device, program the timeout, and ping at half-interval (the initrd pings
# once before switch_root so systemd has the window). This is the same proven
# A133 mechanism (tsp-iuz.2.3); on the A523 we ALSO pin WatchdogDevice explicitly
# to /dev/watchdog0 (both /dev/watchdog and /dev/watchdog0 exist). Verified live
# on hardware (tsp-vuo.4): systemd opens 'sunxi-wdt' /dev/watchdog0 + feeds it.
echo "[customize-a523] installing systemd RuntimeWatchdog drop-in..."
install -d "${ROOTFS}/etc/systemd/system.conf.d"
printf '[Manager]\nRuntimeWatchdogSec=16\nWatchdogDevice=/dev/watchdog0\n' \
    > "${ROOTFS}/etc/systemd/system.conf.d/watchdog.conf"

# Safety net (NOT a shortcut): a keepalive that YIELDS to systemd. It opens
# /dev/watchdog0 only if systemd's open hasn't already claimed it (EBUSY ->
# exit 0, "systemd owns it"); it only actually feeds the dog if systemd's early
# RuntimeWatchdog open ever races/fails on this board, preventing a reset loop.
# When systemd engages (the normal case) this no-ops. bd: tsp-vuo.4.
echo "[customize-a523] installing watchdog keepalive safety net (yields to systemd)..."
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
# AIC8800 WiFi: wpa_supplicant (plain unit) + systemd-networkd (DHCP for wlan0)
ln -sf /etc/systemd/system/pocketforge-wpa-wlan0.service \
    "${SYSD}/multi-user.target.wants/pocketforge-wpa-wlan0.service"
ln -sf /lib/systemd/system/systemd-networkd.service \
    "${SYSD}/multi-user.target.wants/systemd-networkd.service"
install -d "${SYSD}/sockets.target.wants"
ln -sf /lib/systemd/system/systemd-networkd.socket \
    "${SYSD}/sockets.target.wants/systemd-networkd.socket"
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
    chmod 0600 "${ROOTFS}/home/gamer/.ssh/authorized_keys"
    # Ensure gamer OWNS its home + .ssh. The host-side numeric `install -o 1000`/
    # `chown 1000:1000` above landed as root:root in practice, so sshd StrictModes
    # rejected the key (gamer key-auth failed -> rsync loop blocked). chroot chown
    # BY NAME is reliable (mirrors the debug user below). bd: tsp-vuo.4.
    chroot "$ROOTFS" chown -R gamer:gamer /home/gamer
    install -d -m 0700 "${ROOTFS}/home/debug/.ssh"
    install -m 0600 "${ROOTFS}/home/gamer/.ssh/authorized_keys" "${ROOTFS}/home/debug/.ssh/authorized_keys"
    chroot "$ROOTFS" chown -R debug:debug /home/debug/.ssh
    chroot "$ROOTFS" systemctl enable ssh.service 2>/dev/null || \
        ln -sf /lib/systemd/system/ssh.service "${SYSD}/multi-user.target.wants/ssh.service"
    echo "[customize-a523] dev: ${KC} ssh key(s) installed; ssh.service enabled"
fi

echo "[customize-a523] complete."
