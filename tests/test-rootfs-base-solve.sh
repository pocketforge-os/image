#!/usr/bin/env bash
# test-rootfs-base-solve.sh - hermetic tests for the cached rootfs base
# (tsp-hqm1p.182.13). No network, no qemu, no real mmdebstrap: a fake on the
# PF_MMDEBSTRAP seam records its argv and writes a tree shaped like the real one.
#
# Pins:
#   1. the base solve: the single pass's own options, plus --skip=cleanup, with no
#      customize hook, epoch = the snapshot date's instant, into a directory;
#   2. transport independence: with and without the apt proxy, the base tar and
#      manifest are byte-identical (https sources, persisted proxy line stripped,
#      sorted tar with clamped mtimes);
#   3. pf_rootfs_base_verify accepts its own base and refuses a changed package
#      list, a changed local deb, a missing proxy-independent field or a tampered
#      tarball, each by name;
#   4. the overlay options: custom variant, setup kept, update skipped, tar-in of
#      the base, the same aptopts, no packages and no proxy.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
pass=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "${pass}" "$*"; }

SRC="${TMP}/src"
mkdir -p "${SRC}/scripts" "${TMP}/cloud-init" "${TMP}/gpu-um-mesa" "${TMP}/apt-fix" "${TMP}/bin"
for f in snapshot-date.txt rootfs-packages.txt rootfs-packages-dev.txt rootfs-packages-mainline.txt \
    rootfs-packages-mainline-dev.txt rootfs-packages-a133-open-7x-gpu.txt; do
    cp "${REPO}/${f}" "${SRC}/${f}"
done
for f in build-rootfs-base.sh rootfs-package-list.sh rewrite-rootfs-apt-sources-https.sh strip-rootfs-apt-proxy.sh; do
    cp "${REPO}/scripts/${f}" "${SRC}/scripts/${f}"
done
printf 'cloud-init deb\n' > "${TMP}/cloud-init/cloud-init-pocketforge.deb"
printf 'gpu provider deb\n' > "${TMP}/gpu-um-mesa/pocketforge-open-gpu-stack.deb"
printf 'apt\n' > "${TMP}/apt-fix/apt_2.6.2_arm64.deb"
printf 'libapt\n' > "${TMP}/apt-fix/libapt-pkg6.0_2.6.2_arm64.deb"
DATE="$(cat "${SRC}/snapshot-date.txt")"
[[ "${DATE}" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]] || fail "fixture date ${DATE}"
EPOCH="$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}Z" +%s)"

# The fake writes what mmdebstrap's setup + install leave in a --skip=cleanup
# directory target: sources.list in the fetch scheme, every --aptopt persisted
# into 99mmdebstrap with its ';', and some installed payload.
cat > "${TMP}/bin/fake-mmdebstrap" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" > "${FAKE_LOG}"
printf '%s\n' "${SOURCE_DATE_EPOCH}" > "${FAKE_LOG}.epoch"
args=("$@")
n=${#args[@]}
root="${args[n-2]}" url="${args[n-1]}"
[ ! -e "${root}" ] || { echo "fake: target exists" >&2; exit 9; }
mkdir -p "${root}/etc/apt/apt.conf.d" "${root}/usr/bin" "${root}/var/lib/apt/lists"
printf 'deb %s bookworm main\n' "${url}" > "${root}/etc/apt/sources.list"
for a in "$@"; do
    case "${a}" in --aptopt=*) printf '%s;\n' "${a#--aptopt=}" >> "${root}/etc/apt/apt.conf.d/99mmdebstrap" ;; esac
done
printf 'binary\n' > "${root}/usr/bin/tool"
printf 'index\n' > "${root}/var/lib/apt/lists/snapshot_InRelease"
FAKE
chmod +x "${TMP}/bin/fake-mmdebstrap"

base() {  # <out-dir> <proxy> [extra env...]
    local out="$1" proxy="$2"
    shift 2
    env -i PATH="${PATH}" HOME="${TMP}" FAKE_LOG="${TMP}/argv" PF_MMDEBSTRAP="${TMP}/bin/fake-mmdebstrap" \
        SRC_DIR="${SRC}" OUT_DIR="${out}" CLOUD_INIT_DIR="${TMP}/cloud-init" \
        GPU_UM_MESA_DIR="${TMP}/gpu-um-mesa" PF_APT_FIX_DIR="${TMP}/apt-fix" \
        PF_DEVICE_ID=a133-open-7x-gpu PF_GPU_MODEL=open PF_DISPLAY_PIPELINE=drm PF_GAMESCOPE_MODE=g1 \
        PF_APT_PROXY="${proxy}" "$@" \
        bash "${SRC}/scripts/build-rootfs-base.sh" --variant dev > "${out}.log" 2>&1
}

# The lib's own view of the solve, for the same profile, as the overlay sees it.
lib_env() {
    SRC_DIR="${SRC}" VARIANT=dev PF_DEVICE_ID=a133-open-7x-gpu PF_GPU_MODEL=open PF_HAS_DISPLAY=1 \
        PF_GAMESCOPE_MODE=g1 CLOUD_INIT_DIR="${TMP}/cloud-init" GPU_UM_MESA_DIR="${TMP}/gpu-um-mesa" \
        PF_APT_FIX_DIR="${TMP}/apt-fix" PF_APT_PROXY="${1:-}" bash -c '
            set -euo pipefail
            source "${SRC_DIR}/scripts/rootfs-package-list.sh"
            pf_rootfs_snapshot_url; pf_rootfs_package_list >/dev/null
            pf_rootfs_local_package_opts >/dev/null; pf_rootfs_apt_proxy_opts >/dev/null
            pf_rootfs_mmdebstrap_opts
            '"$2"
}

# ------------------------------------------------------------- 1. the base solve
base "${TMP}/out-proxy" http://10.0.32.86:3142 || { cat "${TMP}/out-proxy.log"; fail "base build failed"; }
mapfile -d '' got < "${TMP}/argv"
mapfile -d '' want < <(lib_env http://10.0.32.86:3142 'printf "%s\0" "${MMDEBSTRAP_SOLVE_OPTS[@]}" --skip=cleanup "${MMDEBSTRAP_DPKG_OPTS[@]}" bookworm; printf "%s\0" "${SNAPSHOT_URL}"')
n=${#got[@]}
[ "${n}" -eq $(( ${#want[@]} + 1 )) ] || fail "base argv has ${n} words, want $(( ${#want[@]} + 1 ))"
for i in "${!want[@]}"; do
    j=$i
    [ "$i" -lt $(( ${#want[@]} - 1 )) ] || j=$(( i + 1 ))   # the target dir sits before the URL
    [ "${got[j]}" = "${want[i]}" ] || fail "base argv[${j}]='${got[j]}' want '${want[i]}'"
done
printf '%s\n' "${got[@]}" | grep -q -- '^--customize-hook' && fail "the base ran a customize hook"
printf '%s\n' "${got[@]}" | grep -qx -- '--variant=minbase' || fail "the base is not the minbase solve"
printf '%s\n' "${got[@]}" | grep -qx -- '--include=/.*cloud-init-pocketforge.deb' || fail "cloud-init deb missing from the solve"
printf '%s\n' "${got[@]}" | grep -qx -- '--include=/.*pocketforge-open-gpu-stack.deb' || fail "GPU provider missing from the solve"
[ "$(cat "${TMP}/argv.epoch")" = "${EPOCH}" ] || fail "base epoch $(cat "${TMP}/argv.epoch") != snapshot instant ${EPOCH}"
ok "the base solve is the single pass's options + --skip=cleanup, no customize hook, epoch=snapshot instant"

# ------------------------------------------------------------- 2. transport-free
mkdir "${TMP}/x"
tar -xf "${TMP}/out-proxy/rootfs-base.tar" -C "${TMP}/x"
grep -q 'https://snapshot.debian.org/' "${TMP}/x/etc/apt/sources.list" || fail "base sources not https"
grep -q 'Proxy' "${TMP}/x/etc/apt/apt.conf.d/99mmdebstrap" && fail "base kept the persisted proxy line"
grep -qxF 'Acquire::Retries "5";' "${TMP}/x/etc/apt/apt.conf.d/99mmdebstrap" || fail "base lost a real aptopt"
grep -q 'Proxy\|3142' "${TMP}/out-proxy/rootfs-base.manifest" && fail "the manifest records the transport"
sleep 1   # different wall-clock mtimes; the clamp must hide them
base "${TMP}/out-direct" "" || { cat "${TMP}/out-direct.log"; fail "direct base build failed"; }
cmp -s "${TMP}/out-proxy/rootfs-base.tar" "${TMP}/out-direct/rootfs-base.tar" || fail "base tar depends on the fetch transport"
cmp -s "${TMP}/out-proxy/rootfs-base.manifest" "${TMP}/out-direct/rootfs-base.manifest" || fail "manifest depends on the fetch transport"
ok "proxy and direct bases are byte-identical (https sources, proxy line stripped, clamped sorted tar)"

# ------------------------------------------------------------- 3. overlay verify
verify() {  # <base-dir> -> rc in ${TMP}/vrc, stderr in ${TMP}/verr
    set +e
    lib_env "" "pf_rootfs_base_verify '$1'" > "${TMP}/vout" 2> "${TMP}/verr"
    echo $? > "${TMP}/vrc"
    set -e
}
verify "${TMP}/out-proxy"
[ "$(cat "${TMP}/vrc")" = 0 ] || { cat "${TMP}/verr"; fail "the overlay refused its own base"; }
grep -q 'identity verified' "${TMP}/vout" || fail "verify did not report"
cp "${SRC}/rootfs-packages.txt" "${TMP}/pkgs.orig"
printf 'pf-extra-package\n' >> "${SRC}/rootfs-packages.txt"
verify "${TMP}/out-proxy"
[ "$(cat "${TMP}/vrc")" = 1 ] && grep -q 'different solve' "${TMP}/verr" || fail "a changed package list was accepted"
cp "${TMP}/pkgs.orig" "${SRC}/rootfs-packages.txt"
printf 'rebuilt\n' >> "${TMP}/cloud-init/cloud-init-pocketforge.deb"
verify "${TMP}/out-proxy"
[ "$(cat "${TMP}/vrc")" = 1 ] && grep -q 'local_deb=.*cloud-init' "${TMP}/verr" || fail "a changed local deb was accepted"
printf 'cloud-init deb\n' > "${TMP}/cloud-init/cloud-init-pocketforge.deb"
cp -a "${TMP}/out-proxy" "${TMP}/tampered"
printf 'x' >> "${TMP}/tampered/rootfs-base.tar"
verify "${TMP}/tampered"
[ "$(cat "${TMP}/vrc")" = 1 ] && grep -q 'does not match its manifest' "${TMP}/verr" || fail "a tampered tar was accepted"
mkdir "${TMP}/empty"
verify "${TMP}/empty"
[ "$(cat "${TMP}/vrc")" = 1 ] && grep -q 'holds no rootfs-base.manifest' "${TMP}/verr" || fail "an empty base dir was accepted"
verify "${TMP}/out-proxy"
[ "$(cat "${TMP}/vrc")" = 0 ] || fail "restored inputs no longer verify"
ok "verify accepts its own base and refuses a changed package list, local deb, tarball or empty dir"

# ------------------------------------------------------------- 4. overlay options
mapfile -d '' over < <(lib_env "http://10.0.32.86:3142" 'pf_rootfs_overlay_opts /b; printf "%s\0" "${MMDEBSTRAP_OVERLAY_OPTS[@]}"')
expect=(--arch=arm64 --variant=custom --mode=root
    '--aptopt=Acquire::Check-Valid-Until "false"' '--aptopt=APT::Sandbox::User "root"'
    '--aptopt=Acquire::Retries "5"' '--aptopt=Acquire::Retries::Delay "false"'
    --skip=update '--setup-hook=tar-in /b/rootfs-base.tar /')
[ "${#over[@]}" -eq "${#expect[@]}" ] || fail "overlay opts: ${over[*]}"
for i in "${!expect[@]}"; do
    [ "${over[i]}" = "${expect[i]}" ] || fail "overlay opt[${i}]='${over[i]}' want '${expect[i]}'"
done
ok "the overlay replays the base as a custom variant: setup kept, update skipped, no packages, no proxy"

printf 'rootfs-base-solve-test: %s checks passed\n' "${pass}"
