#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

fixture_src="${scratch}/src"
fixture_board="${fixture_src}/boards/tsp"
fixture_bin="${scratch}/bin"
mkdir -p "${fixture_src}/scripts" "${fixture_board}/initrd" \
    "${fixture_board}/bootlogo" "${fixture_src}/tools/dragonsecboot" \
    "${fixture_bin}" "${scratch}/out" "${scratch}/libsdl3" \
    "${scratch}/wpa" "${scratch}/runtime" "${scratch}/launcher" \
    "${scratch}/hwprobe" "${scratch}/gpu" \
    "${scratch}/kernel/arch/arm64/boot/dts/sunxi" \
    "${scratch}/blobs/sunxi/a133/boot-chain"

install -m 0755 "${repo_dir}/scripts/build-rootfs-direct.sh" \
    "${fixture_src}/scripts/build-rootfs-direct.sh"
install -m 0755 "${repo_dir}/scripts/build-rootfs.sh" \
    "${fixture_src}/scripts/build-rootfs.sh"
install -m 0644 "${repo_dir}/boards/tsp/fs-uuids.env" \
    "${fixture_board}/fs-uuids.env"
install -m 0644 "${repo_dir}/boards/tsp/cmdline.txt" \
    "${fixture_board}/cmdline.txt"
install -m 0644 "${repo_dir}/boards/tsp/boot_package.cfg" \
    "${fixture_board}/boot_package.cfg"
printf 'fixture boot logo\n' > "${fixture_board}/bootlogo/bootlogo.bmp.lzma"

cat > "${fixture_board}/initrd/build-initrd.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
: "${out:?missing --out}"
printf 'fixture initrd\n' > "${out}"
EOF
chmod 0755 "${fixture_board}/initrd/build-initrd.sh"

cat > "${fixture_src}/tools/dragonsecboot/dragonsecboot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fixture boot package\n' > boot_package.fex
EOF
chmod 0755 "${fixture_src}/tools/dragonsecboot/dragonsecboot"

cat > "${fixture_bin}/abootimg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
    if [ "$1" = --create ]; then
        out="$2"
        break
    fi
    shift
done
: "${out:?missing --create output}"
printf 'ANDROID!' > "${out}"
EOF
chmod 0755 "${fixture_bin}/abootimg"

cat > "${fixture_bin}/dd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
for arg in "$@"; do
    case "${arg}" in
        of=*) out="${arg#of=}" ;;
    esac
done
[ -n "${out}" ] || exit 1
: > "${out}"
EOF
chmod 0755 "${fixture_bin}/dd"

cat > "${fixture_bin}/mkdosfs" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${fixture_bin}/mkdosfs"

for input in libsdl3 wpa runtime launcher hwprobe gpu; do
    printf '%s fixture\n' "${input}" > "${scratch}/${input}/payload"
done
printf 'kernel image\n' > "${scratch}/kernel/arch/arm64/boot/Image"
printf 'kernel dtb\n' > "${scratch}/kernel/arch/arm64/boot/dts/sunxi/pocketforge_tsp.dtb"
for blob in u-boot.bin monitor.bin scp.bin boot0.img env.img; do
    printf '%s fixture\n' "${blob}" > "${scratch}/blobs/sunxi/a133/boot-chain/${blob}"
done

fake_rootfs_builder="${scratch}/fake-build-rootfs.sh"
cat > "${fake_rootfs_builder}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${PF_DEVICE_ID}" = a133-open-7x-gpu ]
[ "${PF_GPU_MODEL}" = open ]
[ "${PF_GPU_KM_MODEL}" = in-tree-7.x ]
[ "${PF_KERNEL_REQUIRED_MODULES}" = powervr ]
[ "${PF_DISPLAY_PIPELINE}" = fbdev ]

helper="${FALLBACK_CAPTURE}.helper"
sed -n '/^install_open_gpu_module_options() {$/,/^}$/p' \
    "${SRC_DIR}/scripts/build-rootfs.sh" > "${helper}"
mkdir -p "${FALLBACK_ROOT}"
ROOTFS="${FALLBACK_ROOT}" bash -c \
    'source "$1"; install_open_gpu_module_options' _ "${helper}"
option_file="${FALLBACK_ROOT}/etc/modprobe.d/powervr-a133-open-7x-gpu.conf"
[ "$(cat "${option_file}")" = 'options powervr exp_hw_support=1' ]
printf 'device=%s\ngpu=%s\nkm=%s\nmodules=%s\ndisplay=%s\n' \
    "${PF_DEVICE_ID}" "${PF_GPU_MODEL}" "${PF_GPU_KM_MODEL}" \
    "${PF_KERNEL_REQUIRED_MODULES}" "${PF_DISPLAY_PIPELINE}" \
    > "${FALLBACK_CAPTURE}"
exit 93
EOF
chmod 0755 "${fake_rootfs_builder}"

set +e
PATH="${fixture_bin}:${PATH}" \
SRC_DIR="${fixture_src}" BLOBS_DIR="${scratch}/blobs" OUT_DIR="${scratch}/out" \
LIBSDL3_DIR="${scratch}/libsdl3" WPA_DIR="${scratch}/wpa" \
RUNTIME_DIR="${scratch}/runtime" LAUNCHER_DIR="${scratch}/launcher" \
HWPROBE_DIR="${scratch}/hwprobe" KERNEL_TSP_DIR="${scratch}/kernel" \
GPU_KM_TSP_DIR="${scratch}/gpu" ROOTFS_BUILDER="${fake_rootfs_builder}" \
FALLBACK_CAPTURE="${scratch}/fallback-facts" FALLBACK_ROOT="${scratch}/fallback-root" \
SOURCE_DATE_EPOCH=1700000000 PF_DEVICE_ID=a133-open-7x-gpu \
PF_GPU_MODEL=open PF_GPU_KM_MODEL=in-tree-7.x \
PF_KERNEL_REQUIRED_MODULES=powervr PF_DISPLAY_PIPELINE=fbdev \
bash "${repo_dir}/scripts/build-sd-image.sh" --variant release \
    > "${scratch}/fallback.out" 2> "${scratch}/fallback.err"
status=$?
set -e

[ "${status}" -eq 93 ] || {
    echo "FAIL: SD fallback did not reach the direct rootfs builder (status=${status})" >&2
    cat "${scratch}/fallback.err" >&2
    exit 1
}
[ "$(cat "${scratch}/fallback-facts")" = $'device=a133-open-7x-gpu\ngpu=open\nkm=in-tree-7.x\nmodules=powervr\ndisplay=fbdev' ]
[ "$(cat "${scratch}/fallback-root/etc/modprobe.d/powervr-a133-open-7x-gpu.conf")" = \
    'options powervr exp_hw_support=1' ]
grep -F 'Building full Debian rootfs' "${scratch}/fallback.out" >/dev/null

echo 'rootfs-fallback-profile=PASS'
