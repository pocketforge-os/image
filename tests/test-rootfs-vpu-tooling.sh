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

make_elf() {
    local path="$1"
    local machine="$2"
    local descriptor="$3"
    shift 3
    python3 - "${path}" "${machine}" "${descriptor}" "$@" <<'PY'
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
machine = int(sys.argv[2])
descriptor = sys.argv[3]
literals = sys.argv[4:]

section_names = b"\0.shstrtab\0.dynstr\0.dynsym\0.rodata\0"
dynstr = b"\0" + (descriptor.encode("ascii") + b"\0" if descriptor else b"")
dynsym = bytearray(24)
if descriptor:
    dynsym.extend(struct.pack("<IBBHQQ", 1, 0x12, 0, 4, 0, 0))
rodata = b"".join(value.encode("ascii") + b"\0" for value in literals) or b"\0"

image = bytearray(64)


def append(data, alignment=1):
    while len(image) % alignment:
        image.append(0)
    offset = len(image)
    image.extend(data)
    return offset


shstr_offset = append(section_names)
dynstr_offset = append(dynstr)
dynsym_offset = append(dynsym, 8)
rodata_offset = append(rodata)
while len(image) % 8:
    image.append(0)
section_offset = len(image)

sections = [
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
    (section_names.index(b".shstrtab"), 3, 0, 0, shstr_offset, len(section_names), 0, 0, 1, 0),
    (section_names.index(b".dynstr"), 3, 2, 0, dynstr_offset, len(dynstr), 0, 0, 1, 0),
    (section_names.index(b".dynsym"), 11, 2, 0, dynsym_offset, len(dynsym), 2, 1, 8, 24),
    (section_names.index(b".rodata"), 1, 2, 0, rodata_offset, len(rodata), 0, 0, 1, 0),
]
for section in sections:
    image.extend(struct.pack("<IIQQQQIIQQ", *section))

ident = b"\x7fELF" + bytes((2, 1, 1, 0)) + bytes(8)
header = struct.pack(
    "<16sHHIQQQIHHHHHH",
    ident,
    3,
    machine,
    1,
    0,
    0,
    section_offset,
    0,
    64,
    0,
    0,
    64,
    len(sections),
    1,
)
image[:64] = header
path.write_bytes(image)
PY
}

make_plugin_elf() {
    local path="$1"
    local plugin="$2"
    local machine="${3:-183}"
    local descriptor_override="${4:-}"
    local descriptor

    case "${plugin}" in
        libgstcoreelements.so)
            descriptor="gst_plugin_coreelements_get_desc"
            [ -n "${descriptor_override}" ] && descriptor="${descriptor_override}"
            make_elf "${path}" "${machine}" "${descriptor}" filesrc filesink
            ;;
        libgstvideoconvertscale.so)
            descriptor="gst_plugin_videoconvertscale_get_desc"
            [ -n "${descriptor_override}" ] && descriptor="${descriptor_override}"
            make_elf "${path}" "${machine}" "${descriptor}" videoconvert
            ;;
        libgstvideoparsersbad.so)
            descriptor="gst_plugin_videoparsersbad_get_desc"
            [ -n "${descriptor_override}" ] && descriptor="${descriptor_override}"
            make_elf "${path}" "${machine}" "${descriptor}" h264parse
            ;;
        libgstv4l2codecs.so)
            descriptor="gst_plugin_v4l2codecs_get_desc"
            [ -n "${descriptor_override}" ] && descriptor="${descriptor_override}"
            make_elf "${path}" "${machine}" "${descriptor}" 'v4l2sl%sh264dec'
            ;;
        *) fail "unknown fixture plugin ${plugin}" ;;
    esac
}

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
        make_elf "${root}/usr/bin/${command}" 183 ""
        if [ "${nonexec}" = "${command}" ]; then
            chmod 0644 "${root}/usr/bin/${command}"
        else
            chmod 0755 "${root}/usr/bin/${command}"
        fi
    done

    for plugin in "${plugins[@]}"; do
        [ "${omit}" = "plugin:${plugin}" ] && continue
        make_plugin_elf \
            "${root}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/${plugin}" \
            "${plugin}"
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
    pack_image "${label}" "${tree}"
}

pack_image() {
    local label="$1"
    local tree="$2"
    local image="${WORK}/${label}.ext4"

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
        'command /usr/bin/v4l2-ctl executable mode=0o755 arch=ELF64-LE-AArch64-ET_DYN' \
        'command /usr/bin/gst-launch-1.0 executable mode=0o755 arch=ELF64-LE-AArch64-ET_DYN' \
        'command /usr/bin/gst-inspect-1.0 executable mode=0o755 arch=ELF64-LE-AArch64-ET_DYN' \
        "element filesrc arch=ELF64-LE-AArch64-ET_DYN descriptor=gst_plugin_coreelements_get_desc exported read_only_string=filesrc NUL-terminated; runtime registration remains the strict device probe's job" \
        "element filesink arch=ELF64-LE-AArch64-ET_DYN descriptor=gst_plugin_coreelements_get_desc exported read_only_string=filesink NUL-terminated; runtime registration remains the strict device probe's job" \
        "element videoconvert arch=ELF64-LE-AArch64-ET_DYN descriptor=gst_plugin_videoconvertscale_get_desc exported read_only_string=videoconvert NUL-terminated; runtime registration remains the strict device probe's job" \
        "element h264parse arch=ELF64-LE-AArch64-ET_DYN descriptor=gst_plugin_videoparsersbad_get_desc exported read_only_string=h264parse NUL-terminated; runtime registration remains the strict device probe's job" \
        "element v4l2slh264dec arch=ELF64-LE-AArch64-ET_DYN descriptor=gst_plugin_v4l2codecs_get_desc exported read_only_runtime_name_template=v4l2sl%sh264dec NUL-terminated literal_constructed_at_runtime=true; runtime registration remains the strict device probe's job" \
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

tree="${WORK}/wrong-plugin-libgstcoreelements.so.root"
install -d "${tree}"
make_tree "${tree}"
make_plugin_elf \
    "${tree}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstcoreelements.so" \
    libgstcoreelements.so 183 gst_plugin_wrong_get_desc
image="$(pack_image wrong-plugin-libgstcoreelements.so "${tree}")"
expect_fail "RED wrong plugin descriptor libgstcoreelements.so" "missing exported descriptor" \
    python3 "${VERIFIER}" --gpu-model open --variant dev "${image}"

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

for plugin in "${plugins[@]:1}"; do
    tree="${WORK}/wrong-plugin-${plugin}.root"
    install -d "${tree}"
    make_tree "${tree}"
    make_plugin_elf \
        "${tree}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/${plugin}" \
        "${plugin}" 183 gst_plugin_wrong_get_desc
    image="$(pack_image "wrong-plugin-${plugin}" "${tree}")"
    expect_fail "RED wrong plugin descriptor ${plugin}" "missing exported descriptor" \
        python3 "${VERIFIER}" --gpu-model open --variant dev "${image}"
done

for element in filesrc filesink videoconvert h264parse v4l2slh264dec; do
    tree="${WORK}/missing-element-${element}.root"
    install -d "${tree}"
    make_tree "${tree}"
    case "${element}" in
        filesrc)
            make_elf "${tree}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstcoreelements.so" \
                183 gst_plugin_coreelements_get_desc filesink
            expected="missing read-only element string filesrc"
            ;;
        filesink)
            make_elf "${tree}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstcoreelements.so" \
                183 gst_plugin_coreelements_get_desc filesrc
            expected="missing read-only element string filesink"
            ;;
        videoconvert)
            make_elf "${tree}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideoconvertscale.so" \
                183 gst_plugin_videoconvertscale_get_desc
            expected="missing read-only element string videoconvert"
            ;;
        h264parse)
            make_elf "${tree}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideoparsersbad.so" \
                183 gst_plugin_videoparsersbad_get_desc
            expected="missing read-only element string h264parse"
            ;;
        v4l2slh264dec)
            make_elf "${tree}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstv4l2codecs.so" \
                183 gst_plugin_v4l2codecs_get_desc
            expected="missing read-only runtime-name template v4l2sl%sh264dec"
            ;;
    esac
    image="$(pack_image "missing-element-${element}" "${tree}")"
    expect_fail "RED right descriptor missing ${element} string" "${expected}" \
        python3 "${VERIFIER}" --gpu-model open --variant dev "${image}"
done

tree="${WORK}/x86-plugin.root"
install -d "${tree}"
make_tree "${tree}"
make_plugin_elf \
    "${tree}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstcoreelements.so" \
    libgstcoreelements.so 62
image="$(pack_image x86-plugin "${tree}")"
expect_fail "RED x86_64 plugin" "wrong ELF machine" \
    python3 "${VERIFIER}" --gpu-model open --variant dev "${image}"

tree="${WORK}/truncated-plugin.root"
install -d "${tree}"
make_tree "${tree}"
printf '\177ELF\002\001\001' \
    > "${tree}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstcoreelements.so"
image="$(pack_image truncated-plugin "${tree}")"
expect_fail "RED truncated plugin ELF" "truncated ELF header" \
    python3 "${VERIFIER}" --gpu-model open --variant dev "${image}"

tree="${WORK}/text-plugin.root"
install -d "${tree}"
make_tree "${tree}"
printf 'plain text with the expected names is not a plugin: filesrc filesink\n' \
    > "${tree}/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstcoreelements.so"
image="$(pack_image text-plugin "${tree}")"
expect_fail "RED non-ELF text plugin" "not ELF" \
    python3 "${VERIFIER}" --gpu-model open --variant dev "${image}"

for command in "${commands[@]}"; do
    tree="${WORK}/x86-command-${command}.root"
    install -d "${tree}"
    make_tree "${tree}"
    make_elf "${tree}/usr/bin/${command}" 62 ""
    chmod 0755 "${tree}/usr/bin/${command}"
    image="$(pack_image "x86-command-${command}" "${tree}")"
    expect_fail "RED non-aarch64 command ${command}" "wrong ELF machine" \
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
