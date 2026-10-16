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
grep -F 'scripts/extract-a133-battery-model.py' "$builder" >/dev/null
grep -F 'sunxi/a133/boot-chain/vendor-dtb.bin' "$builder" >/dev/null
grep -F 'lib/firmware/x-powers/axp717-tsp-battery-model.bin' "$builder" >/dev/null
grep -F -- '--set regulatory.db /lib/firmware/regulatory.db-upstream' "$builder" >/dev/null
# Literal build-script variables are intentional in these structural assertions.
# shellcheck disable=SC2016
grep -F '[ -f "${BLOBS_DIR}/sunxi/a133/wifi-firmware/fw_xr829_bt.bin" ]' "$builder" >/dev/null
# shellcheck disable=SC2016
grep -F 'install -m 0644 "/work/blobs/sunxi/a133/wifi-firmware/fw_xr829_bt.bin" "${ROOTFS}/lib/firmware/"' "$builder" >/dev/null
for artifact in fw_xr829.bin boot_xr829.bin sdd_xr829.bin fw_xr829_bt.bin; do
	grep -F "wifi-firmware/$artifact" "$builder" >/dev/null
done

write_xr829_firmware() {
	for artifact in fw_xr829.bin boot_xr829.bin sdd_xr829.bin fw_xr829_bt.bin; do
		printf 'XR829 firmware %s\n' "$artifact" > "$fixture/lib/firmware/$artifact"
	done
	mkdir -p "$fixture/lib/firmware/x-powers"
	dd if=/dev/zero of="$fixture/lib/firmware/x-powers/axp717-tsp-battery-model.bin" \
		bs=128 count=1 status=none
}

fixture_model_sha256=38723a2e5e8a17aa7950dc008209944e898f69a7bd10a23c839d341e935fd5ca
run_verifier() {
	"$verifier" --expected-axp717-model-sha256 "$fixture_model_sha256" "$fixture"
}

mkdir -p "$fixture/lib/firmware"
printf 'database\n' > "$fixture/lib/firmware/regulatory.db"
printf 'signature\n' > "$fixture/lib/firmware/regulatory.db.p7s"
cp "$fixture/lib/firmware/regulatory.db" "$fixture/lib/firmware/regulatory.db-upstream"
cp "$fixture/lib/firmware/regulatory.db.p7s" "$fixture/lib/firmware/regulatory.db.p7s-upstream"
write_xr829_firmware
run_verifier >/dev/null

# Match Debian's update-alternatives layout: absolute links look dangling from
# the build host but resolve correctly after the extracted tree becomes `/`.
find "$fixture" -mindepth 1 -delete
mkdir -p "$fixture/lib/firmware" "$fixture/etc/alternatives"
printf 'database\n' > "$fixture/lib/firmware/regulatory.db-upstream"
printf 'signature\n' > "$fixture/lib/firmware/regulatory.db.p7s-upstream"
write_xr829_firmware
ln -s /etc/alternatives/regulatory.db "$fixture/lib/firmware/regulatory.db"
ln -s /etc/alternatives/regulatory.db.p7s "$fixture/lib/firmware/regulatory.db.p7s"
ln -s /lib/firmware/regulatory.db-upstream "$fixture/etc/alternatives/regulatory.db"
ln -s /lib/firmware/regulatory.db.p7s-upstream "$fixture/etc/alternatives/regulatory.db.p7s"
run_verifier >/dev/null

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
if run_verifier >/dev/null 2>&1; then
    echo 'verifier accepted Debian-signed regulatory database alternatives' >&2
    exit 1
fi

find "$fixture" -mindepth 1 -delete
mkdir -p "$fixture/lib/firmware"
ln -s /does/not/exist "$fixture/lib/firmware/regulatory.db"
ln -s /also/missing "$fixture/lib/firmware/regulatory.db.p7s"
if run_verifier >/dev/null 2>&1; then
    echo 'verifier accepted dangling regulatory database links' >&2
    exit 1
fi

# Negative controls: both signed-regdb files and the owner-approved embedded
# XR829 firmware group are required.
find "$fixture" -mindepth 1 -delete
mkdir -p "$fixture/lib/firmware"
printf 'database\n' > "$fixture/lib/firmware/regulatory.db"
printf 'database\n' > "$fixture/lib/firmware/regulatory.db-upstream"
if run_verifier >/dev/null 2>&1; then
    echo 'verifier accepted a rootfs without regulatory.db.p7s' >&2
    exit 1
fi

printf 'signature\n' > "$fixture/lib/firmware/regulatory.db.p7s"
printf 'signature\n' > "$fixture/lib/firmware/regulatory.db.p7s-upstream"
if run_verifier >/dev/null 2>&1; then
    echo 'verifier accepted a rootfs without the XR829 firmware group' >&2
    exit 1
fi

write_xr829_firmware
# The fixture-only digest override permits hermetic test bytes. Production's
# default pin must reject those bytes.
if "$verifier" "$fixture" >/dev/null 2>&1; then
    echo 'verifier default accepted a non-production AXP717 model digest' >&2
    exit 1
fi
status="$(run_verifier)"
printf '%s\n' "$status" | grep -F 'xr829=EMBEDDED:fw_xr829.bin,boot_xr829.bin,sdd_xr829.bin,fw_xr829_bt.bin' >/dev/null
printf '%s\n' "$status" | grep -F 'axp717-model=PINNED:128' >/dev/null

truncate -s 127 "$fixture/lib/firmware/x-powers/axp717-tsp-battery-model.bin"
if run_verifier >/dev/null 2>&1; then
    echo 'verifier accepted a truncated AXP717 battery model' >&2
    exit 1
fi
write_xr829_firmware
printf '\001' | dd of="$fixture/lib/firmware/x-powers/axp717-tsp-battery-model.bin" \
    bs=1 seek=64 conv=notrunc status=none
if run_verifier >/dev/null 2>&1; then
    echo 'verifier accepted an altered AXP717 battery model' >&2
    exit 1
fi
if printf '%s\n' "$status" | grep -F 'xr829=NOT-SHIPPED' >/dev/null; then
    echo 'verifier still reports XR829 firmware as not shipped' >&2
    exit 1
fi

echo 'rootfs-firmware-test=PASS'
