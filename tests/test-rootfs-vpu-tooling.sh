#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="${ROOT}/scripts/verify-rootfs-vpu-tooling.py"
BUILDER="${ROOT}/scripts/build-rootfs.sh"
WORK="$(mktemp -d "${RUNNER_TEMP:-/tmp}/rootfs-vpu-tooling.XXXXXX")"

cleanup() {
    find "${WORK}" -mindepth 1 -delete
    rmdir "${WORK}"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

for command in mke2fs debugfs python3; do
    command -v "${command}" >/dev/null 2>&1 || fail "required test command is unavailable: ${command}"
done

commands=(v4l2-ctl gst-launch-1.0 gst-inspect-1.0)
plugins=(
    libgstcoreelements.so
    libgstvideoconvertscale.so
    libgstvideoparsersbad.so
    libgstv4l2codecs.so
)
packages=(
    v4l-utils
    gstreamer1.0-tools
    gstreamer1.0-plugins-base
    gstreamer1.0-plugins-bad
)

make_tree() {
    local root="$1"
    local omit="${2:-}"
    local nonexec="${3:-}"
    local command plugin package

    install -d \
        "${root}/usr/bin" \
        "${root}/usr/lib/aarch64-linux-gnu/gstreamer-1.0" \
        "${root}/var/lib/dpkg"

    for command in "${commands[@]}"; do
        [ "${omit}" = "command:${command}" ] && continue
        printf '#!/bin/sh\nexit 0\n' > "${root}/usr/bin/${command}"
        if [ "${nonexec}" = "${command}" ]; then
            chmod 0644 "${root}/usr/bin/${command}"
        else
            chmod 0755 "${root}/usr/bin/${command}"
        fi
    done

    for plugin in "${plugins[@]}"; do
        [ "${omit}" = "plugin:${plugin}" ] && continue
        printf 'fixture plugin bytes: %s\n' "${plugin}" \
            > "${root}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/${plugin}"
        chmod 0644 "${root}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/${plugin}"
    done

    : > "${root}/var/lib/dpkg/status"
    for package in "${packages[@]}"; do
        [ "${omit}" = "package:${package}" ] && continue
        printf 'Package: %s\nStatus: install ok installed\nArchitecture: arm64\n\n' "${package}" \
            >> "${root}/var/lib/dpkg/status"
    done
    chmod 0644 "${root}/var/lib/dpkg/status"
}

make_image() {
    local label="$1"
    local omit="${2:-}"
    local nonexec="${3:-}"
    local tree="${WORK}/${label}.root"
    local image="${WORK}/${label}.ext4"

    install -d "${tree}"
    make_tree "${tree}" "${omit}" "${nonexec}"
    truncate -s 8M "${image}"
    mke2fs -q -t ext4 -F -d "${tree}" "${image}"
    printf '%s\n' "${image}"
}

expect_pass() {
    local label="$1"
    local image="$2"
    local output

    output="$(python3 "${VERIFIER}" --gpu-model open --variant dev "${image}" 2>&1)" \
        || fail "${label}: verifier rejected a valid image: ${output}"
    for prerequisite in \
        /usr/bin/v4l2-ctl \
        /usr/bin/gst-launch-1.0 \
        /usr/bin/gst-inspect-1.0 \
        /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstcoreelements.so \
        /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideoconvertscale.so \
        /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideoparsersbad.so \
        /usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstv4l2codecs.so \
        v4l-utils \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-bad; do
        grep -Fq "${prerequisite}" <<< "${output}" \
            || fail "${label}: PASS output omitted ${prerequisite}: ${output}"
    done
    grep -Fq 'PASS: Cedrus strict-decode userspace verified from final ext4 bytes' <<< "${output}" \
        || fail "${label}: summary PASS missing: ${output}"
    echo "PASS: ${label}"
}

expect_fail() {
    local label="$1"
    local expected="$2"
    shift 2
    local output rc

    set +e
    output="$("$@" 2>&1)"
    rc=$?
    set -e
    [ "${rc}" -ne 0 ] || fail "${label}: negative control unexpectedly passed"
    grep -Fq "${expected}" <<< "${output}" \
        || fail "${label}: expected '${expected}', got: ${output}"
    echo "PASS: ${label}"
}

green_image="$(make_image green)"
expect_pass "GREEN has all commands, plugins, package stanzas, and executable modes" "${green_image}"

# The verifier must read the immutable ext4 bytes, not the now-changed source
# staging tree that mke2fs originally consumed.
find "${WORK}/green.root" -mindepth 1 -delete
expect_pass "GREEN still passes after its source staging tree is emptied" "${green_image}"

for command in "${commands[@]}"; do
    image="$(make_image "missing-command-${command}" "command:${command}")"
    expect_fail "RED missing command ${command}" "missing ${command}" \
        python3 "${VERIFIER}" --gpu-model open --variant dev "${image}"

    image="$(make_image "nonexec-command-${command}" "" "${command}")"
    expect_fail "RED non-executable command ${command}" "not executable ${command}" \
        python3 "${VERIFIER}" --gpu-model open --variant dev "${image}"
done

for plugin in "${plugins[@]}"; do
    image="$(make_image "missing-plugin-${plugin}" "plugin:${plugin}")"
    expect_fail "RED missing plugin ${plugin}" "missing ${plugin}" \
        python3 "${VERIFIER}" --gpu-model open --variant dev "${image}"
done

for package in "${packages[@]}"; do
    image="$(make_image "missing-package-${package}" "package:${package}")"
    expect_fail "RED missing package stanza ${package}" "missing package stanza ${package}" \
        python3 "${VERIFIER}" --gpu-model open --variant dev "${image}"
done

printf 'not an ext4 filesystem\n' > "${WORK}/malformed.img"
expect_fail "RED malformed input" "not a readable ext4 filesystem" \
    python3 "${VERIFIER}" --gpu-model open --variant dev "${WORK}/malformed.img"

install -d "${WORK}/ext2.root"
make_tree "${WORK}/ext2.root"
truncate -s 8M "${WORK}/ext2.img"
mke2fs -q -t ext2 -F -d "${WORK}/ext2.root" "${WORK}/ext2.img"
expect_fail "RED non-ext4 filesystem" "not a readable ext4 filesystem" \
    python3 "${VERIFIER}" --gpu-model open --variant dev "${WORK}/ext2.img"

expect_fail "RED closed-DDK invocation scope" "refusing excluded scope gpu_model=ddk variant=dev" \
    python3 "${VERIFIER}" --gpu-model ddk --variant dev "${green_image}"
expect_fail "RED release invocation scope" "refusing excluded scope gpu_model=open variant=release" \
    python3 "${VERIFIER}" --gpu-model open --variant release "${green_image}"
expect_fail "RED display-less invocation scope" "refusing excluded scope gpu_model=none variant=dev" \
    python3 "${VERIFIER}" --gpu-model none --variant dev "${green_image}"

python3 - "${BUILDER}" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
call = 'python3 "${SRC_DIR}/scripts/verify-rootfs-vpu-tooling.py"'
guard = 'if [ "${PF_GPU_MODEL}" = "open" ] && [ "${VARIANT}" = "dev" ]; then'
if text.count(call) != 1:
    raise SystemExit(f"FAIL: expected exactly one VPU verifier invocation, found {text.count(call)}")
call_at = text.index(call)
guard_at = text.rfind(guard, 0, call_at)
guard_end = text.find("\nfi", call_at)
mke2fs_at = text.index("mke2fs -t ext4")
success_at = text.index("ROOTFS BUILD COMPLETE")
if guard_at < 0 or guard_end < 0:
    raise SystemExit("FAIL: VPU verifier is not enclosed by the exact open+dev guard")
if not (mke2fs_at < guard_at < call_at < guard_end < success_at):
    raise SystemExit("FAIL: VPU verifier is not after mke2fs and before artifact success")
print("PASS: builder invokes the final-ext4 verifier exactly once, only for open+dev, after mke2fs and before success")
PY

echo "PASS: rootfs VPU tooling verifier hermetic GREEN and all RED controls"
