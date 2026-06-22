#!/bin/bash
# =============================================================================
# container-memtest.sh — A523 substrate acceptance proof (bead tsp-vuo.4)
# =============================================================================
# Demonstrates: a crun container runs under a systemd slice with an ENFORCED
# per-app MemoryMax= — i.e. the kernel memory controller (CONFIG_MEMCG=y, owned
# kernel) is active and limits are applied + enforced (OOM at the cap).
#
# Run on the device over serial or SSH:  sudo /usr/lib/pocketforge/container-memtest.sh
# Emits a single PASS/FAIL line plus the load-bearing numbers as evidence.
# =============================================================================
set -uo pipefail
say() { echo "[memtest] $*"; }
PASS=1; fail() { PASS=0; say "FAIL: $*"; }

HELLO=pocketforge-hello-container.service
MEMTEST=pocketforge-memtest-container.service
CG=/sys/fs/cgroup
# A slice named "pocketforge-apps.slice" is auto-nested by systemd under
# "pocketforge.slice", so the real cgroup base is /pocketforge.slice/
# pocketforge-apps.slice. We confirm/override this from hello's live
# ControlGroup below rather than trusting a hardcoded path.
SLICE_CG="${CG}/pocketforge.slice/pocketforge-apps.slice"

say "=== 1. kernel cgroup-v2 + memory controller ==="
mount | grep -q 'type cgroup2' || fail "cgroup2 not mounted"
say "controllers (root): $(cat $CG/cgroup.controllers 2>/dev/null)"
grep -qw memory "$CG/cgroup.controllers" 2>/dev/null || fail "memory controller absent from cgroup.controllers (MEMCG not active)"
say "kernel: $(uname -r)  |  compatible: $(tr -d '\0' </proc/device-tree/compatible 2>/dev/null)"

say "=== 2. steady-state container under the slice (hello, cap 64M) ==="
systemctl reset-failed "$HELLO" 2>/dev/null
systemctl start "$HELLO" || fail "could not start hello container"
sleep 3
HCG="$(systemctl show -p ControlGroup --value "$HELLO" 2>/dev/null)"
HMAX="$(systemctl show -p MemoryMax --value "$HELLO" 2>/dev/null)"
# Derive the real slice cgroup base from hello's live ControlGroup (robust to
# the pocketforge.slice auto-nesting), so the memtest oom check reads the right path.
[ -n "$HCG" ] && SLICE_CG="${CG}$(dirname "$HCG")"
say "hello ControlGroup = ${HCG}"
say "hello MemoryMax (systemd) = ${HMAX} bytes"
if [ -n "$HCG" ] && [ -r "${CG}${HCG}/memory.max" ]; then
    say "hello cgroup memory.max     = $(cat "${CG}${HCG}/memory.max")"
    say "hello cgroup memory.current = $(cat "${CG}${HCG}/memory.current")"
    [ "$(cat "${CG}${HCG}/memory.max")" = "67108864" ] || fail "hello memory.max != 64MiB (limit not applied to the cgroup)"
else
    fail "hello unit cgroup memory.max not readable (controller not delegated)"
fi
crun --cgroup-manager=disabled list 2>/dev/null | sed 's/^/[memtest]   crun: /'

say "=== 3. enforcement: memtest allocates past the cap -> OOM kill ==="
# RELIABLE signal = the SLICE-level memory.events oom_kill: it propagates from
# the (transient) memtest unit cgroup up to the slice AND the slice persists, so
# it's stable. The unit cgroup is torn down faster than we can poll it, and
# dmesg-count deltas are racy under kernel-log spam — both proved unreliable on
# this device. (.local would be 0 — the OOM is in a descendant, not the slice.)
SLICE_EVENTS="${SLICE_CG}/memory.events"
oom_base="$(sed -n 's/^oom_kill //p' "${SLICE_EVENTS}" 2>/dev/null || echo 0)"
say "slice memory.events oom_kill (before) = ${oom_base:-0}"
systemctl reset-failed "$MEMTEST" 2>/dev/null
systemctl start "$MEMTEST" 2>/dev/null || true   # allocates past the cap, OOMs, exits
# wait for the memtest unit to finish (it OOMs + exits within a few seconds)
for _ in $(seq 1 25); do
    systemctl is-active "$MEMTEST" >/dev/null 2>&1 || break
    sleep 1
done
sleep 1
oom_now="$(sed -n 's/^oom_kill //p' "${SLICE_EVENTS}" 2>/dev/null || echo 0)"
say "slice memory.events oom_kill (after)  = ${oom_now:-0}"
DMESG_OOM="$(dmesg 2>/dev/null | grep 'Memory cgroup out of memory' | tail -1)"
[ -n "$DMESG_OOM" ] && say "dmesg: ${DMESG_OOM}"
if [ "${oom_now:-0}" -gt "${oom_base:-0}" ]; then
    say "enforcement CONFIRMED (slice oom_kill incremented ${oom_base}->${oom_now}: runaway allocator OOM-killed at the 64MiB cap)"
else
    fail "no OOM kill recorded at the slice level — MemoryMax not enforced"
fi

systemctl stop "$HELLO" 2>/dev/null

echo
if [ "$PASS" = 1 ]; then
    echo "[memtest] RESULT: PASS — crun container ran under pocketforge-apps.slice with an enforced MemoryMax (cgroup memory controller active)."
    exit 0
else
    echo "[memtest] RESULT: FAIL — see [memtest] FAIL lines above."
    exit 1
fi
