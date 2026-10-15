#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
selector="${root}/rootfs-overlay/usr/lib/pocketforge/pf-gamescope-kms-select"
unit="${root}/rootfs-overlay/etc/systemd/system/pocketforge-gamescope.service"
installer="${root}/scripts/install-gamescope-session.sh"
workflow="${root}/.github/workflows/hermetic-tests.yml"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/gamescope-kms-select.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_card() {
    local tree=$1
    local index=$2
    local driver=$3
    local connected=$4
    local card="card${index}"

    mkdir -p "${tree}/dev/dri" \
        "${tree}/sys/class/drm/${card}/device" \
        "${tree}/sys/bus/platform/drivers/${driver}"
    : >"${tree}/dev/dri/${card}"
    ln -s "${tree}/sys/bus/platform/drivers/${driver}" \
        "${tree}/sys/class/drm/${card}/device/driver"
    if test "${connected}" = yes; then
        mkdir -p "${tree}/sys/class/drm/${card}-DSI-1"
        printf 'connected\n' \
            >"${tree}/sys/class/drm/${card}-DSI-1/status"
        printf 'enabled\n' \
            >"${tree}/sys/class/drm/${card}-DSI-1/enabled"
    fi
}

run_positive() {
    local name=$1
    local kms_index=$2
    local render_index=$3
    local tree="${scratch}/${name}"
    local env_file="${tree}/kms.env"
    local stdout="${tree}/stdout"

    make_card "${tree}" "${kms_index}" sun4i-drm yes
    make_card "${tree}" "${render_index}" powervr no
    PF_DRM_DEV_ROOT="${tree}/dev/dri" \
        PF_DRM_SYS_ROOT="${tree}/sys" \
        PF_GAMESCOPE_KMS_ENV="${env_file}" \
        "${selector}" >"${stdout}"
    grep -Fx "PF_GAMESCOPE_KMS_NODE=${tree}/dev/dri/card${kms_index}" \
        "${env_file}" >/dev/null \
        || fail "${name} did not select sun4i-drm card${kms_index}"
    grep -Fx \
        "PF_GAMESCOPE_KMS_SELECT state=PASS driver=sun4i-drm node=${tree}/dev/dri/card${kms_index}" \
        "${stdout}" >/dev/null \
        || fail "${name} omitted the typed success receipt"
}

test -x "${selector}" || fail "KMS selector is missing or not executable"
install_root="${scratch}/installed"
"${installer}" g1 "${install_root}"
installed_selector="${install_root}/usr/lib/pocketforge/pf-gamescope-kms-select"
test -x "${installed_selector}" \
    || fail "g1 installer omitted the executable KMS selector"
cmp -s "${selector}" "${installed_selector}" \
    || fail "installed KMS selector differs from the source artifact"

# Positive controls: the display driver wins in both probe orders. The PowerVR
# primary node deliberately has no connector resource.
run_positive kms_second 1 0
run_positive kms_first 0 1

# Negative control: a render-only tree must refuse with a typed reason and must
# not leave a stale selector EnvironmentFile behind.
tree="${scratch}/no-kms"
make_card "${tree}" 0 powervr no
make_card "${tree}" 1 powervr no
: >"${tree}/kms.env"
if PF_DRM_DEV_ROOT="${tree}/dev/dri" \
    PF_DRM_SYS_ROOT="${tree}/sys" \
    PF_GAMESCOPE_KMS_ENV="${tree}/kms.env" \
    "${selector}" >"${tree}/stdout" 2>"${tree}/stderr"; then
    fail "render-only tree was accepted"
fi
grep -Fx 'PF_GAMESCOPE_KMS_SELECT state=REFUSED reason=no_kms_node' \
    "${tree}/stderr" >/dev/null \
    || fail "render-only refusal did not preserve the typed reason"
test ! -e "${tree}/kms.env" \
    || fail "render-only refusal retained a stale EnvironmentFile"

# Connector enablement reflects current display ownership, not KMS capability.
# A connected panel must remain selectable after the previous owner releases it.
tree="${scratch}/connected-disabled"
make_card "${tree}" 0 sun4i-drm no
mkdir -p "${tree}/sys/class/drm/card0-DSI-1"
printf 'connected\n' >"${tree}/sys/class/drm/card0-DSI-1/status"
printf 'disabled\n' >"${tree}/sys/class/drm/card0-DSI-1/enabled"
PF_DRM_DEV_ROOT="${tree}/dev/dri" \
    PF_DRM_SYS_ROOT="${tree}/sys" \
    PF_GAMESCOPE_KMS_ENV="${tree}/kms.env" \
    "${selector}" >"${tree}/stdout"
grep -Fx "PF_GAMESCOPE_KMS_NODE=${tree}/dev/dri/card0" \
    "${tree}/kms.env" >/dev/null \
    || fail "connected disabled panel did not select sun4i-drm card0"

# A second display candidate is ambiguous; selecting the lowest card number
# would silently reintroduce the probe-order dependency.
tree="${scratch}/ambiguous"
make_card "${tree}" 0 sun4i-drm yes
make_card "${tree}" 1 sun4i-drm yes
if PF_DRM_DEV_ROOT="${tree}/dev/dri" \
    PF_DRM_SYS_ROOT="${tree}/sys" \
    PF_GAMESCOPE_KMS_ENV="${tree}/kms.env" \
    "${selector}" >"${tree}/stdout" 2>"${tree}/stderr"; then
    fail "ambiguous KMS tree was accepted"
fi
grep -Fx 'PF_GAMESCOPE_KMS_SELECT state=REFUSED reason=ambiguous_kms_nodes count=2' \
    "${tree}/stderr" >/dev/null \
    || fail "ambiguous refusal did not preserve the typed reason"

# Production wiring passes the discovered path to Gamescope and grants the DRM
# device class, not a numbered node.
grep -Fx 'ExecStartPre=/usr/lib/pocketforge/pf-gamescope-kms-select' "${unit}" >/dev/null
grep -Fx 'EnvironmentFile=-/run/pocketforge/gamescope/kms.env' "${unit}" >/dev/null
# The literal is the systemd environment expansion contract, not shell input.
# shellcheck disable=SC2016
grep -F -- '--prefer-drm ${PF_GAMESCOPE_KMS_NODE}' "${unit}" >/dev/null
grep -Fx 'DeviceAllow=char-drm rw' "${unit}" >/dev/null
if grep -v '^[[:space:]]*#' "${unit}" \
    | grep -F 'systemd-udev-settle.service' >/dev/null; then
    fail "Gamescope KMS discovery pulls in the global udev-settle barrier"
fi
if grep -Eq '/dev/dri/card[0-9]|dev-dri-card[0-9]' "${unit}"; then
    fail "Gamescope unit still pins a DRM card index"
fi
grep -F 'pf-gamescope-kms-select' "${installer}" >/dev/null \
    || fail "installer omits the KMS selector"
test "$(grep -n '^ExecStartPre=' "${unit}" | head -n 1 | cut -d: -f2-)" \
    = 'ExecStartPre=/usr/lib/pocketforge/pf-gamescope-kms-select' \
    || fail "KMS refusal would stop the selected shell before failing"
grep -F 'tests/test-gamescope-kms-select.sh' "${workflow}" >/dev/null \
    || fail "hermetic workflow omits the KMS selector test"

echo 'PASS: Gamescope KMS selection is capability-based and probe-order independent'
