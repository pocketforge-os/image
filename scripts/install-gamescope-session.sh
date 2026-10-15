#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo 'usage: install-gamescope-session.sh MODE ROOTFS' >&2
    exit 2
fi
mode=$1
rootfs=$2
src=$(cd "$(dirname "$0")/.." && pwd)/rootfs-overlay

case "${mode}" in
    not-shipped)
        exit 0
        ;;
    g1) ;;
    *)
        echo "invalid Gamescope session mode: ${mode}" >&2
        exit 2
        ;;
esac

files=(
    etc/systemd/system/pocketforge-gamescope-session.target
    etc/systemd/system/pocketforge-gamescope.service
    etc/systemd/system/pocketforge-session-publisher.service
    etc/systemd/system/pocketforge-gamescope-fallback.service
    etc/systemd/system/pocketforge-gamescope-resident.service
    etc/udev/rules.d/73-pocketforge-compositor-input.rules
    usr/lib/sysusers.d/pocketforge-gamescope.conf
)
for file in "${files[@]}"; do
    install -D -m 0644 "${src}/${file}" "${rootfs}/${file}"
done
install -D -m 0755 "${src}/usr/lib/pocketforge/pf-session-publish" \
    "${rootfs}/usr/lib/pocketforge/pf-session-publish"
install -D -m 0755 "${src}/usr/lib/pocketforge/pf-gamescope-kms-select" \
    "${rootfs}/usr/lib/pocketforge/pf-gamescope-kms-select"
install -D -m 0644 \
    "${src}/usr/share/pocketforge/runtime-path-producers-g1.json" \
    "${rootfs}/usr/share/pocketforge/runtime-path-producers.json"

# The session is never enabled or selected as the default. A user opts into a
# resident session by explicitly starting pocketforge-gamescope-resident.service.
if find "${rootfs}/etc/systemd/system" \( \
    -path '*.wants/pocketforge-gamescope-session.target' -o \
    -path '*.wants/pocketforge-gamescope-resident.service' \) \
    -print -quit | grep -q .; then
    echo 'refusing an enabled Gamescope session target' >&2
    exit 1
fi
