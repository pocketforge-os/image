#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-root-grow.XXXXXX")"
loop_device=""

cleanup() {
    if [ -n "${loop_device}" ]; then
        sudo -n losetup --detach "${loop_device}"
    fi
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for command in debugfs dumpe2fs losetup mkfs.ext4 partx \
    resize2fs sfdisk truncate udevadm; do
    command -v "${command}" >/dev/null || fail "missing test dependency: ${command}"
done
sudo -n true || fail "passwordless sudo is required for the hermetic loop device"

disk="${scratch}/sd-card.img"
payload="${scratch}/installed-root-payload.bin"

# Model the five-partition production GPT with p5 last. The initial medium is
# deliberately larger than p5, then the same backing file is enlarged to model
# writing a fixed-size image to a larger SD card.
truncate -s 480M "${disk}"
sfdisk "${disk}" >/dev/null <<'SFDISK'
label: gpt
unit: sectors

start=16384, size=65536, type=linux, name="boot"
start=81920, size=128, type=linux, name="env"
start=82048, size=128, type=linux, name="env-redund"
start=143360, size=131072, type=linux, name="boot-resource"
start=274432, size=655360, type=linux, name="userdata"
SFDISK

loop_device="$(sudo -n losetup --find --show --partscan "${disk}")"
root_partition="${loop_device}p5"
for _attempt in $(seq 1 20); do
    [ -b "${root_partition}" ] && break
    udevadm settle
done
[ -b "${root_partition}" ] || fail "loop partition p5 did not appear"

sudo -n mkfs.ext4 -q -F -m 0 -O '^64bit' "${root_partition}"
dd if=/dev/zero of="${payload}" bs=1M count=20 status=none
sudo -n debugfs -w -R "write ${payload} /installed-root-payload" \
    "${root_partition}" >/dev/null 2>&1

free_bytes() {
    sudo -n dumpe2fs -h "$1" 2>/dev/null | awk '
        /^Free blocks:/ { free_blocks=$3 }
        /^Block size:/ { block_size=$3 }
        END {
            if (!free_blocks || !block_size) exit 1
            print free_blocks * block_size
        }
    '
}

free_before="$(free_bytes "${root_partition}")"
min_free=$((260 * 1024 * 1024))
max_free=$((310 * 1024 * 1024))
[ "${free_before}" -ge "${min_free}" ] && [ "${free_before}" -le "${max_free}" ] \
    || fail "RED fixture does not reproduce about 287 MB free: ${free_before} bytes"

sudo -n losetup --detach "${loop_device}"
loop_device=""
truncate -s 16G "${disk}"
loop_device="$(sudo -n losetup --find --show --partscan "${disk}")"
root_partition="${loop_device}p5"
free_on_larger_media="$(free_bytes "${root_partition}")"
[ "${free_on_larger_media}" -eq "${free_before}" ] \
    || fail "ungrown filesystem free space changed after enlarging only the medium"
echo "ROOT_GROW_RED free_bytes=${free_on_larger_media} disposition=ungrown"

cloud_config="${repo_dir}/rootfs-overlay/etc/cloud/cloud.cfg.d/99-pocketforge-self-flash-v3.cfg"
helper="${repo_dir}/rootfs-overlay/usr/lib/pocketforge/self-flash-v3-grow"
unit="${repo_dir}/rootfs-overlay/etc/systemd/system/pocketforge-self-flash-v3-grow.service"
builder="${repo_dir}/scripts/build-rootfs.sh"
[ -f "${cloud_config}" ] || fail "self-flash v3 cloud override is absent"
grep -Fq 'mode: off' "${cloud_config}" || fail "competing growpart mutator is enabled"
grep -Fxq 'resize_rootfs: false' "${cloud_config}" || fail "competing resizefs mutator is enabled"
[ -x "${helper}" ] || fail "capped root-grow helper is absent or non-executable"
grep -Fq 'Before=cloud-final.service' "${unit}" \
    || fail "cloud-final can complete before capped root growth"
grep -Fq 'ExecStart=/usr/lib/pocketforge/self-flash-v3-grow' "${unit}" \
    || fail "root-grow unit does not execute the capped mutator"
grep -Fq 'WantedBy=multi-user.target' "${unit}" \
    || fail "root-grow unit has no installation target"
for installed_path in \
    '99-pocketforge-self-flash-v3.cfg' \
    'self-flash-v3-grow' \
    'pocketforge-self-flash-v3-grow.service' \
    'multi-user.target.wants/pocketforge-self-flash-v3-grow.service' \
    'etc/pocketforge-selfflash-v3'; do
    grep -Fq "${installed_path}" "${builder}" \
        || fail "rootfs builder does not install ${installed_path}"
done
grep -Fq 'PF_ROOT_GROW state=' "${helper}" \
    || fail "capped mutator does not emit the typed root-grow result"

disk_bytes="$(stat -c %s "${disk}")"
reserve_bytes=$((1024 * 1024 * 1024))
alignment_bytes=$((4 * 1024 * 1024))
tail_start=$(( (disk_bytes - reserve_bytes) / alignment_bytes * alignment_bytes ))
root_start=274432
target_sectors=$(( tail_start / 512 - root_start ))
sudo -n sfdisk --relocate gpt-bak-std "${loop_device}" >/dev/null
printf 'start=%s, size=%s\n' "${root_start}" "${target_sectors}" | \
    sudo -n sfdisk --no-reread --no-tell-kernel --force -N 5 "${loop_device}" >/dev/null
sudo -n partx --update --nr 5 "${loop_device}"
udevadm settle
sudo -n resize2fs "${root_partition}" >/dev/null
free_after="$(free_bytes "${root_partition}")"
[ "${free_after}" -ge $((2 * 1024 * 1024 * 1024)) ] \
    || fail "grown root has less than 2 GiB free"

disk_sectors=$(( $(stat -c %s "${disk}") / 512 ))
partition_end="$(sfdisk --json "${disk}" | python3 -c '
import json, sys
parts = json.load(sys.stdin)["partitiontable"]["partitions"]
part = parts[4]
print(part["start"] + part["size"])
')"
[ "${partition_end}" -eq $((tail_start / 512)) ] \
    || fail "p5 does not end at the aligned self-flash v3 tail boundary"
[ $((disk_bytes - partition_end * 512)) -eq "${reserve_bytes}" ] \
    || fail "self-flash v3 tail is not exactly 1 GiB"
backup_signature="$(dd if="${disk}" bs=512 skip=$((disk_sectors - 1)) count=1 status=none | head -c 8)"
[ "${backup_signature}" = 'EFI PART' ] \
    || fail "GPT backup header was not relocated to the final LBA"

echo "ROOT_GROW_GREEN free_before=${free_before} free_after=${free_after} tail_bytes=${reserve_bytes} gpt_backup=final-lba"
