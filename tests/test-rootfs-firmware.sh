#!/bin/sh
set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
packages="$root/rootfs-packages.txt"
builder="$root/scripts/build-rootfs.sh"
verifier="$root/scripts/verify-rootfs-firmware.sh"
fixture="$(mktemp -d)"
trap 'find "$fixture" -mindepth 1 -delete; rmdir "$fixture"' EXIT

grep -Fx 'wireless-regdb' "$packages" >/dev/null
grep -F 'Debian bookworm 2026.02.04-1~deb12u1' "$packages" >/dev/null
grep -F 'scripts/verify-rootfs-firmware.sh' "$builder" >/dev/null

mkdir -p "$fixture/lib/firmware"
: > "$fixture/lib/firmware/regulatory.db"
: > "$fixture/lib/firmware/regulatory.db.p7s"
"$verifier" "$fixture" >/dev/null

# Negative controls: both signed-regdb files are required, and the explicitly
# declined XR829 BT blob must make image assembly fail closed if it appears.
find "$fixture" -mindepth 1 -delete
mkdir -p "$fixture/lib/firmware"
: > "$fixture/lib/firmware/regulatory.db"
if "$verifier" "$fixture" >/dev/null 2>&1; then
    echo 'verifier accepted a rootfs without regulatory.db.p7s' >&2
    exit 1
fi

: > "$fixture/lib/firmware/regulatory.db.p7s"
: > "$fixture/lib/firmware/fw_xr829_bt.bin"
if "$verifier" "$fixture" >/dev/null 2>&1; then
    echo 'verifier accepted non-redistributable fw_xr829_bt.bin' >&2
    exit 1
fi

echo 'rootfs-firmware-test=PASS'
