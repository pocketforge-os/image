#!/usr/bin/env bash
# Hand-off table for the self-flash v3 initrd after a verified write
# (tsp-fd3619f30f92cf9c62f5). A warm `reboot -f` can fall through to the eMMC
# BOOT0 on the A133, so after a verified write the initrd prefers:
#
#   kernel kexec_load | kexec binary | cold-wake marker | action
#   ------------------+--------------+------------------+---------------------------
#   available         | present      | any              | kexec into the new target
#   available         | absent       | wired            | typed refusal, poweroff -f
#   available         | absent       | absent           | typed refusal, reboot -f
#   unavailable       | any          | wired            | poweroff -f
#   unavailable       | any          | absent/malformed | reboot -f
#   kexec load/exec failure                             | recorded fallback, reboot -f
#   failed or unverified write                          | no hand-off at all
#
# Every case runs against a file-backed card; the hand-off may only ever read it.
# shellcheck disable=SC2034  # SF_V3_* are consumed by the sourced engine
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$root/boards/tsp/initrd/self-flash-v3.sh"
init="$root/boards/tsp/initrd/init"
builder="$root/boards/tsp/initrd/build-initrd.sh"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-selfflash-v3-handoff.XXXXXX")"
trap 'find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# shellcheck source=/dev/null
. "$engine"
for function in sf_v3_handoff sf_v3_handoff_decide sf_v3_handoff_verified \
        sf_v3_kernel_kexec_load sf_v3_cold_wake_wired sf_v3_handoff_extract_target; do
    declare -F "$function" >/dev/null || fail "$function missing"
done

# ---- static wiring --------------------------------------------------------
gate="$(sed -n '/^# BEGIN POCKETFORGE SELF-FLASH V3 GATE/,/^# END POCKETFORGE SELF-FLASH V3 GATE/p' "$init")"
[ -n "$gate" ] || fail 'v3 gate block missing from init'
grep -q 'reboot -f' <<<"$gate" && fail 'v3 gate still ends a verified write with a bare reboot -f'
grep -q 'sf_v3_handoff 0' <<<"$gate" || fail 'v3 gate does not hand off after a verified write'
awk '/if sf_v3_run_armed_transaction; then/{t=1} t&&/sf_v3_handoff 0/{ok=1} t&&/^            fi$/{exit} END{exit !ok}' \
    <<<"$gate" || fail 'hand-off is not inside the verified-transaction branch'
applets="$(sed -n '/for ap in /,/; do$/p' "$builder")"
for applet in od poweroff gunzip; do
    grep -Eq "(^| )$applet( |;)" <<<"$applets" || fail "initrd applet assert lacks $applet (hand-off)"
done
if grep -E 'mmcblk[0-9]|04022000|boot0|BOOT0' <<<"$(sed -n '/^# BEGIN POCKETFORGE SELF-FLASH V3 HANDOFF/,/^# END POCKETFORGE SELF-FLASH V3 HANDOFF/p' "$engine")" \
        | grep -v '^ *#' | grep -q .; then
    fail 'hand-off code names an eMMC or fixed block device'
fi

# ---- fixture: a written target card with GPT + Android boot.img -----------
card="$tmp/card.img"
raw_bytes=$((8 * 1024 * 1024))
python3 -I - "$card" "$raw_bytes" <<'PY'
import struct, sys
path, raw = sys.argv[1], int(sys.argv[2])
card = bytearray(raw + 4 * 1024 * 1024)
hdr = bytearray(512)
hdr[0:8] = b"EFI PART"
struct.pack_into("<QII", hdr, 72, 2, 4, 128)
card[512:1024] = hdr
def entry(i, name, first, last):
    off = 1024 + i * 128
    struct.pack_into("<QQ", card, off + 32, first, last)
    enc = name.encode("utf-16-le")
    card[off + 56:off + 56 + len(enc)] = enc
entry(0, "boot-resource", 6144, 8191)
entry(1, "boot", 4096, 6143)            # 2 MiB at 2 MiB
entry(2, "env", 8192, 8200)
page = 2048
kernel = bytearray(b"K" * 5000)
kernel[56:60] = b"ARMd"
ramdisk = b"R" * 3000
bh = bytearray(page)
bh[0:8] = b"ANDROID!"
struct.pack_into("<IIIIIIII", bh, 8, len(kernel), 0x40080000, len(ramdisk),
                 0x42000000, 0, 0, 0x40000100, page)
cmd = b"console=ttyS0,115200 root=PARTLABEL=userdata rootwait"
bh[64:64 + len(cmd)] = cmd
img = bytes(bh) + bytes(kernel) + b"\0" * (page * 3 - len(kernel)) + ramdisk
start = 4096 * 512
card[start:start + len(img)] = img
open(path, "wb").write(card)
PY
expected_cmdline='console=ttyS0,115200 root=PARTLABEL=userdata rootwait'
card_sha="$(sha256sum "$card" | cut -d' ' -f1)"

bin="$tmp/bin"
mkdir -p "$bin"
calls="$tmp/calls"
for cmd in reboot poweroff; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"%s"\nexit 0\n' "$cmd" "$calls" >"$bin/$cmd"
    chmod 0755 "$bin/$cmd"
done
kexec_stub="$tmp/kexec"
# load_rc / exec_rc control the stub; a successful -e never returns in reality,
# so exec_rc=0 here models "kexec -e returned", which is itself a failure.
cat >"$kexec_stub" <<EOF
#!/bin/sh
case "\$1" in
    -l) printf 'kexec-load %s\n' "\$*" >>"$calls"
        cp "\$2" "$tmp/kexec-kernel"
        for a in "\$@"; do case "\$a" in --initrd=*) cp "\${a#--initrd=}" "$tmp/kexec-initrd";; esac; done
        exit "\$(cat "$tmp/load_rc")" ;;
    -e) printf 'kexec-exec\n' >>"$calls"; exit "\$(cat "$tmp/exec_rc")" ;;
esac
exit 64
EOF
chmod 0755 "$kexec_stub"
PATH="$bin:$PATH"

sysfs="$tmp/kexec_loaded" disabled="$tmp/kexec_load_disabled" cold="$tmp/cold-wake"
setup() {
    # $1 kernel(yes|no|disabled) $2 binary(yes|no) $3 cold(wired|absent|malformed)
    : >"$calls"
    printf 0 >"$tmp/load_rc"; printf 0 >"$tmp/exec_rc"
    rm -f "$sysfs" "$disabled" "$cold" "$tmp/kexec-kernel" "$tmp/kexec-initrd"
    case "$1" in
        yes) printf '0\n' >"$sysfs"; printf '0\n' >"$disabled" ;;
        disabled) printf '0\n' >"$sysfs"; printf '1\n' >"$disabled" ;;
        no) ;;
    esac
    SF_V3_KEXEC_LOADED_SYSFS="$sysfs" SF_V3_KEXEC_LOAD_DISABLED="$disabled"
    SF_V3_KERNEL_CONFIG_GZ="$tmp/no-config.gz"
    if [ "$2" = yes ]; then SF_V3_KEXEC_BIN="$kexec_stub"; else SF_V3_KEXEC_BIN="$tmp/absent-kexec"; fi
    case "$3" in
        wired) printf 'Schema=pocketforge.cold-wake/v1\nColdWake=wired\n' >"$cold" ;;
        malformed) printf 'Schema=pocketforge.cold-wake/v1\nColdWake=maybe\n' >"$cold" ;;
        absent) ;;
    esac
    SF_V3_COLD_WAKE_MARKER="$cold"
    exec 9<"$card"
    SF_V3_SD_IO=/proc/self/fd/9
    SF_V3_WORK="$tmp/work"; rm -rf "$SF_V3_WORK"; mkdir -p "$SF_V3_WORK"
    SF_V3_TARGET_RAW_BYTES="$raw_bytes"
    SF_V3_TARGET_RAW_SHA256="$(printf target | sha256sum | cut -d' ' -f1)"
    SF_V3_RAW_STREAM_SHA256="$SF_V3_TARGET_RAW_SHA256" SF_V3_RAW_STREAM_BYTES="$raw_bytes"
    SF_V3_XZ_RESULT=pass SF_V3_WRITE_RESULT=pass SF_V3_STAMP_RESULT=pass
}

run_case() {
    # $1 name  $2 expected rc of sf_v3_handoff  $3 expected decision  $4 grep for calls
    local name=$1 want_rc=$2 want_mode=$3 want_calls=$4 rc=0
    sf_v3_handoff 0 2>"$tmp/markers" || rc=$?
    [ "$rc" = "$want_rc" ] || fail "$name: rc=$rc want $want_rc ($(cat "$tmp/markers"))"
    [ "${SF_V3_HANDOFF_MODE:-}" = "$want_mode" ] || fail "$name: mode=${SF_V3_HANDOFF_MODE:-} want $want_mode"
    [ "$(tr '\n' ';' <"$calls")" = "$want_calls" ] || fail "$name: calls=$(tr '\n' ';' <"$calls") want $want_calls"
    grep -q "^PF_SELF_FLASH_V3_HANDOFF decision=$want_mode " "$tmp/markers" \
        || fail "$name: no typed decision marker"
    [ "$(sha256sum "$card" | cut -d' ' -f1)" = "$card_sha" ] || fail "$name: hand-off wrote the card"
}

# kexec available + binary present: load the NEW target kernel/initrd/cmdline.
setup yes yes absent
run_case kexec 1 kexec "kexec-load -l $SF_V3_WORK/handoff/kernel --initrd=$SF_V3_WORK/handoff/ramdisk --command-line=$expected_cmdline;kexec-exec;reboot -f;"
grep -q '^PF_SELF_FLASH_V3_HANDOFF_FALLBACK from=kexec to=reboot reason=kexec_exec_returned$' "$tmp/markers" \
    || fail 'kexec -e returning is not recorded as a fallback'
[ "$(head -c 8 "$tmp/kexec-kernel")" = KKKKKKKK ] && [ "$(stat -c %s "$tmp/kexec-kernel")" = 5000 ] \
    || fail 'kexec kernel is not the target boot.img kernel'
[ "$(stat -c %s "$tmp/kexec-initrd")" = 3000 ] && [ "$(head -c 4 "$tmp/kexec-initrd")" = RRRR ] \
    || fail 'kexec initrd is not the target boot.img ramdisk'

# kexec preferred even when cold wake is wired.
setup yes yes wired
run_case kexec-over-cold 1 kexec "kexec-load -l $SF_V3_WORK/handoff/kernel --initrd=$SF_V3_WORK/handoff/ramdisk --command-line=$expected_cmdline;kexec-exec;reboot -f;"

# kexec load failure: recorded fallback to reboot -f (never poweroff).
setup yes yes wired
printf 1 >"$tmp/load_rc"
run_case kexec-load-fail 1 kexec "kexec-load -l $SF_V3_WORK/handoff/kernel --initrd=$SF_V3_WORK/handoff/ramdisk --command-line=$expected_cmdline;reboot -f;"
grep -q '^PF_SELF_FLASH_V3_HANDOFF_FALLBACK from=kexec to=reboot reason=kexec_load_failed$' "$tmp/markers" \
    || fail 'kexec load failure is not recorded'

# Unreadable target boot image: recorded fallback, kexec never invoked.
setup yes yes absent
SF_V3_TARGET_RAW_BYTES=$((3 * 1024 * 1024 - 512)) SF_V3_RAW_STREAM_BYTES=$((3 * 1024 * 1024 - 512))  # boot partition ends past the written range
run_case kexec-target-outside 1 kexec "reboot -f;"
grep -q '^PF_SELF_FLASH_V3_HANDOFF_FALLBACK from=kexec to=reboot reason=target_boot_image_invalid$' "$tmp/markers" \
    || fail 'invalid target boot image is not recorded'

# kexec_load available but binary absent: typed refusal, then the cold ladder.
setup yes no wired
run_case binary-absent-cold 1 poweroff "poweroff -f;"
grep -q '^PF_SELF_FLASH_V3_HANDOFF_REFUSED mode=kexec reason=kexec_binary_absent$' "$tmp/markers" \
    || fail 'absent kexec binary is not a typed refusal'
setup yes no absent
run_case binary-absent 1 reboot "reboot -f;"
grep -q '^PF_SELF_FLASH_V3_HANDOFF_REFUSED mode=kexec reason=kexec_binary_absent$' "$tmp/markers" \
    || fail 'absent kexec binary is not a typed refusal (reboot ladder)'

# Kernel without kexec_load (or with it disabled).
setup no yes wired
run_case no-kexec-cold 1 poweroff "poweroff -f;"
setup no yes absent
run_case no-kexec 1 reboot "reboot -f;"
grep -q 'kexec_reason=kexec_core_absent' "$tmp/markers" || fail 'kernel capability reason missing'
setup disabled yes absent
run_case kexec-disabled 1 reboot "reboot -f;"
grep -q 'kexec_reason=kexec_load_disabled' "$tmp/markers" || fail 'disabled kexec_load reason missing'
setup no yes malformed
run_case cold-malformed 1 reboot "reboot -f;"
setup no no absent
printf 'Schema=pocketforge.cold-wake/v1\nColdWake=wired\nExtra=1\n' >"$cold"
run_case cold-extended 1 reboot "reboot -f;"
setup no no absent
ln -s "$tmp/real-cold" "$cold"; printf 'Schema=pocketforge.cold-wake/v1\nColdWake=wired\n' >"$tmp/real-cold"
run_case cold-symlink 1 reboot "reboot -f;"
rm -f "$tmp/real-cold"

# Kernel config, when exposed, must say CONFIG_KEXEC=y.
setup yes yes absent
printf '# CONFIG_KEXEC is not set\nCONFIG_KEXEC_CORE=y\nCONFIG_KEXEC_FILE=y\n' | gzip -c >"$tmp/config.gz"
SF_V3_KERNEL_CONFIG_GZ="$tmp/config.gz"
run_case kexec-file-only 1 reboot "reboot -f;"
grep -q 'kexec_reason=kexec_load_not_configured' "$tmp/markers" || fail 'KEXEC_FILE-only kernel admitted'

# No hand-off after a failed or unverified write.
expect_no_handoff() {
    local name=$1 status=$2 rc=0
    sf_v3_handoff "$status" 2>"$tmp/markers" || rc=$?
    [ "$rc" = 2 ] || fail "$name: unverified write rc=$rc want 2"
    [ ! -s "$calls" ] || fail "$name: hand-off acted after an unverified write: $(cat "$calls")"
    grep -q '^PF_SELF_FLASH_V3_HANDOFF_REFUSED mode=any reason=write_not_verified$' "$tmp/markers" \
        || fail "$name: unverified refusal not typed"
}
setup yes yes wired; expect_no_handoff transaction-failed 1
setup yes yes wired; SF_V3_WRITE_RESULT=fail; expect_no_handoff write-fail 0
setup yes yes wired; SF_V3_XZ_RESULT=fail; expect_no_handoff xz-fail 0
setup yes yes wired; SF_V3_STAMP_RESULT=fail; expect_no_handoff stamp-fail 0
setup yes yes wired; SF_V3_RAW_STREAM_SHA256=unknown; expect_no_handoff sha-unknown 0
setup yes yes wired; SF_V3_RAW_STREAM_BYTES=$((raw_bytes - 1)); expect_no_handoff bytes-short 0
setup yes yes wired; SF_V3_SD_IO=""; expect_no_handoff no-card 0

printf 'SELF_FLASH_V3_HANDOFF_TEST result=PASS cases=kexec,kexec-over-cold,load-fail,target-outside,binary-absent-cold,binary-absent,no-kexec-cold,no-kexec,disabled,cold-malformed,cold-extended,cold-symlink,kexec-file-only,unverified-x7\n'
