#!/usr/bin/env bash
# shellcheck disable=SC2034  # every variable set here is an output for the sourcing script
# rootfs-package-list.sh - the a133 rootfs apt solve, shared by both mmdebstrap
# passes (tsp-hqm1p.182.13). Sourced, never executed.
#
# scripts/build-rootfs-base.sh runs the solve once into a cached base (no
# customize hook, no cleanup). scripts/build-rootfs.sh either runs the same solve
# with the customize hook (single pass; a523/make callers), or, with
# PF_ROOTFS_BASE_DIR, overlays the customize hook onto that base. Both passes
# must build the identical package set from the identical local debs, so the
# package-list merge, the local-package includes and the solve options live here
# once. The identity of every solve input is pf_rootfs_base_identity's output;
# the overlay refuses a base whose recorded identity differs.
#
# Inputs (caller globals): SRC_DIR VARIANT PF_DEVICE_ID PF_GPU_MODEL
# PF_GAMESCOPE_MODE PF_HAS_DISPLAY CLOUD_INIT_DIR PF_APT_FIX_DIR GPU_UM_MESA_DIR
# PF_APT_PROXY. Moved verbatim from build-rootfs.sh; behavior is unchanged.

PF_ROOTFS_BASE_FORMAT=pf-rootfs-base-v1

# Frozen snapshot mirror. The scheme follows the fetch transport: plain http
# through the PF_APT_PROXY cache (the cache never carries https), https direct
# otherwise, so a direct fetch has no plain-http leg for a redirect to ride
# (CVE-2026-109518, bd tsp-hqm1p.143). apt verifies every byte against the
# signed snapshot index in both modes, and the target's persisted sources are
# rewritten to https after extraction, so the rootfs bytes do not depend on it.
pf_rootfs_snapshot_url() {
SNAPSHOT_DATE="$(cat "${SRC_DIR}/snapshot-date.txt")"
if [ -n "${PF_APT_PROXY:-}" ]; then
    SNAPSHOT_SCHEME=http
else
    SNAPSHOT_SCHEME=https
fi
SNAPSHOT_URL="${SNAPSHOT_SCHEME}://snapshot.debian.org/archive/debian/${SNAPSHOT_DATE}/"
}

# Sets PKG_LIST: the merged, profile-selected package roots (step 1).
pf_rootfs_package_list() {
PKG_FILE="${SRC_DIR}/rootfs-packages.txt"
PKG_DEV_FILE="${SRC_DIR}/rootfs-packages-dev.txt"
PKG_MAINLINE_FILE="${SRC_DIR}/rootfs-packages-mainline.txt"
PKG_MAINLINE_DEV_FILE="${SRC_DIR}/rootfs-packages-mainline-dev.txt"
PKG_A133_OPEN_7X_GPU_FILE="${SRC_DIR}/rootfs-packages-a133-open-7x-gpu.txt"

[ -f "${PKG_FILE}" ] || { echo "FATAL: ${PKG_FILE} not found" >&2; exit 1; }

# Strip comments and blank lines, merge into comma-delimited list
PKG_LIST="$(grep -v '^\s*#' "${PKG_FILE}" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')"

if [ "${VARIANT}" = "dev" ] && [ -f "${PKG_DEV_FILE}" ]; then
    DEV_PKGS="$(grep -v '^\s*#' "${PKG_DEV_FILE}" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')"
    PKG_LIST="${PKG_LIST},${DEV_PKGS}"
    echo "  variant=dev: added dev-only packages (${DEV_PKGS})"
fi

# The open GPU model selects the mainline A133 image variants.  Their
# conformance suites need throughput, cpufreq, I2C, and USB inspection tools in
# both dev and release images.  Keep these out of the shared list so the
# shipping closed-DDK rootfs remains unaffected by this package layer.
if [ "${PF_GPU_MODEL}" = "open" ]; then
    [ -f "${PKG_MAINLINE_FILE}" ] \
        || { echo "FATAL: ${PKG_MAINLINE_FILE} not found" >&2; exit 1; }
    MAINLINE_PKGS="$(grep -v '^\s*#' "${PKG_MAINLINE_FILE}" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')"
    PKG_LIST="${PKG_LIST},${MAINLINE_PKGS}"
    echo "  gpu_model=open: added mainline conformance packages (${MAINLINE_PKGS})"
fi

# Standard demos/diagnostics belong to the PowerVR/Zink 7.x GPU profile, not
# every open bring-up rootfs. Their generic GLVND dependencies are satisfied by
# the source-built, file-owning provider selected below; the our-stack tripwire
# proves that apt did not install a Debian Mesa driver implementation instead.
case "${PF_DEVICE_ID}" in
    a133-open-7x-gpu|a133-open-7x-gpu-cts|a133-open-7x-gpu-noradio)
        [ -f "${PKG_A133_OPEN_7X_GPU_FILE}" ] \
            || { echo "FATAL: ${PKG_A133_OPEN_7X_GPU_FILE} not found" >&2; exit 1; }
        GPU_TOOL_PKGS="$(grep -v '^\s*#' "${PKG_A133_OPEN_7X_GPU_FILE}" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')"
        PKG_LIST="${PKG_LIST},${GPU_TOOL_PKGS}"
        echo "  device=${PF_DEVICE_ID}: added GPU demos and diagnostics (${GPU_TOOL_PKGS})"
        ;;
esac

# The G1 compositor runtime is profile-scoped so all unrelated image package
# lists remain byte-for-byte unchanged. Xwayland is an explicit product input,
# not an implicit recommendation or a runtime download.
if [ "${PF_GAMESCOPE_MODE}" = "g1" ]; then
    GAMESCOPE_RUNTIME_PKGS="libavif15 libcap2 libdecor-0-0 liblcms2-2 libliftoff0 libluajit-5.1-2 libpipewire-0.3-0 libpixman-1-0 libseat1 libsdl2-2.0-0 libxcomposite1 libxcursor1 libxdamage1 libxext6 libxfixes3 libxi6 libxmu6 libxrender1 libxres1 libxtst6 libxxf86vm1 xwayland"
    PKG_LIST="${PKG_LIST},$(printf '%s' "${GAMESCOPE_RUNTIME_PKGS}" | tr ' ' ',')"
    echo "  gamescope=g1: added compositor/Xwayland runtime closure (${GAMESCOPE_RUNTIME_PKGS})"
fi

if [ "${PF_GPU_MODEL}" = "open" ] && [ "${VARIANT}" = "dev" ]; then
    [ -f "${PKG_MAINLINE_DEV_FILE}" ] \
        || { echo "FATAL: ${PKG_MAINLINE_DEV_FILE} not found" >&2; exit 1; }
    MAINLINE_DEV_PKGS="$(grep -v '^\s*#' "${PKG_MAINLINE_DEV_FILE}" | grep -v '^\s*$' | tr '\n' ',' | sed 's/,$//')"
    PKG_LIST="${PKG_LIST},${MAINLINE_DEV_PKGS}"
    echo "  gpu_model=open variant=dev: added mainline diagnostics (${MAINLINE_DEV_PKGS})"
fi

# Zink needs the Khronos Vulkan loader, but the open GPU model is opt-in.
# Keep the shared package set byte-identical for closed a133 by appending the
# loader only to the package list passed to this open-model mmdebstrap run.
if [ "${PF_GPU_MODEL}" = "open" ]; then
    PKG_LIST="${PKG_LIST},libvulkan1"
    echo "  gpu_model=open: added open-GPU package (libvulkan1)"
fi

# These explicit roots provide the product UI's graphics client stack.  Keep the
# existing package string untouched for display-capable builds, but remove every
# root when the profile says there is no display.  In particular, Debian's
# FFmpeg roots the stack twice: its binary depends on SDL2, which pulls GBM and
# GLX Mesa, while libavutil depends on VDPAU and Debian's recommended VDPAU/VA
# providers pull Mesa's driver packages.  Both paths reach the complete Mesa DRI
# driver set even though the codec packages look unrelated to display.
if [ "${PF_HAS_DISPLAY}" = 0 ]; then
    DISPLAY_PACKAGE_ROOTS="libavcodec59 libavutil57 libegl1 libepoxy0 libgbm1 libgles2 libwayland-egl1 ffmpeg libvdpau1"
    for package in ${DISPLAY_PACKAGE_ROOTS}; do
        PKG_LIST="$(printf '%s\n' "${PKG_LIST}" | tr ',' '\n' |
            awk -v drop="${package}" '$0 != drop' | paste -sd, -)"
    done
    echo "  display_pipeline=none: omitted graphics package roots (${DISPLAY_PACKAGE_ROOTS})"
fi

# An explicit apt root such as libgbm1 selects Debian's real package even when
# a local package provides that name. Remove every implementation package that
# the source-built provider replaces before handing the list to mmdebstrap;
# neutral GLVND client libraries (libegl1/libgles2/libgl1/libglx0) and Xwayland
# stay present.
case "${PF_DEVICE_ID}" in
    a133-open-7x-gpu|a133-open-7x-gpu-cts|a133-open-7x-gpu-noradio)
        GPU_STACK_REPLACED_PACKAGES="libegl-mesa0 libgl1-mesa-dri libglx-mesa0 libgbm1 mesa-opencl-icd mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers libosmesa6"
        for package in ${GPU_STACK_REPLACED_PACKAGES}; do
            PKG_LIST="$(printf '%s\n' "${PKG_LIST}" | tr ',' '\n' |
                awk -v drop="${package}" '$0 != drop' | paste -sd, -)"
        done
        echo "  open GPU provider: removed explicit Debian Mesa package roots (${GPU_STACK_REPLACED_PACKAGES})"
        ;;
esac

echo "  package list: ${PKG_LIST}"
}

# Sets LOCAL_PACKAGE_OPTS: the local debs that join the initial solve.
pf_rootfs_local_package_opts() {
# Feed the deterministic local packages into mmdebstrap's initial apt solve so
# their Debian dependencies are resolved from the same frozen image snapshot.
CLOUD_INIT_DEB="${CLOUD_INIT_DIR}/cloud-init-pocketforge.deb"
[ -f "${CLOUD_INIT_DEB}" ] \
    || { echo "FATAL: cloud-init-pocketforge package is missing: ${CLOUD_INIT_DEB}" >&2; exit 1; }
LOCAL_PACKAGE_OPTS=(
    --include="${CLOUD_INIT_DEB}"
)

# CVE-2026-109518 (bd tsp-hqm1p.143): the frozen snapshot's apt 2.6.1 is
# vulnerable. pf-build-base fetched the fixed arm64 apt/libapt-pkg6.0 2.6.2 pair
# from debian-security and checked it against committed SHA256 pins; the initial
# solve installs it in place of the snapshot's, so only those two packages move.
# verify-rootfs-apt-policy.sh gates the installed version after extraction.
for apt_fix_deb in apt_2.6.2_arm64.deb libapt-pkg6.0_2.6.2_arm64.deb; do
    [ -f "${PF_APT_FIX_DIR}/${apt_fix_deb}" ] \
        || { echo "FATAL: CVE-2026-109518 fixed apt package is missing: ${PF_APT_FIX_DIR}/${apt_fix_deb}" >&2; exit 1; }
    LOCAL_PACKAGE_OPTS+=(--include="${PF_APT_FIX_DIR}/${apt_fix_deb}")
done

# Feed the deterministic, file-owning package produced from gpu-um-tsp's exact
# Meson install tree into the initial apt solve. Its versioned Provides satisfy
# Debian's graphics relationships while Conflicts/Replaces prevent a second
# Mesa vendor from entering the rootfs.
case "${PF_DEVICE_ID}" in
    a133-open-7x-gpu|a133-open-7x-gpu-cts|a133-open-7x-gpu-noradio)
        GPU_STACK_PROVIDER_DEB="${GPU_UM_MESA_DIR}/pocketforge-open-gpu-stack.deb"
        [ -f "${GPU_STACK_PROVIDER_DEB}" ] \
            || { echo "FATAL: source-built open GPU stack provider is missing: ${GPU_STACK_PROVIDER_DEB}" >&2; exit 1; }
        LOCAL_PACKAGE_OPTS+=(--include="${GPU_STACK_PROVIDER_DEB}")
        echo "  open GPU dependency provider: ${GPU_STACK_PROVIDER_DEB}"
        ;;
esac
LOCAL_PACKAGE_OPTS+=(--hook-dir=/usr/share/mmdebstrap/hooks/file-mirror-automount)
}

# Optional transparent apt caching proxy. When PF_APT_PROXY is set (e.g. the NAS
# apt-cacher-ng at http://10.0.32.86:3142, which fronts snapshot.debian.org and
# routes the flaky .deb pool to a fast reproducible mirror), mmdebstrap's apt uses
# it. This is a FETCH TRANSPORT ONLY and fully TRANSPARENT: apt verifies every .deb
# against the signed InRelease->Packages chain from the pinned snapshot date, so the
# proxy cannot change the bytes — G-reproducible / the R1 gate are preserved (a cache
# HIT and a direct fetch yield identical rootfs contents). Empty by default = direct
# snapshot. Not recorded in provenance; it never affects output bytes.
# Sets APT_PROXY_OPT and APT_PROXY_PERSISTED.
pf_rootfs_apt_proxy_opts() {
APT_PROXY_OPT=()
APT_PROXY_PERSISTED=""
if [ -n "${PF_APT_PROXY:-}" ]; then
    echo "  apt proxy: ${PF_APT_PROXY} (transparent cache; bytes verified vs signed index)"
    apt_proxy_aptopt="Acquire::http::Proxy \"${PF_APT_PROXY}\""
    APT_PROXY_OPT=( --aptopt="${apt_proxy_aptopt}" )
    # mmdebstrap persists this --aptopt verbatim (plus ';') into the target's
    # etc/apt/apt.conf.d/99mmdebstrap; the strip step removes exactly this line.
    APT_PROXY_PERSISTED="${apt_proxy_aptopt};"
fi
}

# Sets MMDEBSTRAP_APT_OPTS, MMDEBSTRAP_SOLVE_OPTS (arch, variant, mode, aptopts,
# the proxy transport, the package roots and the local debs) and
# MMDEBSTRAP_DPKG_OPTS, in the argv order the single-pass build always used.
# Call after pf_rootfs_package_list, pf_rootfs_local_package_opts and
# pf_rootfs_apt_proxy_opts.
pf_rootfs_mmdebstrap_opts() {
    MMDEBSTRAP_APT_OPTS=(
        --aptopt='Acquire::Check-Valid-Until "false"'
        --aptopt='APT::Sandbox::User "root"'
        --aptopt='Acquire::Retries "5"'
        --aptopt='Acquire::Retries::Delay "false"'
    )
    MMDEBSTRAP_SOLVE_OPTS=(
        --arch=arm64
        --variant=minbase
        --mode=root
        "${MMDEBSTRAP_APT_OPTS[@]}"
        "${APT_PROXY_OPT[@]}"
        --include="${PKG_LIST}"
        "${LOCAL_PACKAGE_OPTS[@]}"
    )
    MMDEBSTRAP_DPKG_OPTS=(
        --dpkgopt='path-exclude=/usr/share/man/*'
        --dpkgopt='path-exclude=/usr/share/doc/*'
        --dpkgopt='path-include=/usr/share/doc/*/copyright'
    )
}

# Prints the identity of every input of the base solve, one key=value per line in
# a fixed order. The proxy aptopt is a fetch transport, normalized out of the
# base, so it is not part of the identity. Local debs are named by their exact
# in-chroot path (dpkg sees the same path in both stages) and their sha256.
pf_rootfs_base_identity() {
    local opt path
    printf 'format=%s\n' "${PF_ROOTFS_BASE_FORMAT}"
    printf 'suite=bookworm\n'
    printf 'snapshot_date=%s\n' "${SNAPSHOT_DATE}"
    printf 'package_list_sha256=%s\n' "$(printf '%s' "${PKG_LIST}" | sha256sum | cut -d' ' -f1)"
    for opt in "${MMDEBSTRAP_SOLVE_OPTS[@]}" "${MMDEBSTRAP_DPKG_OPTS[@]}"; do
        case "${opt}" in
            --include=/*)
                path="${opt#--include=}"
                printf 'local_deb=%s sha256=%s\n' "${path}" "$(sha256sum "${path}" | cut -d' ' -f1)"
                ;;
            --include=*) ;;  # the package roots: package_list_sha256 above
            --aptopt=Acquire::http::Proxy*) ;;
            *) printf 'opt=%s\n' "${opt}" ;;
        esac
    done
    printf 'recipe_sha256=%s\n' "$(cat \
        "${SRC_DIR}/scripts/build-rootfs-base.sh" \
        "${SRC_DIR}/scripts/rootfs-package-list.sh" \
        "${SRC_DIR}/scripts/rewrite-rootfs-apt-sources-https.sh" \
        "${SRC_DIR}/scripts/strip-rootfs-apt-proxy.sh" | sha256sum | cut -d' ' -f1)"
}

# pf_rootfs_base_verify <base-dir> - fail closed unless the base was built from
# exactly this solve (identity equal) and its tarball is the one it recorded.
pf_rootfs_base_verify() {
    local base="$1" want got tar_sha
    local manifest="${base}/rootfs-base.manifest"
    if [ ! -f "${manifest}" ] || [ ! -f "${base}/rootfs-base.tar" ]; then
        echo "FATAL: rootfs base: ${base} holds no rootfs-base.manifest/rootfs-base.tar" >&2
        exit 1
    fi
    want="$(pf_rootfs_base_identity)"
    got="$(grep -v '^tar_sha256=' "${manifest}")"
    if [ "${want}" != "${got}" ]; then
        echo "FATAL: rootfs base was built from a different solve (recorded vs this build):" >&2
        diff <(printf '%s\n' "${got}") <(printf '%s\n' "${want}") >&2 || true
        exit 1
    fi
    tar_sha="$(sed -n 's/^tar_sha256=//p' "${manifest}")"
    if [ "$(sha256sum "${base}/rootfs-base.tar" | cut -d' ' -f1)" != "${tar_sha}" ]; then
        echo "FATAL: rootfs base: rootfs-base.tar does not match its manifest" >&2
        exit 1
    fi
    echo "  rootfs base: identity verified (${PF_ROOTFS_BASE_FORMAT}, tar sha256 ${tar_sha})"
}

# pf_rootfs_overlay_opts <base-dir> - sets MMDEBSTRAP_OVERLAY_OPTS: replay the
# cached base as the setup of a custom variant, with no download and no solve.
# The setup phase still runs, because cleanup/apt drives the outer apt through
# the temporary APT_CONFIG that setup writes (mmdebstrap 1.5.6 run_cleanup). The
# tar-in setup hook runs after it and replaces every file setup wrote with the
# base's normalized copy. The customize hook and the full cleanup then run
# exactly as in the single pass.
pf_rootfs_overlay_opts() {
    MMDEBSTRAP_OVERLAY_OPTS=(
        --arch=arm64
        --variant=custom
        --mode=root
        "${MMDEBSTRAP_APT_OPTS[@]}"
        --skip=update
        --setup-hook="tar-in $1/rootfs-base.tar /"
    )
}
