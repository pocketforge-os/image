#!/usr/bin/env bash
# Hermetic tests for the two B4 build gates (bd: tsp-f3fm.202.1.4):
#   scripts/check-device-descriptor.sh — the B3 platform-inputs consume contract;
#   scripts/check-libpocketforge.sh    — the libpocketforge.so.1 cdylib gate.
# Fake binutils are passed by explicit absolute path (OBJDUMP/READELF), never via PATH.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
descriptor_gate="${root}/scripts/check-device-descriptor.sh"
library_gate="${root}/scripts/check-libpocketforge.sh"
tmp="$(mktemp -d)"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT

expect_fatal() {
    local reason="$1"
    shift
    if "$@" >"${tmp}/out" 2>"${tmp}/err"; then
        echo "FAIL: expected refusal (${reason}): $*" >&2
        exit 1
    fi
    grep -Fq -- "${reason}" "${tmp}/err" || {
        echo "FAIL: refusal reason missing (${reason}); got:" >&2
        cat "${tmp}/err" >&2
        exit 1
    }
}

# --- check-device-descriptor.sh ------------------------------------------------
inputs="${tmp}/inputs"
mkdir -p "${inputs}/devices/a133"
printf '[identity]\nid = "a133"\n' > "${inputs}/devices/a133/capabilities.toml"
sha="$(sha256sum "${inputs}/devices/a133/capabilities.toml" | cut -d' ' -f1)"
empty="${tmp}/empty-inputs"
mkdir -p "${empty}"

# Positive controls: open resolves exactly the one file; non-open is silent.
test "$("${descriptor_gate}" open "${inputs}" a133 "${sha}")" = "${inputs}/devices/a133/capabilities.toml"
for gpu_model in ddk none; do
    test -z "$("${descriptor_gate}" "${gpu_model}" "${empty}" '' '')"
done

# Non-open leaks: the ID, the digest, or a staged tree.
expect_fatal 'PF_DEVICE_DESCRIPTOR_ID set on a non-open profile: a133' \
    "${descriptor_gate}" ddk "${empty}" a133 ''
expect_fatal 'PF_DEVICE_DESCRIPTOR_SHA256 set on a non-open profile' \
    "${descriptor_gate}" none "${empty}" '' "${sha}"
expect_fatal 'platform-inputs staged for a non-open profile' \
    "${descriptor_gate}" ddk "${inputs}" '' ''

# Open refusals: renderer on with no ID, a foreign ID, a bad or mismatched digest,
# a missing/symlinked file, or any extra staged entry.
expect_fatal 'A133-open build has no PF_DEVICE_DESCRIPTOR_ID' \
    "${descriptor_gate}" open "${inputs}" '' "${sha}"
mkdir -p "${tmp}/a523/devices/a523"
cp "${inputs}/devices/a133/capabilities.toml" "${tmp}/a523/devices/a523/capabilities.toml"
expect_fatal 'unexpected PF_DEVICE_DESCRIPTOR_ID=a523' \
    "${descriptor_gate}" open "${tmp}/a523" a523 "${sha}"
expect_fatal 'malformed PF_DEVICE_DESCRIPTOR_SHA256' \
    "${descriptor_gate}" open "${inputs}" a133 "${sha:0:63}"
expect_fatal "descriptor sha256 ${sha} != PF_DEVICE_DESCRIPTOR_SHA256 $(printf '0%.0s' {1..64})" \
    "${descriptor_gate}" open "${inputs}" a133 "$(printf '0%.0s' {1..64})"
expect_fatal 'staged descriptor missing or not a regular file' \
    "${descriptor_gate}" open "${empty}" a133 "${sha}"
mkdir -p "${tmp}/linked/devices/a133"
ln -s "${inputs}/devices/a133/capabilities.toml" "${tmp}/linked/devices/a133/capabilities.toml"
expect_fatal 'staged descriptor missing or not a regular file' \
    "${descriptor_gate}" open "${tmp}/linked" a133 "${sha}"
printf 'extra\n' > "${inputs}/devices/a133/profile.toml"
expect_fatal 'platform-inputs holds more than the one descriptor' \
    "${descriptor_gate}" open "${inputs}" a133 "${sha}"
rm "${inputs}/devices/a133/profile.toml"
test "$("${descriptor_gate}" open "${inputs}" a133 "${sha}")" = "${inputs}/devices/a133/capabilities.toml"

# --- check-libpocketforge.sh ---------------------------------------------------
golden="${tmp}/libpocketforge.v1.abi"
printf '%s\n' '# frozen v1' '' pf_acquire pf_acquire_input_fd pf_connect pf_free pf_rumble_pulse > "${golden}"
elf() {
    # 64-byte ELF header: magic, ELFCLASS64, little-endian, e_type ($2), e_machine ($3).
    dd if=/dev/zero of="$1" bs=64 count=1 status=none
    printf '\177ELF\002\001' | dd of="$1" bs=1 conv=notrunc status=none
    printf "$2" | dd of="$1" bs=1 seek=16 conv=notrunc status=none
    printf "$3" | dd of="$1" bs=1 seek=18 conv=notrunc status=none
}
so="${tmp}/libpocketforge.so"
elf "${so}" '\003\000' '\267\000'

fake_objdump="${tmp}/fake-objdump"
fake_readelf="${tmp}/fake-readelf"
cat > "${fake_objdump}" <<'SH'
#!/bin/sh
[ "$1" = -T ] || exit 64
cat "${FAKE_OBJDUMP_OUTPUT:?}"
SH
cat > "${fake_readelf}" <<'SH'
#!/bin/sh
[ "$1" = -d ] || exit 64
cat "${FAKE_READELF_OUTPUT:?}"
SH
chmod 0755 "${fake_objdump}" "${fake_readelf}"

symbols="${tmp}/objdump.txt"
dynamic="${tmp}/readelf.txt"
write_symbols() {
    local glibc="$1" omit="${2:-}" symbol
    {
        printf '\n%s:     file format elf64-littleaarch64\n\nDYNAMIC SYMBOL TABLE:\n' "${so}"
        printf '0000000000000000      DF *UND*\t0000000000000000 (GLIBC_2.17) write\n'
        printf '0000000000000000      DF *UND*\t0000000000000000 (GLIBC_%s) pthread_create\n' "${glibc}"
        printf '0000000000000000      DF *UND*\t0000000000000000 (GCC_3.0)    _Unwind_Resume\n'
        printf '0000000000000000      DF *UND*\t0000000000000000  Base        pf_undefined_import\n'
        for symbol in pf_acquire pf_acquire_input_fd pf_connect pf_free pf_rumble_pulse \
            pf_preference_bool pf_preference_scalar pf_appearance pf_appearance_source; do
            [ "${symbol}" != "${omit}" ] || continue
            printf '0000000000012340 g    DF .text\t0000000000000054  Base        %s\n' "${symbol}"
        done
    } > "${symbols}"
}
write_needed() {
    {
        printf '\nDynamic section at offset 0xed8d0 contains 30 entries:\n'
        printf '  Tag        Type                         Name/Value\n'
        for library in "$@"; do
            printf ' 0x0000000000000001 (NEEDED)             Shared library: [%s]\n' "${library}"
        done
        printf ' 0x000000000000000c (INIT)               0x12000\n'
    } > "${dynamic}"
}
gate() {
    FAKE_OBJDUMP_OUTPUT="${symbols}" FAKE_READELF_OUTPUT="${dynamic}" \
        OBJDUMP="${fake_objdump}" READELF="${fake_readelf}" \
        "${library_gate}" "$@"
}

# Positive control at the boundary: GLIBC_2.36 is the rootfs glibc and passes.
write_symbols 2.36
write_needed libgcc_s.so.1 libc.so.6
gate "${so}" "${golden}" > "${tmp}/pass"
grep -Fq 'check-libpocketforge: PASS glibc_max=GLIBC_2.36 (<= GLIBC_2.36) needed=libgcc_s.so.1,libc.so.6 required_exports=9' "${tmp}/pass"
# 2.4 sorts numerically below 2.36 (version sort, not lexical).
write_symbols 2.4
gate "${so}" "${golden}" | grep -Fq 'glibc_max=GLIBC_2.17'

write_symbols 2.37
expect_fatal 'requires GLIBC_2.37 > GLIBC_2.36' gate "${so}" "${golden}"
write_symbols 3.0
expect_fatal 'requires GLIBC_3.0 > GLIBC_2.36' gate "${so}" "${golden}"
write_symbols 2.34 pf_appearance_source
expect_fatal 'required symbol(s) not exported: pf_appearance_source' gate "${so}" "${golden}"
write_symbols 2.34 pf_acquire
expect_fatal 'required symbol(s) not exported: pf_acquire' gate "${so}" "${golden}"
write_symbols 2.34
write_needed libgcc_s.so.1 libc.so.6 libssl.so.3
expect_fatal 'DT_NEEDED libssl.so.3 is outside bookworm libc6/libgcc-s1' gate "${so}" "${golden}"
write_needed
expect_fatal 'no DT_NEEDED entries' gate "${so}" "${golden}"
write_needed libc.so.6
printf '\nDYNAMIC SYMBOL TABLE:\n0000000000012340 g    DF .text\t0000000000000054  Base        pf_connect\n' > "${symbols}"
expect_fatal 'shows no GLIBC_* symbol versions' gate "${so}" "${golden}"
write_symbols 2.34
elf "${so}" '\003\000' '\076\000'
expect_fatal 'not aarch64 (e_machine=3e00, want b700)' gate "${so}" "${golden}"
elf "${so}" '\002\000' '\267\000'
expect_fatal 'not a shared object (e_type=0200, want 0300)' gate "${so}" "${golden}"
printf 'not an elf' > "${so}"
expect_fatal 'not an ELF file' gate "${so}" "${golden}"
elf "${so}" '\003\000' '\267\000'
ln -s "${so}" "${tmp}/linked.so"
expect_fatal 'not a regular file' gate "${tmp}/linked.so" "${golden}"
gate "${so}" "${golden}" >/dev/null

echo 'default-app input gates: PASS (descriptor contract open/non-open, 10 refusals; libpocketforge glibc<=2.36 boundary, version sort, exports, DT_NEEDED, ELF identity)'
