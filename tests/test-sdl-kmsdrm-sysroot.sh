#!/usr/bin/env bash
# Exercise the target-sysroot transform used by the production SDL stage. The
# fixture includes Wayland's private libffi edge so host metadata cannot satisfy
# the closure accidentally.
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
        "${source_include}/aarch64-linux-gnu" \
        "${source_include}/xkbcommon" \
        "${fixture}/system/etc/apt/sources.list.d" "${fixture}/system/etc"
    printf '%s\n' '20260601T000000Z' >"${fixture}/system/etc/pocketforge-apt-snapshot-date"
    printf '%s\n' \
        'deb [arch=amd64] http://snapshot.debian.org/archive/debian/20260601T000000Z/ bookworm main' \
        'deb [arch=arm64] http://snapshot.debian.org/archive/debian/20260601T000000Z/ bookworm main' \
        >"${fixture}/system/etc/apt/sources.list"

    printf '%s\n' 'int pocketforge_fixture(void) { return 0; }' >"${fixture}/fixture.c"
    aarch64-linux-gnu-gcc -shared -fPIC "${fixture}/fixture.c" -o "${source_lib}/libdrm.so.2.4.0"
    aarch64-linux-gnu-gcc -shared -fPIC "${fixture}/fixture.c" -o "${source_lib}/libgbm.so.1.0.0"
    for library in ffi wayland-client wayland-egl wayland-cursor xkbcommon; do
        aarch64-linux-gnu-gcc -shared -fPIC "${fixture}/fixture.c" \
            -o "${source_lib}/lib${library}.so.0.0.0"
        ln -s "lib${library}.so.0.0.0" "${source_lib}/lib${library}.so"
    done
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
    printf '%s\n' \
        'prefix=/usr' \
        'libdir=${prefix}/lib/aarch64-linux-gnu' \
        'includedir=${prefix}/include' \
        'Name: libffi' \
        'Description: target libffi fixture' \
        'Version: 3.4.4' \
        'Libs: -L${libdir} -lffi' \
        'Cflags: -I${includedir}' \
        >"${source_lib}/pkgconfig/libffi.pc"
    for module in wayland-client wayland-egl wayland-cursor xkbcommon; do
        printf '%s\n' \
            'prefix=/usr' \
            'libdir=/usr/lib/aarch64-linux-gnu' \
            'includedir=/usr/include' \
            "Name: ${module}" \
            "Description: target ${module} fixture" \
            'Version: 1.21.0' \
            "Libs: -L\${libdir} -l${module}" \
            'Cflags: -I${includedir}' \
            >"${source_lib}/pkgconfig/${module}.pc"
    done
    sed -i '/^Version:/a Requires.private: libffi' \
        "${source_lib}/pkgconfig/wayland-client.pc"
    sed -i '/^Version:/a Requires: wayland-client' \
        "${source_lib}/pkgconfig/wayland-egl.pc"
    sed -i '/^Version:/a Requires.private: wayland-client' \
        "${source_lib}/pkgconfig/wayland-cursor.pc"
    for header in gbm.h xf86drm.h xf86drmMode.h; do
        printf '%s\n' '/* target ARM64 fixture */' >"${source_include}/${header}"
    done
    for header in wayland-client.h wayland-egl.h wayland-cursor.h; do
        printf '%s\n' '/* target ARM64 Wayland fixture */' >"${source_include}/${header}"
    done
    printf '%s\n' '/* target libdrm fixture */' >"${source_include}/libdrm/drm.h"
    printf '%s\n' '/* target libffi fixture */' >"${source_include}/aarch64-linux-gnu/ffi.h"
    printf '%s\n' '/* target libffi target fixture */' >"${source_include}/aarch64-linux-gnu/ffitarget.h"
    printf '%s\n' '/* target xkbcommon fixture */' >"${source_include}/xkbcommon/xkbcommon.h"
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
for module in libdrm gbm libkms libffi wayland-client wayland-egl wayland-cursor xkbcommon; do
    test "$(pkg-config --variable=pcfiledir "${module}")" = "${PKG_CONFIG_LIBDIR}"
    test "$(pkg-config --variable=libdir "${module}")" = "${positive}/target/usr/lib"
    test "$(pkg-config --variable=includedir "${module}")" = "${positive}/target/usr/include"
done
for header in \
    gbm.h xf86drm.h xf86drmMode.h libdrm/drm.h \
    ffi.h ffitarget.h wayland-client.h wayland-egl.h wayland-cursor.h \
    xkbcommon/xkbcommon.h; do
    test -f "${positive}/target/usr/include/${header}"
done
for library in drm gbm ffi wayland-client wayland-egl wayland-cursor xkbcommon; do
    aarch64-linux-gnu-readelf -h "${positive}/target/usr/lib/lib${library}.so" \
        | grep -Eq 'Machine:[[:space:]]+AArch64'
done

wrong_arch_drm="${TMPDIR_TEST}/wrong-arch-drm"
make_fixture "${wrong_arch_drm}"
cc -shared -fPIC "${wrong_arch_drm}/fixture.c" \
    -o "${wrong_arch_drm}/system/usr/lib/aarch64-linux-gnu/libdrm.so.2.4.0"
if run_helper "${wrong_arch_drm}" "${wrong_arch_drm}/target" >/dev/null 2>&1; then
    echo 'FAIL: production preparation accepted non-AArch64 libdrm' >&2
    exit 1
fi

missing_wayland="${TMPDIR_TEST}/missing-wayland"
make_fixture "${missing_wayland}"
rm "${missing_wayland}/system/usr/lib/aarch64-linux-gnu/pkgconfig/wayland-client.pc"
if run_helper "${missing_wayland}" "${missing_wayland}/target" >/dev/null 2>&1; then
    echo 'FAIL: production preparation accepted missing target Wayland metadata' >&2
    exit 1
fi

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

for package in \
    'libgbm-dev:arm64' \
    'libffi-dev:arm64' \
    'libwayland-dev:arm64' \
    'libwayland-egl-backend-dev:arm64' \
    'libxkbcommon-dev:arm64'; do
    grep -F "${package}" "${HELPER}" >/dev/null
done
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
