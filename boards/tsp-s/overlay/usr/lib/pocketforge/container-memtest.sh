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
systemctl reset-failed "$MEMTEST" 2>/dev/null
MCG="${SLICE_CG}/${MEMTEST}"
say "memtest cgroup = ${MCG}"
# Baseline dmesg cgroup-OOM count (the kernel line persists even after the unit's
# cgroup is torn down — it is the authoritative enforcement signal; crun exits 0
# even when the container's process is OOM-killed, so systemd Result is unreliable).
oom_base="$(dmesg 2>/dev/null | grep -c 'Memory cgroup out of memory')"
OOMKILLS=0
systemctl start "$MEMTEST" 2>/dev/null || true   # will OOM; start may return after exit
for _ in $(seq 1 25); do
    # capture the cgroup oom_kill counter LIVE (the cgroup is removed once the unit exits)
    if [ -r "${MCG}/memory.events" ]; then
        v="$(sed -n 's/^oom_kill //p' "${MCG}/memory.events" 2>/dev/null)"
        [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && { OOMKILLS="$v"; break; }
    fi
    [ "$(dmesg 2>/dev/null | grep -c 'Memory cgroup out of memory')" -gt "$oom_base" ] && break
    sleep 1
done
oom_now="$(dmesg 2>/dev/null | grep -c 'Memory cgroup out of memory')"
say "memtest cgroup oom_kill count = ${OOMKILLS}"
DMESG_OOM="$(dmesg 2>/dev/null | grep 'Memory cgroup out of memory' | grep "${MEMTEST}" | tail -1)"
[ -z "$DMESG_OOM" ] && DMESG_OOM="$(dmesg 2>/dev/null | grep 'Memory cgroup out of memory' | tail -1)"
[ -n "$DMESG_OOM" ] && say "dmesg: ${DMESG_OOM}"
if [ "${OOMKILLS:-0}" -gt 0 ] || [ "$oom_now" -gt "$oom_base" ]; then
    say "enforcement CONFIRMED (runaway allocator OOM-killed at the 64MiB cap)"
else
    fail "no OOM kill observed — MemoryMax not enforced"
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
