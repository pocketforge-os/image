#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/build/prepare-sdl-kmsdrm-sysroot.sh"
DOCKERFILE="${ROOT}/build/Dockerfile.pf"
TMPDIR_TEST="$(mktemp -d)"
trap 'find "${TMPDIR_TEST}" -mindepth 1 -delete; rmdir "${TMPDIR_TEST}"' EXIT

# Fixture metadata and structural checks intentionally preserve literal shell
# and pkg-config variables.

make_fixture() {
    local fixture=$1
    local source_lib="${fixture}/system/usr/lib/aarch64-linux-gnu"
    local source_include="${fixture}/system/usr/include"

    mkdir -p "${source_lib}/pkgconfig" "${source_include}/libdrm" \
        "${fixture}/system/etc/apt/sources.list.d" "${fixture}/system/etc"
    printf '%s\n' '20260601T000000Z' >"${fixture}/system/etc/pocketforge-apt-snapshot-date"
    printf '%s\n' \
        'deb [arch=amd64] http://snapshot.debian.org/archive/debian/20260601T000000Z/ bookworm main' \
        'deb [arch=arm64] http://snapshot.debian.org/archive/debian/20260601T000000Z/ bookworm main' \
        >"${fixture}/system/etc/apt/sources.list"

    printf '%s\n' 'int pocketforge_fixture(void) { return 0; }' >"${fixture}/fixture.c"
    aarch64-linux-gnu-gcc -shared -fPIC "${fixture}/fixture.c" -o "${source_lib}/libdrm.so.2.4.0"
    aarch64-linux-gnu-gcc -shared -fPIC "${fixture}/fixture.c" -o "${source_lib}/libgbm.so.1.0.0"
    ln -s libdrm.so.2.4.0 "${source_lib}/libdrm.so"
    ln -s libgbm.so.1.0.0 "${source_lib}/libgbm.so"

    printf '%s\n' \
        'prefix=/usr' \
        'libdir=/usr/lib/aarch64-linux-gnu' \
        'includedir=/usr/include' \
        'Name: libdrm' \
        'Description: target DRM fixture' \
        'Version: 2.4.114' \
        'Libs: -L${libdir} -ldrm' \
        'Cflags: -I${includedir} -I${includedir}/libdrm' \
        >"${source_lib}/pkgconfig/libdrm.pc"
    printf '%s\n' \
        'prefix=/usr' \
        'libdir=${prefix}/lib/aarch64-linux-gnu' \
        'includedir=${prefix}/include' \
        'Name: gbm' \
        'Description: target GBM fixture' \
        'Version: 22.3.6' \
        'Libs: -L${libdir} -lgbm' \
        'Cflags: -I${includedir}' \
        >"${source_lib}/pkgconfig/gbm.pc"
    printf '%s\n' \
        'prefix=/usr' \
        'libdir=${prefix}/lib/aarch64-linux-gnu' \
        'includedir=/usr/include' \
        'Name: libkms' \
        'Description: optional target KMS fixture' \
        'Version: 2.4.114' \
        'Libs: -L${libdir} -lkms' \
        'Cflags: -I${includedir}' \
        >"${source_lib}/pkgconfig/libkms.pc"
    for header in gbm.h xf86drm.h xf86drmMode.h; do
        printf '%s\n' '/* target ARM64 fixture */' >"${source_include}/${header}"
    done
    printf '%s\n' '/* target libdrm fixture */' >"${source_include}/libdrm/drm.h"
}

run_helper() {
    local fixture=$1
    local target=$2
    PF_SDL_SYSTEM_ROOT="${fixture}/system" \
    PF_SDL_TARGET_SYSROOT="${target}" \
    PF_SDL_EXPECTED_SNAPSHOT_FILE="${ROOT}/snapshot-date.txt" \
    PF_SDL_SKIP_APT=1 \
    PF_SDL_READELF="$(command -v aarch64-linux-gnu-readelf)" \
        "${HELPER}"
}

positive="${TMPDIR_TEST}/positive"
make_fixture "${positive}"
run_helper "${positive}" "${positive}/target"
export PKG_CONFIG_LIBDIR="${positive}/target/usr/lib/pkgconfig"
unset PKG_CONFIG_PATH
for module in libdrm gbm libkms; do
    test "$(pkg-config --variable=pcfiledir "${module}")" = "${PKG_CONFIG_LIBDIR}"
    test "$(pkg-config --variable=libdir "${module}")" = "${positive}/target/usr/lib"
    test "$(pkg-config --variable=includedir "${module}")" = "${positive}/target/usr/include"
done
for header in gbm.h xf86drm.h xf86drmMode.h libdrm/drm.h; do
    test -f "${positive}/target/usr/include/${header}"
done
aarch64-linux-gnu-readelf -h "${positive}/target/usr/lib/libgbm.so" | grep -Eq 'Machine:[[:space:]]+AArch64'

missing_gbm="${TMPDIR_TEST}/missing-gbm"
make_fixture "${missing_gbm}"
rm "${missing_gbm}/system/usr/include/gbm.h"
if run_helper "${missing_gbm}" "${missing_gbm}/target" >/dev/null 2>&1; then
    echo 'FAIL: production preparation accepted a missing target GBM header' >&2
    exit 1
fi

host_metadata="${TMPDIR_TEST}/host-metadata"
make_fixture "${host_metadata}"
sed -i 's|libdir=${prefix}/lib/aarch64-linux-gnu|libdir=/usr/lib/x86_64-linux-gnu|' \
    "${host_metadata}/system/usr/lib/aarch64-linux-gnu/pkgconfig/gbm.pc"
if run_helper "${host_metadata}" "${host_metadata}/target" >/dev/null 2>&1; then
    echo 'FAIL: production preparation accepted host GBM metadata' >&2
    exit 1
fi

floating="${TMPDIR_TEST}/floating"
make_fixture "${floating}"
sed -i 's|snapshot.debian.org/archive/debian/20260601T000000Z|deb.debian.org/debian|' \
    "${floating}/system/etc/apt/sources.list"
if run_helper "${floating}" "${floating}/target" >/dev/null 2>&1; then
    echo 'FAIL: production preparation accepted non-frozen apt sources' >&2
    exit 1
fi

deb822="${TMPDIR_TEST}/deb822"
make_fixture "${deb822}"
printf '%s\n' 'Types: deb' 'URIs: http://deb.debian.org/debian' \
    >"${deb822}/system/etc/apt/sources.list.d/host.sources"
if run_helper "${deb822}" "${deb822}/target" >/dev/null 2>&1; then
    echo 'FAIL: production preparation accepted an unvalidated deb822 apt source' >&2
    exit 1
fi

grep -F 'apt-get install -y --no-install-recommends libgbm-dev:arm64' "${HELPER}" >/dev/null
grep -F 'find "${SYSTEM_ROOT}/var/lib/apt/lists"' "${HELPER}" >/dev/null
sdl_block="$(sed -n "/^RUN <<'SDL'$/,/^SDL$/p" "${DOCKERFILE}")"
test "$(printf '%s\n' "${sdl_block}" | grep -Fc '/usr/local/bin/prepare-sdl-kmsdrm-sysroot')" -eq 1
prepare_line="$(printf '%s\n' "${sdl_block}" | grep -nF '  /usr/local/bin/prepare-sdl-kmsdrm-sysroot' | cut -d: -f1)"
soc_exit_line="$(printf '%s\n' "${sdl_block}" | grep -nF 'if [ "${PF_SOC}" != "sun50iw10p1" ]; then' | cut -d: -f1)"
none_exit_line="$(printf '%s\n' "${sdl_block}" | grep -nF 'if [ "${PF_GPU_MODEL}" = "none" ]; then' | cut -d: -f1)"
open_line="$(printf '%s\n' "${sdl_block}" | grep -nF 'if [ "${PF_GPU_MODEL}" = "open" ]; then' | cut -d: -f1)"
test "${prepare_line}" -gt "${soc_exit_line}"
test "${prepare_line}" -gt "${none_exit_line}"
test "${prepare_line}" -gt "${open_line}"
if grep -F 'PF_SDL_SKIP_APT' "${DOCKERFILE}" >/dev/null; then
    echo 'FAIL: production Dockerfile skips the frozen libgbm-dev installation' >&2
    exit 1
fi

echo 'sdl-kmsdrm-sysroot=PASS'
