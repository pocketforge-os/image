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
grep -F -- '--set regulatory.db /lib/firmware/regulatory.db-upstream' "$builder" >/dev/null
# Literal build-script variables are intentional in these structural assertions.
# shellcheck disable=SC2016
grep -F '[ -f "${BLOBS_DIR}/sunxi/a133/wifi-firmware/fw_xr829_bt.bin" ]' "$builder" >/dev/null
# shellcheck disable=SC2016
grep -F 'install -m 0644 "/work/blobs/sunxi/a133/wifi-firmware/fw_xr829_bt.bin" "${ROOTFS}/lib/firmware/"' "$builder" >/dev/null

mkdir -p "$fixture/lib/firmware"
printf 'database\n' > "$fixture/lib/firmware/regulatory.db"
printf 'signature\n' > "$fixture/lib/firmware/regulatory.db.p7s"
cp "$fixture/lib/firmware/regulatory.db" "$fixture/lib/firmware/regulatory.db-upstream"
cp "$fixture/lib/firmware/regulatory.db.p7s" "$fixture/lib/firmware/regulatory.db.p7s-upstream"
printf 'bluetooth firmware\n' > "$fixture/lib/firmware/fw_xr829_bt.bin"
"$verifier" "$fixture" >/dev/null

# Match Debian's update-alternatives layout: absolute links look dangling from
# the build host but resolve correctly after the extracted tree becomes `/`.
find "$fixture" -mindepth 1 -delete
mkdir -p "$fixture/lib/firmware" "$fixture/etc/alternatives"
printf 'database\n' > "$fixture/lib/firmware/regulatory.db-upstream"
printf 'signature\n' > "$fixture/lib/firmware/regulatory.db.p7s-upstream"
printf 'bluetooth firmware\n' > "$fixture/lib/firmware/fw_xr829_bt.bin"
ln -s /etc/alternatives/regulatory.db "$fixture/lib/firmware/regulatory.db"
ln -s /etc/alternatives/regulatory.db.p7s "$fixture/lib/firmware/regulatory.db.p7s"
ln -s /lib/firmware/regulatory.db-upstream "$fixture/etc/alternatives/regulatory.db"
ln -s /lib/firmware/regulatory.db.p7s-upstream "$fixture/etc/alternatives/regulatory.db.p7s"
"$verifier" "$fixture" >/dev/null

# Debian's higher-priority, locally re-signed alternative is present in the
# package but must never be selected by the assembled PocketForge rootfs.
find "$fixture" -mindepth 1 -delete
mkdir -p "$fixture/lib/firmware" "$fixture/etc/alternatives"
printf 'upstream database\n' > "$fixture/lib/firmware/regulatory.db-upstream"
printf 'upstream signature\n' > "$fixture/lib/firmware/regulatory.db.p7s-upstream"
printf 'debian database\n' > "$fixture/lib/firmware/regulatory.db-debian"
printf 'debian signature\n' > "$fixture/lib/firmware/regulatory.db.p7s-debian"
ln -s /etc/alternatives/regulatory.db "$fixture/lib/firmware/regulatory.db"
ln -s /etc/alternatives/regulatory.db.p7s "$fixture/lib/firmware/regulatory.db.p7s"
ln -s /lib/firmware/regulatory.db-debian "$fixture/etc/alternatives/regulatory.db"
ln -s /lib/firmware/regulatory.db.p7s-debian "$fixture/etc/alternatives/regulatory.db.p7s"
if "$verifier" "$fixture" >/dev/null 2>&1; then
    echo 'verifier accepted Debian-signed regulatory database alternatives' >&2
    exit 1
fi

find "$fixture" -mindepth 1 -delete
mkdir -p "$fixture/lib/firmware"
ln -s /does/not/exist "$fixture/lib/firmware/regulatory.db"
ln -s /also/missing "$fixture/lib/firmware/regulatory.db.p7s"
if "$verifier" "$fixture" >/dev/null 2>&1; then
    echo 'verifier accepted dangling regulatory database links' >&2
    exit 1
fi

# Negative controls: both signed-regdb files and the owner-approved embedded
# XR829 Bluetooth firmware are required.
find "$fixture" -mindepth 1 -delete
mkdir -p "$fixture/lib/firmware"
printf 'database\n' > "$fixture/lib/firmware/regulatory.db"
printf 'database\n' > "$fixture/lib/firmware/regulatory.db-upstream"
if "$verifier" "$fixture" >/dev/null 2>&1; then
    echo 'verifier accepted a rootfs without regulatory.db.p7s' >&2
    exit 1
fi

printf 'signature\n' > "$fixture/lib/firmware/regulatory.db.p7s"
printf 'signature\n' > "$fixture/lib/firmware/regulatory.db.p7s-upstream"
if "$verifier" "$fixture" >/dev/null 2>&1; then
    echo 'verifier accepted a rootfs without fw_xr829_bt.bin' >&2
    exit 1
fi

printf 'bluetooth firmware\n' > "$fixture/lib/firmware/fw_xr829_bt.bin"
status="$($verifier "$fixture")"
printf '%s\n' "$status" | grep -F 'xr829_bt=EMBEDDED' >/dev/null
if printf '%s\n' "$status" | grep -F 'xr829_bt=NOT-SHIPPED' >/dev/null; then
    echo 'verifier still reports fw_xr829_bt.bin as not shipped' >&2
    exit 1
fi

echo 'rootfs-firmware-test=PASS'
