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

for command in blockdev debugfs dumpe2fs growpart losetup mkfs.ext4 \
    resize2fs sfdisk truncate udevadm; do
    command -v "${command}" >/dev/null || fail "missing test dependency: ${command}"
done
sudo -n true || fail "passwordless sudo is required for the hermetic loop device"

disk="${scratch}/sd-card.img"
payload="${scratch}/installed-root-payload.bin"
grow_output="${scratch}/grow.out"
second_output="${scratch}/second-grow.out"

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
truncate -s 1G "${disk}"
loop_device="$(sudo -n losetup --find --show --partscan "${disk}")"
root_partition="${loop_device}p5"
free_on_larger_media="$(free_bytes "${root_partition}")"
[ "${free_on_larger_media}" -eq "${free_before}" ] \
    || fail "ungrown filesystem free space changed after enlarging only the medium"
echo "ROOT_GROW_RED free_bytes=${free_on_larger_media} disposition=ungrown"

cloud_config="${repo_dir}/rootfs-overlay/etc/cloud/cloud.cfg.d/99-pocketforge-root-grow.cfg"
reporter="${repo_dir}/rootfs-overlay/usr/lib/pocketforge/root-grow-result"
unit="${repo_dir}/rootfs-overlay/etc/systemd/system/pocketforge-root-grow-result.service"
[ -f "${cloud_config}" ] || fail "first-boot cloud-init growth config is absent"
grep -Fq 'mode: auto' "${cloud_config}" || fail "growpart is not automatic"
grep -Fq -- '- /' "${cloud_config}" || fail "growpart does not target the root partition"
grep -Fxq 'resize_rootfs: true' "${cloud_config}" || fail "resizefs is not enabled"
[ -x "${reporter}" ] || fail "typed root-grow reporter is absent or non-executable"
grep -Fq 'After=cloud-final.service' "${unit}" \
    || fail "typed reporter is not ordered after cloud-init growth"
grep -Fq 'ExecStart=/usr/lib/pocketforge/root-grow-result' "${unit}" \
    || fail "typed reporter unit does not execute the installed helper"
grep -Fq 'WantedBy=multi-user.target' "${unit}" \
    || fail "typed reporter unit is not enabled by the builder"

sudo -n growpart "${loop_device}" 5 >"${grow_output}"
sudo -n blockdev --rereadpt "${loop_device}"
udevadm settle
sudo -n resize2fs "${root_partition}" >/dev/null
free_after="$(free_bytes "${root_partition}")"
[ "${free_after}" -gt $((free_before + 400 * 1024 * 1024)) ] \
    || fail "grown root did not acquire the larger medium's free space"

disk_sectors=$(( $(stat -c %s "${disk}") / 512 ))
partition_end="$(sfdisk --json "${disk}" | python3 -c '
import json, sys
parts = json.load(sys.stdin)["partitiontable"]["partitions"]
part = parts[4]
print(part["start"] + part["size"])
')"
[ "${partition_end}" -eq $((disk_sectors - 33)) ] \
    || fail "p5 does not end immediately before the GPT backup structures"
backup_signature="$(dd if="${disk}" bs=512 skip=$((disk_sectors - 1)) count=1 status=none | head -c 8)"
[ "${backup_signature}" = 'EFI PART' ] \
    || fail "GPT backup header was not relocated to the final LBA"

if sudo -n growpart "${loop_device}" 5 >"${second_output}" 2>&1; then
    fail "second growpart invocation changed the already-grown root"
fi
grep -Fq 'NOCHANGE:' "${second_output}" \
    || fail "second growpart invocation was not the expected no-op"

echo "ROOT_GROW_GREEN free_before=${free_before} free_after=${free_after} second_boot=no-op gpt_backup=final-lba"
