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
    etc/udev/rules.d/73-pocketforge-compositor-input.rules
    usr/lib/sysusers.d/pocketforge-gamescope.conf
    usr/share/pocketforge/runtime-path-producers.json
)
for file in "${files[@]}"; do
    install -D -m 0644 "${src}/${file}" "${rootfs}/${file}"
done
install -D -m 0755 "${src}/usr/lib/pocketforge/pf-session-publish" \
    "${rootfs}/usr/lib/pocketforge/pf-session-publish"

# This bead deliberately creates no .wants/.requires link. The parent milestone
# owns selection of the default session after G1 and visual acceptance.
if find "${rootfs}/etc/systemd/system" -path '*.wants/pocketforge-gamescope-session.target' \
    -print -quit | grep -q .; then
    echo 'refusing an enabled Gamescope session target' >&2
    exit 1
fi
