#!/usr/bin/env bash
# Verify that an extracted rootfs carries the networkd -> resolved -> libc path.
set -euo pipefail

ROOTFS="${1:?usage: verify-rootfs-dns.sh ROOTFS}"
RESOLV_CONF="${ROOTFS}/etc/resolv.conf"
RESOLVED_WANT="${ROOTFS}/etc/systemd/system/sysinit.target.wants/systemd-resolved.service"
RESOLVED_CONF="${ROOTFS}/etc/systemd/resolved.conf.d/pocketforge.conf"
NETWORK_CONF="${ROOTFS}/etc/systemd/network/20-wlan0.network"

[ -L "${RESOLV_CONF}" ] || { echo "FATAL: rootfs DNS: /etc/resolv.conf is not a symlink" >&2; exit 1; }
[ "$(readlink "${RESOLV_CONF}")" = "../run/systemd/resolve/stub-resolv.conf" ] \
    || { echo "FATAL: rootfs DNS: /etc/resolv.conf does not target systemd-resolved's stub" >&2; exit 1; }
[ -f "${ROOTFS}/lib/systemd/system/systemd-resolved.service" ] \
    || { echo "FATAL: rootfs DNS: systemd-resolved package is missing" >&2; exit 1; }
[ -L "${RESOLVED_WANT}" ] || { echo "FATAL: rootfs DNS: systemd-resolved is not enabled" >&2; exit 1; }
[ -f "${RESOLVED_CONF}" ] || { echo "FATAL: rootfs DNS: resolved fallback configuration is missing" >&2; exit 1; }
grep -Eq '^FallbackDNS=[^[:space:]]' "${RESOLVED_CONF}" \
    || { echo "FATAL: rootfs DNS: resolved fallback DNS is empty" >&2; exit 1; }
if ! { [ -f "${NETWORK_CONF}" ] && grep -Eq '^DHCP=(yes|ipv4)$' "${NETWORK_CONF}"; }; then
    echo "FATAL: rootfs DNS: wlan0 is not configured for networkd DHCP" >&2
    exit 1
fi

echo "  rootfs DNS self-check: networkd DHCP -> systemd-resolved -> /etc/resolv.conf"
