#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
init="$root/boards/tsp/initrd/init"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-selfflash-v2.XXXXXX")"
cleanup() {
    find "$tmp" -mindepth 1 -delete
    rmdir "$tmp"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

awk '
    /^# BEGIN POCKETFORGE SELF-FLASH V2 FUNCTIONS$/ { copy=1; next }
    /^# END POCKETFORGE SELF-FLASH V2 FUNCTIONS$/ { copy=0 }
    copy { print }
' "$init" >"$tmp/functions.sh"
[[ -s "$tmp/functions.sh" ]] || fail 'production self-flash v2 function block missing'
# shellcheck source=/dev/null
. "$tmp/functions.sh"
for function in sf_v2_validate_and_resolve sf_v2_stage_ram sf_v2_write_verify \
        sf_v2_install_seed; do
    declare -F "$function" >/dev/null || fail "$function missing"
done

sys="$tmp/sys/class/block"
dev="$tmp/dev"
mnt="$tmp/root"
ram="$tmp/ram"
fat="$tmp/fat"
mkdir -p "$sys" "$dev" "$mnt/var/tmp/pf-selfflash-seed" "$ram" "$fat"
SF_SYS_CLASS_BLOCK="$sys"
SF_DEV_ROOT="$dev"
SF_RAM_ROOT="$ram"
export SF_SYS_CLASS_BLOCK SF_DEV_ROOT SF_RAM_ROOT

make_card() {
    local class_name=$1 controller=$2 removable=$3 serial=$4 sectors=$5
    local physical="$tmp/sys/devices/platform/soc/${controller}.mmc/mmc_host/mmc9/mmc9:0001"
    local class="$sys/$class_name"
    mkdir -p "$physical" "$class"
    ln -s "$physical" "$class/device"
    printf '%s\n' "$removable" >"$class/removable"
    printf '%s\n' "$sectors" >"$class/size"
    printf '%s\n' "$serial" >"$physical/serial"
    : >"$dev/$class_name"
}

raw="$tmp/raw.img"
for value in $(seq 0 4095); do printf '%04x\n' "$value"; done >"$raw"
xz -z -c "$raw" >"$mnt/var/tmp/pf-selfflash-stage.img.xz"
xz_bytes="$(stat -c %s "$mnt/var/tmp/pf-selfflash-stage.img.xz")"
xz_sha="$(sha256sum "$mnt/var/tmp/pf-selfflash-stage.img.xz" | cut -d' ' -f1)"
img_bytes="$(stat -c %s "$raw")"
img_sha="$(sha256sum "$raw" | cut -d' ' -f1)"
printf 'instance-id: test\n' >"$mnt/var/tmp/pf-selfflash-seed/meta-data"
printf 'version: 2\n' >"$mnt/var/tmp/pf-selfflash-seed/network-config"
printf '#cloud-config\n' >"$mnt/var/tmp/pf-selfflash-seed/user-data"
meta_sha="$(sha256sum "$mnt/var/tmp/pf-selfflash-seed/meta-data" | cut -d' ' -f1)"
network_sha="$(sha256sum "$mnt/var/tmp/pf-selfflash-seed/network-config" | cut -d' ' -f1)"
user_sha="$(sha256sum "$mnt/var/tmp/pf-selfflash-seed/user-data" | cut -d' ' -f1)"

flag() {
    cat <<EOF
PF_FLAG=1
ver=2
state=armed
generation=0123456789abcdef0123456789abcdef
descriptor_sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
xz_file=/var/tmp/pf-selfflash-stage.img.xz
xz_bytes=$xz_bytes
xz_sha256=$xz_sha
img_bytes=$img_bytes
img_sha256=$img_sha
sd_controller=04020000
sd_serial=0x1234abcd
card_sectors=256
seed_dir=/var/tmp/pf-selfflash-seed
seed_meta_sha256=$meta_sha
seed_network_sha256=$network_sha
seed_user_sha256=$user_sha
tries=0
EOF
}

# Positive control: the SD card may have any block name. The controller path,
# removable bit, serial, and size are the identity.
make_card arbitrary-card 4020000 1 0x1234abcd 256
truncate -s $((256 * 512)) "$dev/arbitrary-card"
printf 'TAIL-SENTINEL' | dd of="$dev/arbitrary-card" bs=1 seek="$img_bytes" conv=notrunc status=none
sf_v2_validate_and_resolve "$(flag)" || fail 'valid SD identity refused'
[[ "$SF_SD" == "$dev/arbitrary-card" ]] || fail "resolved wrong device: $SF_SD"
sf_v2_stage_ram "$mnt" || fail 'valid payload refused'
sf_v2_write_verify || fail 'valid whole-image write/verify refused'
cmp -n "$img_bytes" "$raw" "$dev/arbitrary-card" || fail 'raw image range differs'
tail_value="$(dd if="$dev/arbitrary-card" bs=1 skip="$img_bytes" count=13 status=none)"
[[ "$tail_value" == TAIL-SENTINEL ]] || fail 'write crossed RawBytes'
sf_v2_install_seed "$fat" || fail 'valid seed install refused'
for name in meta-data network-config user-data; do
    cmp "$mnt/var/tmp/pf-selfflash-seed/$name" "$fat/$name" \
        || fail "$name differs after install"
done
grep -Fqx "RawSHA256=$img_sha" "$fat/pocketforge-selfflash-receipt" \
    || fail 'durable receipt lacks verified raw SHA'

# Negative control required by the owner: mmcblk0 is eMMC. Its name must not
# persuade the gate to write it, and refusal happens before the sentinel changes.
find "$sys" -mindepth 1 -delete
make_card mmcblk0 4022000 0 0x1234abcd 256
truncate -s $((256 * 512)) "$dev/mmcblk0"
printf 'EMMC-DO-NOT-WRITE' | dd of="$dev/mmcblk0" bs=1 conv=notrunc status=none
before="$(sha256sum "$dev/mmcblk0" | cut -d' ' -f1)"
if sf_v2_validate_and_resolve "$(flag)"; then
    sf_v2_write_verify
    fail 'mmcblk0 eMMC identity was accepted'
fi
after="$(sha256sum "$dev/mmcblk0" | cut -d' ' -f1)"
[[ "$before" == "$after" ]] || fail 'eMMC changed before refusal'

# Same SD controller but a non-removable card, changed serial, or changed size
# must refuse before the write helper can be reached.
for case_name in nonremovable serial size; do
    find "$sys" -mindepth 1 -delete
    removable=1; serial=0x1234abcd; sectors=256
    [[ "$case_name" == nonremovable ]] && removable=0
    [[ "$case_name" == serial ]] && serial=0xfeedbeef
    [[ "$case_name" == size ]] && sectors=512
    make_card "$case_name" 4020000 "$removable" "$serial" "$sectors"
    if sf_v2_validate_and_resolve "$(flag)"; then
        fail "$case_name identity mismatch was accepted"
    fi
done

# Payload corruption is not a negative result: it is a hard refusal and cannot
# proceed to the destructive helper.
find "$sys" -mindepth 1 -delete
make_card sd-again 4020000 1 0x1234abcd 256
truncate -s $((256 * 512)) "$dev/sd-again"
sf_v2_validate_and_resolve "$(flag)" || fail 'second valid SD identity refused'
printf 'corrupt\n' >>"$mnt/var/tmp/pf-selfflash-seed/user-data"
if sf_v2_stage_ram "$mnt"; then
    fail 'corrupt seed payload was accepted'
fi

# A post-write device mismatch proves the complete RawBytes readback is binding.
printf '#cloud-config\n' >"$mnt/var/tmp/pf-selfflash-seed/user-data"
sf_v2_stage_ram "$mnt" || fail 'restored payload refused'
SF_V2_TEST_CORRUPT_AFTER_WRITE=1
export SF_V2_TEST_CORRUPT_AFTER_WRITE
if sf_v2_write_verify; then
    fail 'post-write raw corruption was accepted'
fi

printf 'PASS: self-flash v2 binds controller/card identity, whole-image readback, seed reinjection, and durable receipt\n'
