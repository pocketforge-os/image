#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
verifier="${root}/scripts/verify-mesa-shader-cache.sh"
fixture_dir="${root}/tests/fixtures/mesa-shader-cache"
builder="${root}/scripts/build-rootfs.sh"
workflow="${root}/.github/workflows/hermetic-tests.yml"
cc_bin="${CC:-cc}"

command -v "${cc_bin}" >/dev/null 2>&1 || {
    echo "C compiler is unavailable: ${cc_bin}" >&2
    exit 1
}

tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/mesa-shader-cache-test.XXXXXX")"
cleanup() {
    find "${tmp}" -mindepth 1 -delete
    rmdir "${tmp}"
}
trap cleanup EXIT

"${cc_bin}" -shared -fPIC \
    -Wl,-soname,libzstd.so.1 \
    "${fixture_dir}/zstd-stub.c" \
    -o "${tmp}/libzstd.so.1"

build_fixture() {
    output=$1
    shift
    "${cc_bin}" -shared -fPIC "$@" \
        "${fixture_dir}/gallium-cache-fixture.c" \
        -L"${tmp}" -Wl,--no-as-needed -l:libzstd.so.1 \
        -Wl,-rpath,'$ORIGIN' \
        -o "${output}"
}

build_fixture "${tmp}/cache-enabled.so" -DENABLE_SHADER_CACHE
build_fixture "${tmp}/cache-disabled.so"
build_fixture "${tmp}/cache-no-zstd-symbols.so" \
    -DENABLE_SHADER_CACHE -DOMIT_ZSTD_CALLS
"${cc_bin}" -shared -fPIC \
    -DENABLE_SHADER_CACHE -DOMIT_ZSTD_CALLS \
    "${fixture_dir}/gallium-cache-fixture.c" \
    -o "${tmp}/cache-no-zstd-needed.so"

[ -x "${verifier}" ] || {
    echo "Mesa shader-cache verifier is missing or not executable: ${verifier}" >&2
    exit 1
}

"${verifier}" "${tmp}/cache-enabled.so" >"${tmp}/positive.log"
grep -F 'cache_witness="zink: Failed to create disk cache queue"' \
    "${tmp}/positive.log" >/dev/null
grep -F 'zstd_soname=libzstd.so.1' "${tmp}/positive.log" >/dev/null
grep -F 'zstd_symbols=ZSTD_compress,ZSTD_decompress' \
    "${tmp}/positive.log" >/dev/null

if "${verifier}" "${tmp}/cache-disabled.so" >"${tmp}/disabled.log" 2>&1; then
    echo 'shader-cache verifier accepted a cache-disabled Gallium fixture' >&2
    exit 1
fi
grep -F 'compiled Zink shader-cache witness is absent' \
    "${tmp}/disabled.log" >/dev/null

if "${verifier}" "${tmp}/cache-no-zstd-symbols.so" \
    >"${tmp}/no-zstd-symbols.log" 2>&1; then
    echo 'shader-cache verifier accepted a fixture without zstd calls' >&2
    exit 1
fi
grep -F 'required undefined symbol is absent: ZSTD_compress' \
    "${tmp}/no-zstd-symbols.log" >/dev/null

if "${verifier}" "${tmp}/cache-no-zstd-needed.so" \
    >"${tmp}/no-zstd-needed.log" 2>&1; then
    echo 'shader-cache verifier accepted a fixture without zstd DT_NEEDED' >&2
    exit 1
fi
grep -F 'required DT_NEEDED entry is absent: libzstd.so.1' \
    "${tmp}/no-zstd-needed.log" >/dev/null

test "$(grep -Fc '/scripts/verify-mesa-shader-cache.sh' "${builder}")" -eq 2
test "$(grep -Fxc '            tests/test-mesa-shader-cache.sh' "${workflow}")" -eq 1

echo 'mesa-shader-cache-gate=PASS positive=enabled negative=compiled-out,zstd-needed-absent,zstd-calls-absent'
