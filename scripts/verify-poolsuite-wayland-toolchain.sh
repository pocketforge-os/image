#!/bin/sh
# Fail closed unless the Poolsuite cross toolchain can compile and link an
# AArch64 SDL Wayland client using target-only pkg-config metadata.
set -eu

fail() {
    echo "FATAL: Poolsuite Wayland toolchain: $*" >&2
    exit 1
}

TARGET_LIBDIR=${PF_POOLSUITE_TARGET_LIBDIR:-/usr/lib/aarch64-linux-gnu}
TARGET_INCLUDEDIR=${PF_POOLSUITE_TARGET_INCLUDEDIR:-/usr/include}
TARGET_PKGCONFIG_DIR=${PF_POOLSUITE_TARGET_PKGCONFIG_DIR:-${TARGET_LIBDIR}/pkgconfig}
SHARE_PKGCONFIG_DIR=${PF_POOLSUITE_SHARE_PKGCONFIG_DIR:-/usr/share/pkgconfig}
CC=${PF_POOLSUITE_CC:-aarch64-linux-gnu-gcc}
READELF=${PF_POOLSUITE_READELF:-aarch64-linux-gnu-readelf}

[ -d "${TARGET_LIBDIR}" ] || fail "target library directory is missing: ${TARGET_LIBDIR}"
[ -d "${TARGET_INCLUDEDIR}" ] || fail "target include directory is missing: ${TARGET_INCLUDEDIR}"
[ -d "${TARGET_PKGCONFIG_DIR}" ] || fail "target pkg-config directory is missing: ${TARGET_PKGCONFIG_DIR}"
[ -d "${SHARE_PKGCONFIG_DIR}" ] || fail "shared pkg-config directory is missing: ${SHARE_PKGCONFIG_DIR}"
command -v pkg-config >/dev/null 2>&1 || fail "pkg-config is unavailable"
command -v "${CC}" >/dev/null 2>&1 || fail "cross compiler is unavailable: ${CC}"
command -v "${READELF}" >/dev/null 2>&1 || fail "target readelf is unavailable: ${READELF}"

# Never consult native-host library metadata. SDL also queries the
# architecture-independent wayland-protocols package in /usr/share/pkgconfig,
# while the checks below require every library module to resolve from the
# AArch64 multiarch directory.
export PKG_CONFIG_LIBDIR="${TARGET_PKGCONFIG_DIR}:${SHARE_PKGCONFIG_DIR}"
unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR

modules='wayland-client wayland-egl wayland-cursor egl xkbcommon'
for module in ${modules}; do
    pkg-config --exists "${module}" || fail "target pkg-config module is missing: ${module}"
    pcfiledir=$(pkg-config --variable=pcfiledir "${module}")
    [ "${pcfiledir}" = "${TARGET_PKGCONFIG_DIR}" ] \
        || fail "${module}.pc resolved outside the target metadata directory: ${pcfiledir}"
    libdir=$(pkg-config --variable=libdir "${module}")
    [ "${libdir}" = "${TARGET_LIBDIR}" ] \
        || fail "${module}.pc resolved a non-target libdir: ${libdir}"
    includedir=$(pkg-config --variable=includedir "${module}")
    [ "${includedir}" = "${TARGET_INCLUDEDIR}" ] \
        || fail "${module}.pc resolved a non-target includedir: ${includedir}"
done
pkg-config --exists wayland-protocols || fail "architecture-independent wayland-protocols metadata is missing"
[ "$(pkg-config --variable=pcfiledir wayland-protocols)" = "${SHARE_PKGCONFIG_DIR}" ] \
    || fail "wayland-protocols.pc resolved outside the shared metadata directory"
protocol_dir=$(pkg-config --variable=pkgdatadir wayland-protocols)
[ -d "${protocol_dir}" ] || fail "Wayland protocol definitions are missing: ${protocol_dir}"

probe_dir=$(mktemp -d)
trap 'find "${probe_dir}" -mindepth 1 -delete; rmdir "${probe_dir}"' EXIT HUP INT TERM
cat >"${probe_dir}/probe.c" <<'EOF'
#include <wayland-client.h>
#include <wayland-egl.h>
#include <wayland-cursor.h>
#include <EGL/egl.h>
#include <xkbcommon/xkbcommon.h>

int main(void) {
    struct wl_display *display = wl_display_connect(0);
    struct wl_egl_window *window = wl_egl_window_create(0, 1, 1);
    struct wl_cursor_theme *theme = wl_cursor_theme_load(0, 1, 0);
    EGLDisplay egl_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    struct xkb_context *xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (xkb) xkb_context_unref(xkb);
    if (theme) wl_cursor_theme_destroy(theme);
    if (window) wl_egl_window_destroy(window);
    if (display) wl_display_disconnect(display);
    return egl_display == EGL_NO_DISPLAY;
}
EOF

# Word splitting is required for pkg-config's compiler and linker arguments.
# shellcheck disable=SC2046,SC2086
"${CC}" -Wl,--no-as-needed -o "${probe_dir}/probe" "${probe_dir}/probe.c" \
    $(pkg-config --cflags --libs ${modules}) \
    || fail "AArch64 Wayland/EGL/xkbcommon compile-link probe failed"
"${READELF}" -h "${probe_dir}/probe" \
    | grep -Eq 'Machine:[[:space:]]+AArch64' \
    || fail "compile-link probe did not produce an AArch64 ELF"

echo "Poolsuite Wayland toolchain PASS target_pkg_config_dir=${TARGET_PKGCONFIG_DIR}"
