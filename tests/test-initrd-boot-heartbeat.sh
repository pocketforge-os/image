#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
init="$repo/boards/tsp/initrd/init"

require() {
    pattern=$1
    reason=$2
    if ! grep -Fq -- "$pattern" "$init"; then
        printf 'FAIL: %s (missing %s)\n' "$reason" "$pattern" >&2
        exit 1
    fi
}

require 'mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs /newroot/run' \
    'diagnostic state must be volatile'
require 'DefaultDependencies=no' 'heartbeat must start before ordinary boot targets'
require 'Before=sysinit.target' 'heartbeat must precede sysinit'
require '/proc/1/stat' 'heartbeat must report PID 1 state'
require '/dev/kmsg' 'heartbeat must exercise the kernel log path'
require '/dev/console' 'heartbeat must exercise the active console path'
require 'sysinit.target.wants/pf-boot-heartbeat.service' \
    'the volatile service must be enabled for this boot'

printf 'PASS: volatile early-boot heartbeat is wired into the initrd handoff\n'
