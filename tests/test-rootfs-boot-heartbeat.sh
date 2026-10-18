#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
unit="$root/rootfs-overlay/etc/systemd/system/pf-boot-heartbeat.service"
builder="$root/scripts/build-rootfs.sh"
initrd="$root/boards/tsp/initrd/init"

test -f "$unit"
grep -Fq 'DefaultDependencies=no' "$unit"
grep -Fq 'Before=sysinit.target' "$unit"
grep -Fq 'PF_BOOT_HEARTBEAT' "$unit"
grep -Fq '> /dev/kmsg' "$unit"
grep -Fq '> /dev/console' "$unit"
grep -Fq 'install -m 0644 "/work/src/rootfs-overlay/etc/systemd/system/pf-boot-heartbeat.service"' "$builder"
grep -Fq 'sysinit.target.wants/pf-boot-heartbeat.service' "$builder"

# The diagnostic must not perturb the boot-resource memory layout.
if grep -Fq 'PF_BOOT_HEARTBEAT' "$initrd"; then
    echo 'heartbeat still changes initrd' >&2
    exit 1
fi

echo 'rootfs boot heartbeat test: PASS'
