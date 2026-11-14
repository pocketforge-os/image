#!/usr/bin/env bash
# Regression for owned-image build 43527442384: sdl3-sys requested Wayland,
# but the production Poolsuite stage had no AArch64 Wayland/EGL/xkbcommon
# development closure, so all five pkg-config checks failed and SDL aborted.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${root}/build/Dockerfile.pf"
validator="${root}/scripts/verify-poolsuite-wayland-toolchain.sh"
tmp="$(mktemp -d)"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT

toolchain_block="$(sed -n '/^FROM debian:.* AS poolsuite-toolchain$/,/^FROM poolsuite-toolchain AS poolsuite-fetch$/p' "${dockerfile}")"
dev_block="$(sed -n '/^FROM poolsuite-toolchain AS poolsuite-dev$/,/^FROM pf-build-base AS poolsuite-not-shipped$/p' "${dockerfile}")"

# Pin the actual production stage closure and its fail-closed probe. Merely
# disabling SDL_WAYLAND or allowing native pkg-config metadata cannot pass.
grep -Fx 'COPY --chmod=0555 --from=image-src scripts/verify-poolsuite-wayland-toolchain.sh /usr/local/bin/verify-poolsuite-wayland-toolchain' <<<"${toolchain_block}" >/dev/null
grep -F 'dpkg --add-architecture arm64' <<<"${toolchain_block}" >/dev/null
for package in \
    'libegl-dev:arm64' \
    'libwayland-dev:arm64' \
    'libwayland-egl-backend-dev:arm64' \
    'libxkbcommon-dev:arm64' \
    'wayland-protocols'; do
    grep -F "  ${package}" <<<"${toolchain_block}" >/dev/null
done
grep -Fx '/usr/local/bin/verify-poolsuite-wayland-toolchain' <<<"${toolchain_block}" >/dev/null

export_line="$(grep -nF 'export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig' <<<"${dev_block}" | cut -d: -f1)"
unset_line="$(grep -nF 'unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR' <<<"${dev_block}" | cut -d: -f1)"
build_line="$(grep -nF './ci/device-build.sh --offline' <<<"${dev_block}" | cut -d: -f1)"
test -n "${export_line}" && test -n "${unset_line}" && test -n "${build_line}"
test "${export_line}" -lt "${build_line}"
test "${unset_line}" -lt "${build_line}"
if grep -Eq 'SDL_WAYLAND=(OFF|0)|-DSDL_WAYLAND=OFF' <<<"${toolchain_block}${dev_block}"; then
    echo 'FAIL: production Poolsuite stage disables the required SDL Wayland backend' >&2
    exit 1
fi

make_fixture() {
    local fixture=$1
    local libdir="${fixture}/lib"
    local includedir="${fixture}/include"
    local pcdir="${libdir}/pkgconfig"
    local share_pcdir="${fixture}/share/pkgconfig"
    mkdir -p "${pcdir}" "${share_pcdir}" "${fixture}/share/wayland-protocols" \
        "${includedir}/EGL" "${includedir}/xkbcommon"

    cat >"${fixture}/fixture.c" <<'EOF'
void *wl_display_connect(const char *name) { (void)name; return 0; }
void wl_display_disconnect(void *display) { (void)display; }
void *wl_egl_window_create(void *surface, int width, int height) { (void)surface; (void)width; (void)height; return 0; }
void wl_egl_window_destroy(void *window) { (void)window; }
void *wl_cursor_theme_load(const char *name, int size, void *shm) { (void)name; (void)size; (void)shm; return 0; }
void wl_cursor_theme_destroy(void *theme) { (void)theme; }
void *eglGetDisplay(void *display) { (void)display; return 0; }
void *xkb_context_new(int flags) { (void)flags; return 0; }
void xkb_context_unref(void *context) { (void)context; }
EOF
    aarch64-linux-gnu-gcc -shared -fPIC "${fixture}/fixture.c" -o "${libdir}/libpoolsuite-wayland-fixture.so"

    cat >"${includedir}/wayland-client.h" <<'EOF'
struct wl_display;
struct wl_display *wl_display_connect(const char *name);
void wl_display_disconnect(struct wl_display *display);
EOF
    cat >"${includedir}/wayland-egl.h" <<'EOF'
struct wl_surface;
struct wl_egl_window;
struct wl_egl_window *wl_egl_window_create(struct wl_surface *surface, int width, int height);
void wl_egl_window_destroy(struct wl_egl_window *window);
EOF
    cat >"${includedir}/wayland-cursor.h" <<'EOF'
struct wl_shm;
struct wl_cursor_theme;
struct wl_cursor_theme *wl_cursor_theme_load(const char *name, int size, struct wl_shm *shm);
void wl_cursor_theme_destroy(struct wl_cursor_theme *theme);
EOF
    cat >"${includedir}/EGL/egl.h" <<'EOF'
typedef void *EGLDisplay;
#define EGL_DEFAULT_DISPLAY ((void *)0)
#define EGL_NO_DISPLAY ((EGLDisplay)0)
EGLDisplay eglGetDisplay(void *display_id);
EOF
    cat >"${includedir}/xkbcommon/xkbcommon.h" <<'EOF'
struct xkb_context;
#define XKB_CONTEXT_NO_FLAGS 0
struct xkb_context *xkb_context_new(int flags);
void xkb_context_unref(struct xkb_context *context);
EOF

    for module in wayland-client wayland-egl wayland-cursor egl xkbcommon; do
        cat >"${pcdir}/${module}.pc" <<EOF
prefix=${fixture}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: ${module}
Description: AArch64 regression fixture for ${module}
Version: 1.0
Libs: -L\${libdir} -lpoolsuite-wayland-fixture
Cflags: -I\${includedir}
EOF
    done
    cat >"${share_pcdir}/wayland-protocols.pc" <<EOF
prefix=${fixture}
pkgdatadir=\${prefix}/share/wayland-protocols
Name: wayland-protocols
Description: architecture-independent Wayland protocol fixture
Version: 1.0
EOF
}

run_validator() {
    local fixture=$1
    PF_POOLSUITE_TARGET_LIBDIR="${fixture}/lib" \
    PF_POOLSUITE_TARGET_INCLUDEDIR="${fixture}/include" \
    PF_POOLSUITE_TARGET_PKGCONFIG_DIR="${fixture}/lib/pkgconfig" \
    PF_POOLSUITE_SHARE_PKGCONFIG_DIR="${fixture}/share/pkgconfig" \
        "${validator}"
}

positive="${tmp}/positive"
make_fixture "${positive}"
run_validator "${positive}" >/dev/null

missing="${tmp}/missing"
make_fixture "${missing}"
rm "${missing}/lib/pkgconfig/xkbcommon.pc"
if run_validator "${missing}" >/dev/null 2>&1; then
    echo 'FAIL: production validator accepted missing target xkbcommon metadata' >&2
    exit 1
fi

host_lib="${tmp}/host-lib"
make_fixture "${host_lib}"
gcc -shared -fPIC "${host_lib}/fixture.c" -o "${host_lib}/lib/libpoolsuite-wayland-fixture.so"
if run_validator "${host_lib}" >/dev/null 2>&1; then
    echo 'FAIL: production validator accepted a host-architecture Wayland closure' >&2
    exit 1
fi

echo 'poolsuite-wayland-toolchain=PASS'
