#!/usr/bin/env bash
# Release exclusion for the dev-only bench USB network (bd tsp-mc9m.41.984.34.2).
#
# The property: a release rootfs never contains the bench USB network (it
# switches USB0's role), and a dev kernel-sunxi-7.x rootfs contains it exactly
# and enabled. Enforced by scripts/verify-rootfs-usbnet-bench.py, which parses
# the extracted tree (paths, names, symlink targets, content digests, the unit's
# [Install] section) rather than grepping build text.
#
#   1. The install function is run exactly as scripts/build-rootfs.sh generates
#      it (captured from the real customize hook), for each variant/kernel.
#   2. The guard passes the correct trees and FAILS every wrong one: the dev
#      tree checked as release, hostile release trees (renamed copy, stray
#      enablement link, moved .network, unit under /lib), broken dev trees, a
#      committed unit whose [Install] drifts, and unparseable input.
#   3. build-rootfs.sh itself is driven through a fake mmdebstrap that runs the
#      captured install function, so the guard is proven to be INVOKED on the
#      extracted rootfs of both variants and to stop a release build that
#      wrongly includes the unit.
# Hermetic: tmpdir fixtures, a fake mmdebstrap and qemu shim, python3, tar.
set -euo pipefail
# The production extraction runs as root and preserves archive modes. Make the
# non-root fixture model that behavior independently of the caller's umask.
umask 022

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="${root}/scripts/verify-rootfs-usbnet-bench.py"
scratch="$(mktemp -d)"
cleanup() {
    chmod -R u+rwX "${scratch}" 2>/dev/null || true
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
unit=pocketforge-usbnet-bench.service
artifacts=(
    usr/lib/pocketforge/usbnet-bench.sh
    "etc/systemd/system/${unit}"
    etc/udev/rules.d/80-pocketforge-usbnet-bench.rules
    etc/systemd/network/30-usb0.network
)
enable_link="etc/systemd/system/usb-gadget.target.wants/${unit}"

# --- 1. the install function, exactly as the generated hook defines it --------
# shellcheck source=tests/lib/capture-customize-hook.sh
. "${root}/tests/lib/capture-customize-hook.sh"
hook="${scratch}/customize-hook.sh"
capture_customize_hook "${root}" "${scratch}/capture" "${hook}"
[ "$(grep -cx 'install_usbnet_bench() {' "${hook}")" -eq 1 ] \
    || fail "generated hook must define install_usbnet_bench exactly once"
install_fn="${scratch}/install-usbnet-bench.sh"
awk '/^install_usbnet_bench\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' \
    "${hook}" > "${install_fn}"
[ "$(tail -n 1 "${install_fn}")" = '}' ] || fail "could not extract install_usbnet_bench from the hook"

# install_tree DEST VARIANT KERNEL [SRC]
install_tree() {
    mkdir -p "$1"
    # shellcheck disable=SC2016 # expanded by the inner bash, not here
    env -i PATH="${PATH}" bash -c 'set -euo pipefail; source "$1"; shift; install_usbnet_bench "$@"' \
        _ "${install_fn}" "$1" "$2" "$3" "${4:-${root}}" < /dev/null > "$1.log"
}
install_tree "${scratch}/dev7x" dev kernel-sunxi-7.x
install_tree "${scratch}/release7x" release kernel-sunxi-7.x
install_tree "${scratch}/dev6x" dev kernel-sunxi-6.x
install_tree "${scratch}/devnone" dev ""
for rel in "${artifacts[@]}"; do
    if [ ! -f "${scratch}/dev7x/${rel}" ] || [ -L "${scratch}/dev7x/${rel}" ]; then
        fail "dev kernel-sunxi-7.x rootfs lacks ${rel}"
    fi
done
[ "$(readlink "${scratch}/dev7x/${enable_link}")" = "/etc/systemd/system/${unit}" ] \
    || fail "dev rootfs does not enable ${unit} through usb-gadget.target.wants"
for tree in release7x dev6x devnone; do
    [ -z "$(find "${scratch}/${tree}" -mindepth 1 -print -quit)" ] \
        || fail "${tree}: install_usbnet_bench installed something"
    grep -F '[customize] usbnet bench: NOT-SHIPPED' "${scratch}/${tree}.log" >/dev/null \
        || fail "${tree}: no NOT-SHIPPED log line"
done
grep -Fx "[customize] dev: usbnet bench installed (usbnet contract v1: ${unit} via usb-gadget.target, 30-usb0.network, VBUS udev rule)" \
    "${scratch}/dev7x.log" >/dev/null || fail "dev install printed no positive log line"
# The unit's ExecStart must name the installed, executable script.
exec_start="$(python3 - "${scratch}/dev7x/etc/systemd/system/${unit}" <<'PY'
import sys
section = None
found = []
for raw in open(sys.argv[1], encoding="utf-8"):
    line = raw.strip()
    if not line or line[0] in "#;":
        continue
    if line.startswith("["):
        section = line[1:-1]
        continue
    key, _, value = line.partition("=")
    if section == "Service" and key.strip() == "ExecStart":
        found.append(value.strip())
print(found[0] if len(found) == 1 else "")
PY
)"
if [ -z "${exec_start}" ] || [ ! -x "${scratch}/dev7x${exec_start}" ]; then
    fail "unit ExecStart '${exec_start}' is not an executable in the dev rootfs"
fi
echo "install function: dev/kernel-sunxi-7.x installs and enables; release, 6.x and no kernel install nothing: PASS"

# --- 2. the guard over good, wrong and unparseable trees ----------------------
# expect_guard LABEL WANT_RC TREE VARIANT KERNEL [SRC] [NEEDLE]
expect_guard() {
    local label="$1" want="$2" tree="$3" variant="$4" kernel="$5" src="${6:-${root}}" needle="${7:-}"
    local rc=0
    python3 "${guard}" --variant "${variant}" --kernel-repo "${kernel}" --src "${src}" "${tree}" \
        > "${scratch}/${label}.out" 2> "${scratch}/${label}.err" || rc=$?
    [ "${rc}" -eq "${want}" ] || {
        cat "${scratch}/${label}.out" "${scratch}/${label}.err" >&2
        fail "guard case ${label}: exit ${rc}, want ${want}"
    }
    if [ -n "${needle}" ]; then
        grep -F -- "${needle}" "${scratch}/${label}.out" "${scratch}/${label}.err" >/dev/null || {
            cat "${scratch}/${label}.out" "${scratch}/${label}.err" >&2
            fail "guard case ${label}: missing '${needle}'"
        }
    fi
    if [ -n "${needle}" ]; then
        echo "guard ${label}: exit ${rc} as expected, quoting: ${needle}"
    else
        echo "guard ${label}: exit ${rc} as expected"
    fi
}

expect_guard dev-present 0 "${scratch}/dev7x" dev kernel-sunxi-7.x "" \
    'usbnet-bench rootfs guard: PASS variant=dev kernel=kernel-sunxi-7.x expected=present artifacts=4 enabled_by=usb-gadget.target'
expect_guard release-absent 0 "${scratch}/release7x" release kernel-sunxi-7.x "" \
    'usbnet-bench rootfs guard: PASS variant=release kernel=kernel-sunxi-7.x expected=absent hits=0'
expect_guard dev6x-absent 0 "${scratch}/dev6x" dev kernel-sunxi-6.x "" 'expected=absent hits=0'
# The guard must be shown to fail on a release rootfs that wrongly includes it.
expect_guard release-includes-unit 1 "${scratch}/dev7x" release kernel-sunxi-7.x "" \
    "usbnet-bench rootfs guard: FAIL shipped_in_excluded_rootfs etc/systemd/system/${unit} (content,name)"
expect_guard dev6x-includes-unit 1 "${scratch}/dev7x" dev kernel-sunxi-6.x "" \
    "FAIL shipped_in_excluded_rootfs ${enable_link} (link,name)"

# Hostile release trees: each hides one piece the name-only check would miss.
hostile() {
    local label="$1"
    rm -rf "${scratch:?}/${label}"
    mkdir -p "${scratch}/${label}"
    printf 'unrelated\n' > "${scratch}/${label}/marker"
}
hostile renamed-script
install -D -m 0755 "${root}/rootfs-overlay/usr/lib/pocketforge/usbnet-bench.sh" \
    "${scratch}/renamed-script/usr/local/bin/pf-helper"
expect_guard hostile-renamed-copy 1 "${scratch}/renamed-script" release kernel-sunxi-7.x "" \
    'FAIL shipped_in_excluded_rootfs usr/local/bin/pf-helper (content)'
hostile stray-link
mkdir -p "${scratch}/stray-link/etc/systemd/system/multi-user.target.wants"
ln -s "/lib/systemd/system/${unit}" "${scratch}/stray-link/etc/systemd/system/multi-user.target.wants/bench.service"
expect_guard hostile-stray-link 1 "${scratch}/stray-link" release kernel-sunxi-7.x "" \
    'FAIL shipped_in_excluded_rootfs etc/systemd/system/multi-user.target.wants/bench.service (link)'
hostile moved-network
install -D -m 0644 /dev/null "${scratch}/moved-network/lib/systemd/network/30-usb0.network"
expect_guard hostile-moved-network 1 "${scratch}/moved-network" release kernel-sunxi-7.x "" \
    'FAIL shipped_in_excluded_rootfs lib/systemd/network/30-usb0.network (name)'
hostile lib-unit
install -D -m 0644 "${root}/rootfs-overlay/etc/systemd/system/${unit}" \
    "${scratch}/lib-unit/lib/systemd/system/${unit}"
expect_guard hostile-lib-unit 1 "${scratch}/lib-unit" release kernel-sunxi-7.x "" \
    "FAIL shipped_in_excluded_rootfs lib/systemd/system/${unit} (content,name)"

# Broken dev trees.
cp -a "${scratch}/dev7x" "${scratch}/dev-unenabled"
rm "${scratch}/dev-unenabled/${enable_link}"
expect_guard dev-not-enabled 1 "${scratch}/dev-unenabled" dev kernel-sunxi-7.x "" \
    "FAIL not_enabled ${enable_link} is not a symlink"
cp -a "${scratch}/dev7x" "${scratch}/dev-mode"
chmod 0644 "${scratch}/dev-mode/usr/lib/pocketforge/usbnet-bench.sh"
expect_guard dev-script-mode 1 "${scratch}/dev-mode" dev kernel-sunxi-7.x "" \
    'FAIL mode usr/lib/pocketforge/usbnet-bench.sh 0o644 != 0o755'
cp -a "${scratch}/dev7x" "${scratch}/dev-edited"
printf '# edited\n' >> "${scratch}/dev-edited/etc/systemd/network/30-usb0.network"
expect_guard dev-edited-network 1 "${scratch}/dev-edited" dev kernel-sunxi-7.x "" \
    'FAIL content_mismatch etc/systemd/network/30-usb0.network'
cp -a "${scratch}/dev7x" "${scratch}/dev-missing"
rm "${scratch}/dev-missing/etc/udev/rules.d/80-pocketforge-usbnet-bench.rules"
expect_guard dev-missing-rule 1 "${scratch}/dev-missing" dev kernel-sunxi-7.x "" \
    'FAIL missing etc/udev/rules.d/80-pocketforge-usbnet-bench.rules'
cp -a "${scratch}/dev7x" "${scratch}/dev-extra"
ln -s "/etc/systemd/system/${unit}" "${scratch}/dev-extra/etc/systemd/system/multi-user.target.wants-${unit}"
expect_guard dev-extra-link 1 "${scratch}/dev-extra" dev kernel-sunxi-7.x "" \
    "FAIL unexpected etc/systemd/system/multi-user.target.wants-${unit} (link)"

# A committed unit whose [Install] drifts, and unparseable/missing sources.
drift_src="${scratch}/drift-src"
mkdir -p "${drift_src}"
cp -a "${root}/rootfs-overlay" "${drift_src}/rootfs-overlay"
sed -i 's/^WantedBy=usb-gadget.target$/WantedBy=multi-user.target/' \
    "${drift_src}/rootfs-overlay/etc/systemd/system/${unit}"
install_tree "${scratch}/dev-drift" dev kernel-sunxi-7.x "${drift_src}"
expect_guard dev-install-drift 1 "${scratch}/dev-drift" dev kernel-sunxi-7.x "${drift_src}" \
    "FAIL install_section {'WantedBy': ['multi-user.target']}"
printf 'this is not unit syntax\n' >> "${drift_src}/rootfs-overlay/etc/systemd/system/${unit}"
install_tree "${scratch}/dev-garbage" dev kernel-sunxi-7.x "${drift_src}"
expect_guard dev-unparseable-unit 1 "${scratch}/dev-garbage" dev kernel-sunxi-7.x "${drift_src}" \
    "FAIL unit_unparseable"
rm "${drift_src}/rootfs-overlay/etc/systemd/network/30-usb0.network"
expect_guard source-missing 1 "${scratch}/release7x" release kernel-sunxi-7.x "${drift_src}" \
    'FAIL source_artifact_missing rootfs-overlay/etc/systemd/network/30-usb0.network'
echo "guard: passes correct trees, fails every wrong or unparseable one: PASS"

# --- 3. build-rootfs.sh invokes the guard on its extracted rootfs --------------
fixture="${scratch}/build"
fixture_src="${fixture}/src"
release="${fixture}/kernel/7.0.0-pocketforge"
mkdir -p "${fixture_src}/scripts" "${fixture_src}/boards/tsp" \
    "${fixture_src}/packages/pocketforge-open-gpu-stack/DEBIAN" \
    "${fixture}/bin" "${fixture}/out" "${fixture}/wpa" \
    "${fixture}/blobs/sunxi/a133/wifi-firmware" "${fixture}/mesa/usr/local/lib/gbm" "${release}"
# Keep this fixture focused on final-rootfs USB guard ordering. Stage the real
# builder inputs but replace the independently tested GPU-tools verifier with a
# named stub; the synthetic tar below intentionally contains no dpkg database,
# GPU userspace, or tool binaries.
cp -a "${root}/scripts/." "${fixture_src}/scripts/"
cp -a "${root}/rootfs-overlay" "${fixture_src}/rootfs-overlay"
for input in rootfs-packages.txt rootfs-packages-dev.txt rootfs-packages-mainline.txt \
    rootfs-packages-mainline-dev.txt rootfs-packages-a133-open-7x-gpu.txt \
    snapshot-date.txt; do
    install -m 0644 "${root}/${input}" "${fixture_src}/${input}"
done
install -m 0644 "${root}/boards/tsp/fs-uuids.env" \
    "${fixture_src}/boards/tsp/fs-uuids.env"
install -m 0644 "${root}/packages/pocketforge-open-gpu-stack/DEBIAN/control" \
    "${fixture_src}/packages/pocketforge-open-gpu-stack/DEBIAN/control"
cat > "${fixture_src}/scripts/verify-open-gpu-tools.sh" <<'EOF'
#!/bin/sh
echo 'open-gpu-tools fixture=SKIP scope=usbnet-final-rootfs-ordering'
EOF
cat > "${fixture_src}/scripts/verify-mesa-shader-cache.sh" <<'EOF'
#!/bin/sh
echo 'mesa-shader-cache fixture=SKIP scope=usbnet-final-rootfs-ordering'
EOF
chmod 0755 "${fixture_src}/scripts/verify-open-gpu-tools.sh" \
    "${fixture_src}/scripts/verify-mesa-shader-cache.sh"
: > "${fixture}/blobs/sunxi/a133/wifi-firmware/fw_xr829.bin"
: > "${fixture}/blobs/sunxi/a133/wifi-firmware/fw_xr829_bt.bin"
for library in libEGL.so libGLESv2.so libgbm.so gbm/dri_gbm.so; do
    : > "${fixture}/mesa/usr/local/lib/${library}"
done
: > "${release}/modules.builtin"
: > "${release}/powervr.ko"
: > "${fixture}/wpa/wpa_supplicant"
cat > "${fixture}/bin/qemu-aarch64-static" <<'EOF'
#!/bin/sh
exit 0
EOF
# The fake mmdebstrap runs the hook's REAL install_usbnet_bench with the
# variant and kernel the real hook command carries, optionally tampers with the
# tree, and writes the rootfs tar build-rootfs.sh extracts next.
cat > "${fixture}/bin/mmdebstrap" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
hook_command=""
tar_out=""
for arg in "$@"; do
    case "${arg}" in
        --customize-hook=*) hook_command="${arg#--customize-hook=}" ;;
        */rootfs.tar) tar_out="${arg}" ;;
    esac
done
variant=""
kernel=""
hook=""
for word in ${hook_command}; do
    case "${word}" in
        POCKETFORGE_VARIANT=*) variant="${word#*=}" ;;
        PF_KERNEL_REPO=*) kernel="${word#*=}" ;;
        */customize-hook.sh) hook="${word}" ;;
    esac
done
[ -f "${hook}" ] && [ -n "${tar_out}" ] && [ -n "${variant}" ] || {
    echo "fake mmdebstrap: missing hook, tar or variant in: $*" >&2
    exit 1
}
tree="$(mktemp -d "${PF_TEST_WORK}/rootfs.XXXXXX")"
awk '/^install_usbnet_bench\(\) \{$/ { on = 1 } on { print } on && /^}$/ { exit }' \
    "${hook}" > "${tree}.fn"
env -i PATH="${PATH}" bash -c 'set -euo pipefail; source "$1"; shift; install_usbnet_bench "$@"' \
    _ "${tree}.fn" "${tree}" "${variant}" "${kernel}" "${PF_TEST_SRC}" < /dev/null
case "${PF_TEST_TAMPER:-none}" in
    none) ;;
    release-includes-unit)
        install -D -m 0644 "${PF_TEST_SRC}/rootfs-overlay/etc/systemd/system/pocketforge-usbnet-bench.service" \
            "${tree}/etc/systemd/system/pocketforge-usbnet-bench.service" ;;
    dev-drops-network) rm "${tree}/etc/systemd/network/30-usb0.network" ;;
    *) echo "fake mmdebstrap: unknown tamper ${PF_TEST_TAMPER}" >&2; exit 1 ;;
esac
tar -C "${tree}" -cf "${tar_out}" .
EOF
chmod 0755 "${fixture}/bin/qemu-aarch64-static" "${fixture}/bin/mmdebstrap"

# run_build LABEL VARIANT TAMPER -- the build must stop (the fake rootfs cannot
# satisfy the later DNS verifier); prints the exit status.
run_build() {
    local label="$1" variant="$2" tamper="$3" status=0
    mkdir -p "${fixture}/work-${label}"
    PATH="${fixture}/bin:${PATH}" PF_TEST_WORK="${fixture}/work-${label}" \
    PF_TEST_SRC="${root}" PF_TEST_TAMPER="${tamper}" \
    SRC_DIR="${fixture_src}" BLOBS_DIR="${fixture}/blobs" \
    GPU_UM_MESA_DIR="${fixture}/mesa" WPA_DIR="${fixture}/wpa" \
    KERNEL_TSP_DIR="${fixture}/kernel" GPU_KM_TSP_DIR="${fixture}/unused-gpu" \
    OUT_DIR="${fixture}/out" SOURCE_DATE_EPOCH=1700000000 \
    PF_DEVICE_ID=a133-open-7x-gpu PF_KERNEL_REPO=kernel-sunxi-7.x PF_GPU_MODEL=open \
    PF_GPU_KM_MODEL=in-tree-7.x PF_KERNEL_REQUIRED_MODULES=powervr \
    PF_DISPLAY_PIPELINE=none \
        bash "${root}/scripts/build-rootfs.sh" --variant "${variant}" \
        > "${fixture}/${label}.out" 2> "${fixture}/${label}.err" || status=$?
    printf '%s\n' "${status}"
}
dns_stop='/etc/resolv.conf is not a symlink'
build_case() {
    local label="$1" variant="$2" tamper="$3" want="$4" guard_passed="$5" status
    status="$(run_build "${label}" "${variant}" "${tamper}")"
    [ "${status}" -ne 0 ] || fail "build ${label}: fixture build unexpectedly completed"
    if ! grep -F -- "${want}" "${fixture}/${label}.out" "${fixture}/${label}.err" >/dev/null; then
        tail -n 30 "${fixture}/${label}.err" >&2
        fail "build ${label}: missing '${want}'"
    fi
    if [ "${guard_passed}" = yes ]; then
        # The guard passed, so the build went on to the next verifier.
        grep -F -- "${dns_stop}" "${fixture}/${label}.err" >/dev/null \
            || fail "build ${label}: did not continue past the guard to the DNS verifier"
    elif grep -F -- "${dns_stop}" "${fixture}/${label}.err" >/dev/null; then
        fail "build ${label}: continued past a failing guard"
    fi
    echo "build-rootfs.sh ${label} (--variant ${variant}): '${want}'"
}
build_case release-clean release none \
    'usbnet-bench rootfs guard: PASS variant=release kernel=kernel-sunxi-7.x expected=absent hits=0' yes
build_case release-tampered release release-includes-unit \
    "usbnet-bench rootfs guard: FAIL shipped_in_excluded_rootfs etc/systemd/system/${unit} (content,name)" no
build_case dev-clean dev none \
    'usbnet-bench rootfs guard: PASS variant=dev kernel=kernel-sunxi-7.x expected=present artifacts=4 enabled_by=usb-gadget.target' yes
build_case dev-tampered dev dev-drops-network \
    'usbnet-bench rootfs guard: FAIL missing etc/systemd/network/30-usb0.network' no
echo "usbnet-bench rootfs release exclusion: PASS"
