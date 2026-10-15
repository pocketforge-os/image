#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
init="$root/boards/tsp/initrd/init"
builder="$root/boards/tsp/initrd/build-initrd.sh"
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
grep -Fq 'pocketforge-selfflash-v2' "$builder" \
    || fail 'versioned self-flash capability marker missing from initrd builder'

recover="$(sed -n '/^selfflash_recover() {/,/^}/p' "$init")"
post_write="$(sed -n '/^[[:space:]]*if ! sf_v2_write_verify/,/^[[:space:]]*# Success:/p' \
    <<<"$recover")"
post_write_contract() {
    [[ "$(grep -Fc 'sf_v2_terminal_recovery' <<<"$1")" -eq 5 ]] \
        && ! grep -Fq 'return 1' <<<"$1"
}
post_write_contract "$post_write" \
    || fail 'every post-write error must enter terminal FEL recovery'
fail_open_mutation="$(sed '0,/sf_v2_terminal_recovery/s//return 1 #/' <<<"$post_write")"
if post_write_contract "$fail_open_mutation"; then
    fail 'post-write fail-open negative control was accepted'
fi
if grep -Fq 'return 1' <<<"$post_write"; then
    fail 'post-write error can return to normal boot'
fi

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
mountinfo="$tmp/mountinfo"
mkdir -p "$sys" "$dev" "$mnt/var/tmp/pf-selfflash-seed" "$ram" "$fat"
: >"$mountinfo"
SF_SYS_CLASS_BLOCK="$sys"
SF_DEV_ROOT="$dev"
SF_RAM_ROOT="$ram"
SF_MOUNTINFO_FILE="$mountinfo"
export SF_SYS_CLASS_BLOCK SF_DEV_ROOT SF_RAM_ROOT SF_MOUNTINFO_FILE

make_card() {
    local class_name=$1 controller=$2 type=$3 serial=$4 sectors=$5
    local physical="$tmp/sys/devices/platform/soc/${controller}.mmc/mmc_host/$class_name/${class_name}:0001"
    local block="$physical/block/$class_name"
    local class="$sys/$class_name"
    mkdir -p "$block"
    ln -s "$block" "$class"
    ln -s "$physical" "$block/device"
    # Linux MMC gendisks report removable=0 even for hot-pluggable SD cards.
    printf '0\n' >"$class/removable"
    printf '%s\n' "$sectors" >"$class/size"
    printf '179:0\n' >"$class/dev"
    printf '%s\n' "$type" >"$physical/type"
    printf '%s\n' "$serial" >"$physical/serial"
    : >"$dev/$class_name"
}

make_emmc_extra_disks() {
    local parent_name=$1 parent_real extra index=1
    parent_real="$(readlink -f "$sys/$parent_name")"
    for extra in boot0 boot1 rpmb; do
        mkdir -p "$parent_real/${parent_name}${extra}"
        ln -s "$parent_real/${parent_name}${extra}" "$sys/${parent_name}${extra}"
        ln -s "$parent_real" "$sys/${parent_name}${extra}/device"
        printf '0\n' >"$sys/${parent_name}${extra}/removable"
        printf '8192\n' >"$sys/${parent_name}${extra}/size"
        printf '179:%s\n' "$index" >"$sys/${parent_name}${extra}/dev"
        : >"$dev/${parent_name}${extra}"
        index=$((index + 1))
    done
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

# Positive control mirrors the real kernel: even a hot-pluggable SD gendisk has
# removable=0. Controller path, MMC card type, serial, and size are the identity.
make_card arbitrary-card 4020000 SD 0x1234abcd 256
truncate -s $((256 * 512)) "$dev/arbitrary-card"
printf 'TAIL-SENTINEL' | dd of="$dev/arbitrary-card" bs=1 seek="$img_bytes" conv=notrunc status=none
sf_v2_validate_and_resolve "$(flag)" || fail 'valid SD identity refused'
[[ "$SF_SD" == "$dev/arbitrary-card" ]] || fail "resolved wrong device: $SF_SD"
removable_lookup="\$sf_v2_entry/removable"
if grep -Fq "$removable_lookup" "$tmp/functions.sh"; then
    fail 'gate still assumes the MMC gendisk removable attribute'
fi
card_real="$(readlink -f "$SF_SD_SYS")"
mkdir -p "$card_real/arbitrary-cardp5"
printf '179:5\n' >"$card_real/arbitrary-cardp5/dev"
printf '0\n' >"$card_real/arbitrary-cardp5/removable"
ln -s "$card_real/arbitrary-cardp5" "$sys/arbitrary-cardp5"
[[ ! -e "$sys/arbitrary-cardp5/device" ]] \
    || fail 'partition fixture unexpectedly has a device link'
sf_v2_partition_on_selected_card "$dev/arbitrary-cardp5" \
    || fail 'partition on selected physical card was refused'
printf '25 1 179:5 / /root rw - ext4 /dev/anything rw\n' >"$mountinfo"
if sf_v2_selected_card_unmounted; then
    fail 'mounted selected-card partition was reported unmounted'
fi
: >"$mountinfo"
sf_v2_selected_card_unmounted || fail 'unmounted selected card was reported mounted'
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
grep -Fqx 'CardType=SD' "$fat/pocketforge-selfflash-receipt" \
    || fail 'durable receipt lacks verified SD card type'

# Negative control required by the owner: mmcblk0 is eMMC with the expected
# serial and a realistic boot0/boot1/rpmb fanout. Its name and matching card
# fields must not persuade the gate to write it.
find "$sys" -mindepth 1 -delete
make_card mmcblk0 4022000 MMC 0x1234abcd 256
make_emmc_extra_disks mmcblk0
for disk in "$sys"/*; do
    [[ "$(cat "$disk/removable")" == 0 ]] \
        || fail "MMC fixture does not mirror removable=0: ${disk##*/}"
done
truncate -s $((256 * 512)) "$dev/mmcblk0"
printf 'EMMC-DO-NOT-WRITE' | dd of="$dev/mmcblk0" bs=1 conv=notrunc status=none
before="$(sha256sum "$dev/mmcblk0" | cut -d' ' -f1)"
if sf_v2_validate_and_resolve "$(flag)"; then
    sf_v2_write_verify
    fail 'mmcblk0 eMMC identity was accepted'
fi
after="$(sha256sum "$dev/mmcblk0" | cut -d' ' -f1)"
[[ "$before" == "$after" ]] || fail 'eMMC changed before refusal'

# Even under the SD controller, an MMC-type card object is not the target.
find "$sys" -mindepth 1 -delete
make_card wrong-type 4020000 MMC 0x1234abcd 256
if sf_v2_validate_and_resolve "$(flag)"; then
    fail 'MMC type on SD controller was accepted'
fi

# More than one exact SD-type match is ambiguous and must fail closed.
find "$sys" -mindepth 1 -delete
make_card sd-match-a 4020000 SD 0x1234abcd 256
make_card sd-match-b 4020000 SD 0x1234abcd 256
if sf_v2_validate_and_resolve "$(flag)"; then
    fail 'two exact SD matches were accepted'
fi

# Legacy flags do not carry a controller/card identity and therefore cannot arm
# this gate. They remain a host-side FEL recovery case.
legacy_flag="$(flag | sed 's/^ver=2$/ver=1/')"
if sf_v2_validate_and_resolve "$legacy_flag"; then
    fail 'identity-less v1 flag was accepted'
fi

# Same SD controller and SD type with changed serial or size must refuse before
# the write helper can be reached.
for case_name in serial size; do
    find "$sys" -mindepth 1 -delete
    serial=0x1234abcd; sectors=256
    [[ "$case_name" == serial ]] && serial=0xfeedbeef
    [[ "$case_name" == size ]] && sectors=512
    make_card "$case_name" 4020000 SD "$serial" "$sectors"
    if sf_v2_validate_and_resolve "$(flag)"; then
        fail "$case_name identity mismatch was accepted"
    fi
done

# Payload corruption is not a negative result: it is a hard refusal and cannot
# proceed to the destructive helper.
find "$sys" -mindepth 1 -delete
make_card sd-again 4020000 SD 0x1234abcd 256
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
sf_v2_after_write() {
    [[ "${SF_V2_TEST_CORRUPT_AFTER_WRITE:-0}" == 1 ]] || return 0
    printf X | dd of="$SF_SD" bs=1 seek=17 conv=notrunc status=none
}
if sf_v2_write_verify; then
    fail 'post-write raw corruption was accepted'
fi

printf 'PASS: self-flash v2 binds controller/card identity, whole-image readback, seed reinjection, and durable receipt\n'
