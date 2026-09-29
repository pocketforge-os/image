#!/usr/bin/env bash
# check-libpocketforge.sh — gate the libpocketforge cdylib before it ships as
# /usr/lib/aarch64-linux-gnu/libpocketforge.so.1 (bd: tsp-f3fm.202.1 B4).
#
# Usage: check-libpocketforge.sh <libpocketforge.so> <frozen-v1-abi-file>
#   OBJDUMP / READELF select the (cross) binutils; defaults: objdump / readelf.
#
# Gates, all fatal:
#   1. a regular 64-bit little-endian aarch64 ET_DYN ELF;
#   2. `objdump -T` shows GLIBC_* symbol versions, and the highest is <= 2.36
#      (Debian bookworm's glibc, the rootfs this library is dlopened in);
#   3. every DT_NEEDED is provided by bookworm libc6 / libgcc-s1;
#   4. every frozen v1 ABI symbol, and every symbol Poolsuite's ps-platform
#      resolves with dlsym, is exported and defined.
set -euo pipefail

OBJDUMP="${OBJDUMP:-objdump}"
READELF="${READELF:-readelf}"
max_glibc=2.36
allowed_needed="libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libutil.so.1 libgcc_s.so.1 ld-linux-aarch64.so.1"
# poolsuite crates/ps-platform/src/lib.rs dlsym()s exactly these.
consumer_symbols="pf_connect pf_free pf_acquire_input_fd pf_preference_bool pf_preference_scalar pf_appearance pf_appearance_source pf_rumble_pulse"

fail() {
    echo "check-libpocketforge: FATAL: $*" >&2
    exit 1
}

[ "$#" -eq 2 ] || fail "usage: check-libpocketforge.sh <libpocketforge.so> <frozen-v1-abi-file>"
so="$1"
golden="$2"
[ -f "${so}" ] && [ ! -L "${so}" ] || fail "${so}: not a regular file"
[ -f "${golden}" ] || fail "${golden}: frozen ABI file missing"

header_hex() {
    od -An -tx1 -j "$1" -N "$2" "${so}" | tr -d ' \n'
}
[ "$(header_hex 0 4)" = 7f454c46 ] || fail "${so}: not an ELF file"
[ "$(header_hex 4 2)" = 0201 ] || fail "${so}: not a 64-bit little-endian ELF"
[ "$(header_hex 16 2)" = 0300 ] || fail "${so}: not a shared object (e_type=$(header_hex 16 2), want 0300)"
[ "$(header_hex 18 2)" = b700 ] || fail "${so}: not aarch64 (e_machine=$(header_hex 18 2), want b700)"

dynamic_symbols="$("${OBJDUMP}" -T "${so}")" || fail "${OBJDUMP} -T ${so} failed"
glibc_versions="$(grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' <<<"${dynamic_symbols}" \
    | sed 's/^GLIBC_//' | LC_ALL=C sort -u -V || true)"
[ -n "${glibc_versions}" ] || fail "${so}: objdump -T shows no GLIBC_* symbol versions (wrong libc or wrong tool)"
glibc_highest="$(tail -n 1 <<<"${glibc_versions}")"
[ "$(printf '%s\n%s\n' "${glibc_highest}" "${max_glibc}" | LC_ALL=C sort -V | tail -n 1)" = "${max_glibc}" ] \
    || fail "${so}: requires GLIBC_${glibc_highest} > GLIBC_${max_glibc} (bookworm rootfs)"

needed="$("${READELF}" -d "${so}" | awk '/\(NEEDED\)/ { gsub(/[][]/, "", $NF); print $NF }')" \
    || fail "${READELF} -d ${so} failed"
[ -n "${needed}" ] || fail "${so}: no DT_NEEDED entries (not a dynamically linked glibc object)"
while read -r library; do
    case " ${allowed_needed} " in
        *" ${library} "*) ;;
        *) fail "${so}: DT_NEEDED ${library} is outside bookworm libc6/libgcc-s1" ;;
    esac
done <<<"${needed}"

defined_exports="$(awk '
    /^DYNAMIC SYMBOL TABLE:/ { table = 1; next }
    table && NF >= 4 && $0 !~ /\*UND\*/ { print $NF }
' <<<"${dynamic_symbols}" | LC_ALL=C sort -u)"
required="$( { grep -vE '^[[:space:]]*(#|$)' "${golden}"; printf '%s\n' ${consumer_symbols}; } \
    | tr -d ' \t' | LC_ALL=C sort -u)"
missing="$(LC_ALL=C comm -23 <(printf '%s\n' "${required}") <(printf '%s\n' "${defined_exports}"))"
[ -z "${missing}" ] || fail "${so}: required symbol(s) not exported: $(tr '\n' ' ' <<<"${missing}")"

echo "check-libpocketforge: PASS glibc_max=GLIBC_${glibc_highest} (<= GLIBC_${max_glibc}) needed=$(tr '\n' ',' <<<"${needed}" | sed 's/,$//') required_exports=$(grep -c . <<<"${required}")"
