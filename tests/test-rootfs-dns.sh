#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

mkdir -p \
    "${SCRATCH}/lib/systemd/system" \
    "${SCRATCH}/etc/systemd/network" \
    "${SCRATCH}/etc/systemd/resolved.conf.d" \
    "${SCRATCH}/etc/systemd/system/sysinit.target.wants"
ln -s ../run/systemd/resolve/stub-resolv.conf "${SCRATCH}/etc/resolv.conf"
ln -s /lib/systemd/system/systemd-resolved.service \
    "${SCRATCH}/etc/systemd/system/sysinit.target.wants/systemd-resolved.service"
: > "${SCRATCH}/lib/systemd/system/systemd-resolved.service"
printf '[Network]\nDHCP=yes\n' > "${SCRATCH}/etc/systemd/network/20-wlan0.network"
printf '[Resolve]\nFallbackDNS=1.1.1.1\n' > \
    "${SCRATCH}/etc/systemd/resolved.conf.d/pocketforge.conf"

"${SRC_DIR}/scripts/verify-rootfs-dns.sh" "${SCRATCH}"

# Model the package-created backup from the real rootfs producer. The final
# rootfs gate must reject build-network resolver state even when the active
# resolver is the correct systemd-resolved stub.
printf 'nameserver 192.168.151.1\n' > \
    "${SCRATCH}/etc/.resolv.conf.systemd-resolved.bak"
if "${SRC_DIR}/scripts/verify-rootfs-dns.sh" "${SCRATCH}" \
    >"${SCRATCH}/expected-backup-failure.log" 2>&1; then
    grep -Fqx 'nameserver 192.168.151.1' \
        "${SCRATCH}/etc/.resolv.conf.systemd-resolved.bak"
    echo "FAIL: final rootfs DNS gate accepted and retained the build resolver backup" >&2
    exit 1
fi
grep -F '/etc/.resolv.conf.systemd-resolved.bak is present' \
    "${SCRATCH}/expected-backup-failure.log"
rm "${SCRATCH}/etc/.resolv.conf.systemd-resolved.bak"

# The build guard must reject the original regression: no /etc/resolv.conf.
rm "${SCRATCH}/etc/resolv.conf"
if "${SRC_DIR}/scripts/verify-rootfs-dns.sh" "${SCRATCH}" \
    >"${SCRATCH}/expected-failure.log" 2>&1; then
    echo "FAIL: verifier accepted a rootfs without /etc/resolv.conf" >&2
    exit 1
fi
grep -F '/etc/resolv.conf is not a symlink' "${SCRATCH}/expected-failure.log"
echo "rootfs DNS self-check regression: PASS"
