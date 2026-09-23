#!/bin/sh
set -eu

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
source_dir="$root/third_party/xradio-hciattach"
builder="$root/scripts/build-rootfs.sh"
verifier="$root/scripts/verify-rootfs-bluetooth.sh"
unit="$root/rootfs-overlay/etc/systemd/system/pocketforge-xr829-hciattach.service"
fixture="$(mktemp -d)"
trap 'find "$fixture" -mindepth 1 -delete; rmdir "$fixture"' EXIT

"${CC:-cc}" -O2 -std=gnu11 -Wall -Wextra \
	-Wno-unused-parameter -Wno-unused-function \
	-I"$source_dir" -o "$fixture/xr829-hciattach" \
	"$source_dir/main.c" "$source_dir/hciattach_xradio.c"
"$fixture/xr829-hciattach" 2>&1 | grep -F 'usage:' >/dev/null || test "$?" -eq 2

grep -Fq 'ExecStart=/usr/libexec/pocketforge/xr829-hciattach /dev/ttyS1' "$unit"
grep -Fq 'BindsTo=dev-ttyS1.device' "$unit"
grep -Fq 'After=systemd-udev-settle.service systemd-rfkill.service dev-ttyS1.device' "$unit"
grep -Fq 'Restart=no' "$unit"
# This is intentionally a literal shell fragment in the builder.
# shellcheck disable=SC2016
grep -Fq '[ "${PF_GPU_MODEL}" = "open" ]' "$builder"
grep -Fq 'scripts/verify-rootfs-bluetooth.sh' "$builder"

mkdir -p "$fixture/root/usr/libexec/pocketforge" \
	"$fixture/root/etc/systemd/system/multi-user.target.wants" \
	"$fixture/root/lib/firmware"
cp "$fixture/xr829-hciattach" "$fixture/root/usr/libexec/pocketforge/"
cp "$unit" "$fixture/root/etc/systemd/system/"
printf 'firmware\n' > "$fixture/root/lib/firmware/fw_xr829_bt.bin"
ln -s /etc/systemd/system/pocketforge-xr829-hciattach.service \
	"$fixture/root/etc/systemd/system/multi-user.target.wants/pocketforge-xr829-hciattach.service"
"$verifier" "$fixture/root" >/dev/null

# Negative control: the image-content gate must reject a silently dropped binary.
find "$fixture/root/usr/libexec/pocketforge" -mindepth 1 -delete
if "$verifier" "$fixture/root" >/dev/null 2>&1; then
	echo 'FAIL: Bluetooth verifier accepted a rootfs without the attach binary' >&2
	exit 1
fi

echo 'rootfs-bluetooth-test=PASS'
