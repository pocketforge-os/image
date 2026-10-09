#!/usr/bin/env bash
# Hermetic controls for the exact volatile-root functions embedded in /init.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
init="${root}/boards/tsp/initrd/init"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-initrd-volatile.XXXXXX")"
cleanup() {
    find "$tmp" -mindepth 1 -delete
    rmdir "$tmp"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
    local got="$1" want="$2" label="$3"
    [[ "$got" == "$want" ]] || fail "$label: got '$got', want '$want'"
}

# Execute the production functions, not a test copy.
awk '
    /^# BEGIN POCKETFORGE VOLATILE ROOT FUNCTIONS$/ { copy=1; next }
    /^# END POCKETFORGE VOLATILE ROOT FUNCTIONS$/ { copy=0 }
    copy { print }
' "$init" >"$tmp/volatile-root.sh"
[[ -s "$tmp/volatile-root.sh" ]] || fail 'production volatile-root function block missing'
# shellcheck source=/dev/null
. "$tmp/volatile-root.sh"
declare -F pf_select_root_mode >/dev/null || fail 'selector function missing'
declare -F pf_mount_volatile_root >/dev/null || fail 'mount function missing'

write_cmdline() { printf '%s\n' "$1" >"$tmp/cmdline"; }
select_case() {
    write_cmdline "$1"
    PF_ROOT_MODE="unset"
    PF_ROOT_SELECTOR_MALFORMED="unset"
    pf_select_root_mode "$tmp/cmdline"
    assert_eq "$PF_ROOT_MODE" "$2" "$4 mode"
    assert_eq "$PF_ROOT_SELECTOR_MALFORMED" "$3" "$4 malformed"
}

select_case 'console=ttyS0 root=PARTLABEL=userdata' normal 0 absent
select_case 'console=ttyS0 pocketforge.root=volatile rootwait' volatile 0 valid
select_case 'pocketforge.root=' normal 1 empty
select_case 'pocketforge.root=persistent' normal 1 unknown
select_case 'pocketforge.root=volatile pocketforge.root=volatile' normal 1 duplicate
select_case 'pocketforge.root' normal 1 missing-equals

# Integration ordering: selection precedes the current writable FAT log; normal
# mode retains the exact old mount command; malformed selection logs one stable
# line before taking that path; valid setup can only fail into fail().
selector_line="$(grep -nF 'pf_select_root_mode /proc/cmdline' "$init" | cut -d: -f1)"
fat_line="$(grep -nF 'mount -t vfat -o rw,flush "$LOGDEV" /pflog' "$init" | cut -d: -f1)"
[[ -n "$selector_line" && -n "$fat_line" && "$selector_line" -lt "$fat_line" ]] \
    || fail 'selector does not precede the writable FAT log mount'
grep -Fqx '    log "STAGE: malformed pocketforge.root selector; using normal root"' "$init" \
    || fail 'malformed-selector log line drifted'
grep -Fqx '    mount -t ext4 -o rw,noatime "$ROOT" /newroot || fail "mount $ROOT failed"' "$init" \
    || fail 'normal-root mount command changed'
grep -Fqx '    pf_mount_volatile_root "$ROOT" /newroot || fail "volatile root setup failed: ${PF_VOLATILE_ERROR}"' "$init" \
    || fail 'volatile setup does not fail into the initrd shell'
grep -Fqx 'if [ "$PF_ROOT_MODE" != volatile ] && [ -f /etc/pocketforge-selfflash ]; then' "$init" \
    || fail 'volatile mode can reach the persistent self-flash gate'

PF_VOLATILE_RUN_ROOT="$tmp/run"
PF_VOLATILE_LOWER_ROOT="$tmp/lower"
PF_VOLATILE_MOUNTINFO="$tmp/mountinfo"
PF_VOLATILE_BOOT_ID_FILE="$tmp/boot-id"
export PF_VOLATILE_RUN_ROOT PF_VOLATILE_LOWER_ROOT PF_VOLATILE_MOUNTINFO \
    PF_VOLATILE_BOOT_ID_FILE
boot_id=01234567-89ab-4cde-8fab-0123456789ab
printf '%s\n' "$boot_id" >"$PF_VOLATILE_BOOT_ID_FILE"
events="$tmp/events"
block_ro="$tmp/block-ro"
printf '0\n' >"$block_ro"

run_mounted=0
lower_mounted=0
overlay_mounted=0
run_moved=0
lower_moved=0
bad_topology=0
fail_overlay=0
root_device=/dev/mmcblk0p5
newroot="$tmp/newroot"

write_mountinfo() {
    local run_fs=tmpfs
    [[ "$bad_topology" == 0 ]] || run_fs=ext4
    : >"$PF_VOLATILE_MOUNTINFO"
    if [[ "$overlay_mounted" == 1 ]]; then
        printf '42 1 0:42 / %s rw,relatime - overlay overlay rw\n' "$newroot" \
            >>"$PF_VOLATILE_MOUNTINFO"
    fi
    if [[ "$run_mounted" == 1 ]]; then
        local run_path="$PF_VOLATILE_RUN_ROOT"
        [[ "$run_moved" == 0 ]] || run_path="$newroot/run"
        printf '40 1 0:40 / %s rw,nosuid,nodev - %s tmpfs rw\n' "$run_path" "$run_fs" \
            >>"$PF_VOLATILE_MOUNTINFO"
    fi
    if [[ "$lower_mounted" == 1 ]]; then
        local lower_path="$PF_VOLATILE_LOWER_ROOT"
        [[ "$lower_moved" == 0 ]] \
            || lower_path="$newroot/run/pf-kit-session/$boot_id/lower"
        printf '41 1 179:5 / %s ro,noatime - ext4 %s ro\n' "$lower_path" "$root_device" \
            >>"$PF_VOLATILE_MOUNTINFO"
    fi
}

blockdev() {
    printf 'blockdev %s\n' "$*" >>"$events"
    case "$1" in
        --setro) printf '1\n' >"$block_ro" ;;
        --getro) cat "$block_ro" ;;
        *) return 2 ;;
    esac
}

mount() {
    printf 'mount %s\n' "$*" >>"$events"
    if [[ "$1:$2" == -o:move ]]; then
        if [[ "$3" == "$PF_VOLATILE_RUN_ROOT" ]]; then
            run_moved=1
        elif [[ "$3" == "$PF_VOLATILE_LOWER_ROOT" ]]; then
            lower_moved=1
        else
            return 2
        fi
        write_mountinfo
        return 0
    fi
    case "$1:$2" in
        -t:ext4) lower_mounted=1 ;;
        -t:tmpfs) run_mounted=1 ;;
        -t:overlay)
            [[ "$fail_overlay" == 0 ]] || return 1
            overlay_mounted=1
            ;;
        *) return 2 ;;
    esac
    write_mountinfo
}

reset_fake() {
    : >"$events"
    : >"$PF_VOLATILE_MOUNTINFO"
    printf '0\n' >"$block_ro"
    run_mounted=0
    lower_mounted=0
    overlay_mounted=0
    run_moved=0
    lower_moved=0
    bad_topology=0
    fail_overlay=0
    PF_VOLATILE_ERROR=''
    mkdir -p "$newroot/run"
}

# Positive control: exact overlay/RO/same-tmpfs topology passes, and no writable
# root mount appears anywhere in the operation log.
reset_fake
pf_mount_volatile_root "$root_device" "$newroot" \
    || fail "valid topology rejected: $PF_VOLATILE_ERROR"
grep -Fqx "blockdev --setro $root_device" "$events" || fail 'BLKROSET missing'
grep -Fqx "mount -t ext4 -o ro,noload,noatime $root_device $PF_VOLATILE_LOWER_ROOT" "$events" \
    || fail 'read-only noload lower mount missing'
grep -Fqx "mount -o move $PF_VOLATILE_RUN_ROOT $newroot/run" "$events" \
    || fail 'boot tmpfs not moved into the new root'
grep -Fqx "mount -o move $PF_VOLATILE_LOWER_ROOT $newroot/run/pf-kit-session/$boot_id/lower" "$events" \
    || fail 'lower witness not moved into the new root'
! grep -F 'rw,noatime' "$events" >/dev/null || fail 'volatile setup mounted a writable root'

# Negative controls: an operation failure and a mountinfo mismatch both refuse;
# neither can invoke the normal writable mount as a fallback.
reset_fake
fail_overlay=1
if pf_mount_volatile_root "$root_device" "$newroot"; then
    fail 'overlay mount failure was accepted'
fi
assert_eq "$PF_VOLATILE_ERROR" overlay-mount 'overlay failure reason'
! grep -F 'rw,noatime' "$events" >/dev/null || fail 'failure fell through to writable root'

reset_fake
bad_topology=1
if pf_mount_volatile_root "$root_device" "$newroot"; then
    fail 'non-tmpfs upper/work mountinfo was accepted'
fi
assert_eq "$PF_VOLATILE_ERROR" topology-check 'topology failure reason'
! grep -F 'rw,noatime' "$events" >/dev/null || fail 'topology failure fell through to writable root'

printf 'PASS: initrd volatile root selects strictly, preserves normal mode, verifies overlay/RO/tmpfs topology, and fails closed\n'
