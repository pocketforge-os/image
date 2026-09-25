#!/bin/sh
# Complete and verify the legacy ARM64 cross sysroot used by SDL's dynamic
# KMSDRM build.  The pinned r4 image already carries libdrm-dev:arm64 and the
# frozen apt sources; open SDL alone adds libgbm-dev:arm64 here.
set -eu

fail() {
    echo "FATAL: SDL KMSDRM sysroot: $*" >&2
    exit 1
}

SYSTEM_ROOT=${PF_SDL_SYSTEM_ROOT:-}
TARGET_SYSROOT=${PF_SDL_TARGET_SYSROOT:-/opt/arm-10.3-2021.07/aarch64-none-linux-gnu/libc}
EXPECTED_SNAPSHOT_FILE=${PF_SDL_EXPECTED_SNAPSHOT_FILE:-/work/image-snapshot-date}
CONTAINER_SNAPSHOT_FILE=${PF_SDL_CONTAINER_SNAPSHOT_FILE:-${SYSTEM_ROOT}/etc/pocketforge-apt-snapshot-date}
SOURCE_LIBDIR=${PF_SDL_SOURCE_LIBDIR:-${SYSTEM_ROOT}/usr/lib/aarch64-linux-gnu}
SOURCE_INCLUDEDIR=${PF_SDL_SOURCE_INCLUDEDIR:-${SYSTEM_ROOT}/usr/include}
APT_DIR=${PF_SDL_APT_DIR:-${SYSTEM_ROOT}/etc/apt}
SKIP_APT=${PF_SDL_SKIP_APT:-0}
READELF=${PF_SDL_READELF:-/opt/arm-10.3-2021.07/bin/aarch64-none-linux-gnu-readelf}

TARGET_LIBDIR=${TARGET_SYSROOT}/usr/lib
TARGET_INCLUDEDIR=${TARGET_SYSROOT}/usr/include
TARGET_PKG_CONFIG_LIBDIR=${TARGET_LIBDIR}/pkgconfig

[ -f "${EXPECTED_SNAPSHOT_FILE}" ] || fail "committed snapshot marker is missing: ${EXPECTED_SNAPSHOT_FILE}"
[ -f "${CONTAINER_SNAPSHOT_FILE}" ] || fail "container snapshot marker is missing: ${CONTAINER_SNAPSHOT_FILE}"
expected_snapshot=$(tr -d '\r\n' < "${EXPECTED_SNAPSHOT_FILE}")
container_snapshot=$(tr -d '\r\n' < "${CONTAINER_SNAPSHOT_FILE}")
[ -n "${expected_snapshot}" ] || fail "committed snapshot marker is empty"
[ "${container_snapshot}" = "${expected_snapshot}" ] \
    || fail "container snapshot ${container_snapshot} does not match committed ${expected_snapshot}"

# Fail closed if any enabled one-line apt source can float or names another
# snapshot.  r4 intentionally uses one-line sources exclusively.
for deb822_source in "${APT_DIR}/sources.list.d/"*.sources; do
    [ -s "${deb822_source}" ] || continue
    fail "unsupported deb822 apt source could bypass the frozen r4 source set: ${deb822_source}"
done
active_sources=$(
    for source_file in "${APT_DIR}/sources.list" "${APT_DIR}/sources.list.d/"*.list; do
        [ -f "${source_file}" ] || continue
        sed -n '/^[[:space:]]*deb[[:space:]]/p' "${source_file}"
    done
)
[ -n "${active_sources}" ] || fail "no active frozen apt sources found under ${APT_DIR}"
while IFS= read -r source_line; do
    case "${source_line}" in
        *snapshot.debian.org*"/${expected_snapshot}/"*) ;;
        *) fail "non-frozen or mismatched apt source: ${source_line}" ;;
    esac
done <<EOF
${active_sources}
EOF

case "${SKIP_APT}" in
    0)
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libgbm-dev:arm64
        dpkg-query -W -f='${Status} ${Architecture}\n' libgbm-dev:arm64 \
            | grep -Fx 'install ok installed arm64' >/dev/null \
            || fail "libgbm-dev:arm64 was not installed from the frozen snapshot"
        apt-get clean
        find "${SYSTEM_ROOT}/var/lib/apt/lists" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        ;;
    1) ;;
    *) fail "PF_SDL_SKIP_APT must be 0 or 1, got ${SKIP_APT}" ;;
esac

[ -d "${SOURCE_LIBDIR}" ] || fail "ARM64 source library directory is missing: ${SOURCE_LIBDIR}"
[ -d "${SOURCE_INCLUDEDIR}" ] || fail "ARM64 source include directory is missing: ${SOURCE_INCLUDEDIR}"
[ -e "${SOURCE_LIBDIR}/libdrm.so" ] || fail "target libdrm.so is missing from ${SOURCE_LIBDIR}"
[ -e "${SOURCE_LIBDIR}/libgbm.so" ] || fail "target libgbm.so is missing from ${SOURCE_LIBDIR}"

mkdir -p "${TARGET_LIBDIR}" "${TARGET_INCLUDEDIR}" "${TARGET_PKG_CONFIG_LIBDIR}"
find "${SOURCE_LIBDIR}" -maxdepth 1 \
    \( -name 'libdrm*' -o -name 'libgbm*' \) \
    -exec cp -a -- {} "${TARGET_LIBDIR}/" \;

rewrite_pc() {
    module=$1
    source_pc=${SOURCE_LIBDIR}/pkgconfig/${module}.pc
    target_pc=${TARGET_PKG_CONFIG_LIBDIR}/${module}.pc
    [ -f "${source_pc}" ] || return 1
    # shellcheck disable=SC2016 # Preserve pkg-config's literal ${prefix} variable.
    sed \
        -e 's|/usr/lib/aarch64-linux-gnu|${prefix}/lib|g' \
        -e 's|${prefix}/lib/aarch64-linux-gnu|${prefix}/lib|g' \
        -e 's|/usr/include|${prefix}/include|g' \
        -e "s|^prefix=.*|prefix=${TARGET_SYSROOT}/usr|" \
        "${source_pc}" > "${target_pc}"
}

rewrite_pc libdrm || fail "target libdrm.pc is missing from ${SOURCE_LIBDIR}/pkgconfig"
rewrite_pc gbm || fail "target gbm.pc is missing from ${SOURCE_LIBDIR}/pkgconfig"
# Debian Bookworm does not ship libkms.pc, but preserve and rewrite it when a
# source package does.  This matches the canonical f5 standalone recipe.
rewrite_pc libkms || true

[ -d "${SOURCE_INCLUDEDIR}/libdrm" ] || fail "target libdrm headers are missing"
cp -a "${SOURCE_INCLUDEDIR}/libdrm" "${TARGET_INCLUDEDIR}/"
for header in gbm.h xf86drm.h xf86drmMode.h; do
    [ -f "${SOURCE_INCLUDEDIR}/${header}" ] || fail "target header is missing: ${header}"
    cp -a "${SOURCE_INCLUDEDIR}/${header}" "${TARGET_INCLUDEDIR}/"
done

export PKG_CONFIG_LIBDIR="${TARGET_PKG_CONFIG_LIBDIR}"
unset PKG_CONFIG_PATH
for module in libdrm gbm; do
    pkg-config --exists "${module}" || fail "target pkg-config module is missing: ${module}"
    [ "$(pkg-config --variable=pcfiledir "${module}")" = "${TARGET_PKG_CONFIG_LIBDIR}" ] \
        || fail "${module}.pc resolved outside the target sysroot"
    [ "$(pkg-config --variable=libdir "${module}")" = "${TARGET_LIBDIR}" ] \
        || fail "${module}.pc resolved a non-target libdir: $(pkg-config --variable=libdir "${module}")"
    [ "$(pkg-config --variable=includedir "${module}")" = "${TARGET_INCLUDEDIR}" ] \
        || fail "${module}.pc resolved a non-target includedir: $(pkg-config --variable=includedir "${module}")"
done
if [ -f "${TARGET_PKG_CONFIG_LIBDIR}/libkms.pc" ]; then
    pkg-config --exists libkms || fail "rewritten target libkms.pc is invalid"
    [ "$(pkg-config --variable=pcfiledir libkms)" = "${TARGET_PKG_CONFIG_LIBDIR}" ] \
        || fail "libkms.pc resolved outside the target sysroot"
    [ "$(pkg-config --variable=libdir libkms)" = "${TARGET_LIBDIR}" ] \
        || fail "libkms.pc resolved a non-target libdir"
    [ "$(pkg-config --variable=includedir libkms)" = "${TARGET_INCLUDEDIR}" ] \
        || fail "libkms.pc resolved a non-target includedir"
fi

for header in gbm.h xf86drm.h xf86drmMode.h; do
    [ -f "${TARGET_INCLUDEDIR}/${header}" ] || fail "materialized target header is missing: ${header}"
done
[ -x "${READELF}" ] || command -v "${READELF}" >/dev/null 2>&1 \
    || fail "target readelf is unavailable: ${READELF}"
"${READELF}" -h "${TARGET_LIBDIR}/libgbm.so" \
    | grep -E 'Machine:[[:space:]]+AArch64' >/dev/null \
    || fail "materialized libgbm.so is not AArch64"

echo "SDL KMSDRM sysroot PASS snapshot=${expected_snapshot} sysroot=${TARGET_SYSROOT}"
