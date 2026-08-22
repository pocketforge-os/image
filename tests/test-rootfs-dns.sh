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

# The build guard must reject the original regression: no /etc/resolv.conf.
rm "${SCRATCH}/etc/resolv.conf"
if "${SRC_DIR}/scripts/verify-rootfs-dns.sh" "${SCRATCH}" \
    >"${SCRATCH}/expected-failure.log" 2>&1; then
    echo "FAIL: verifier accepted a rootfs without /etc/resolv.conf" >&2
    exit 1
fi
grep -F '/etc/resolv.conf is not a symlink' "${SCRATCH}/expected-failure.log"
echo "rootfs DNS self-check regression: PASS"
