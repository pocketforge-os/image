#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"

# On any failure, print the failing command and the tail of every captured build
# stderr BEFORE the EXIT trap deletes ${scratch}. Before this, a bare `set -e`
# exit (e.g. an assertion grep failing because the fixture build died earlier)
# printed nothing at all (bd tsp-mc9m.41.984.30).
fail_line=""
fail_cmd=""
on_err() { fail_line="$1"; fail_cmd="$2"; }
trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR

cleanup() {
    local ec=$?
    if [ "${ec}" -ne 0 ]; then
        echo "FAIL: test-rootfs-fallback-profile.sh exited ${ec}" >&2
        [ -z "${fail_cmd}" ] || \
            echo "  failing command (line ${fail_line}): ${fail_cmd}" >&2
        for err_file in "${scratch}"/*.err; do
            [ -e "${err_file}" ] || continue
            echo "  --- $(basename "${err_file}") (stderr tail) ---" >&2
            tail -n 30 "${err_file}" >&2
        done
    fi
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

fixture_src="${scratch}/src"
fixture_board="${fixture_src}/boards/tsp"
fixture_bin="${scratch}/bin"
kernel_tree="${scratch}/kernel"
kernel_release=7.0.0-pocketforge
kernel_modules_root="${kernel_tree}/lib/modules"
kernel_release_dir="${kernel_modules_root}/${kernel_release}"
powervr_module="${kernel_release_dir}/kernel/drivers/gpu/drm/imagination/powervr.ko"

mkdir -p "${fixture_src}/scripts" "${fixture_board}/initrd" \
    "${fixture_board}/bootlogo" "${fixture_src}/tools/dragonsecboot" \
    "${fixture_src}/packages/pocketforge-open-gpu-stack/DEBIAN" \
    "${fixture_bin}" "${scratch}/out" "${scratch}/libsdl3" \
    "${scratch}/wpa" "${scratch}/runtime" "${scratch}/launcher" \
    "${scratch}/hwprobe" "${scratch}/gpu" \
    "${scratch}/mesa/usr/local/lib/gbm" \
    "${kernel_tree}/arch/arm64/boot/dts/sunxi" \
    "$(dirname "${powervr_module}")" \
    "${scratch}/blobs/sunxi/a133/boot-chain" \
    "${scratch}/blobs/sunxi/a133/wifi-firmware"

# Stage every script build-sd-image.sh (or anything it calls) might invoke by
# copying the real scripts/ directory wholesale, preserving each file's
# committed mode. A newly added helper (e.g. make-reproducible-vfat.sh,
# bd tsp-mc9m.41.984.20.1) is then staged automatically instead of needing a
# new hand-added line here every time build-sd-image.sh grows one
# (bd tsp-mc9m.41.984.30).
cp -a "${repo_dir}/scripts/." "${fixture_src}/scripts/"
for input in rootfs-packages.txt rootfs-packages-dev.txt rootfs-packages-mainline.txt rootfs-packages-mainline-dev.txt \
    rootfs-packages-a133-open-7x-gpu.txt \
    snapshot-date.txt; do
    install -m 0644 "${repo_dir}/${input}" "${fixture_src}/${input}"
done
install -m 0644 \
    "${repo_dir}/packages/pocketforge-open-gpu-stack/DEBIAN/control" \
    "${fixture_src}/packages/pocketforge-open-gpu-stack/DEBIAN/control"
for input in fs-uuids.env cmdline.txt cmdline-vendor-4.9.txt boot_package.cfg; do
    install -m 0644 "${repo_dir}/boards/tsp/${input}" "${fixture_board}/${input}"
done
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

cat > "${fixture_bin}/mkdosfs" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# make-reproducible-vfat.sh (bd tsp-mc9m.41.984.20.1, staged by the wholesale
# scripts/ copy above) formats via the faked no-op mkdosfs, then labels via a
# real mlabel -- against a file the fake dd/mkdosfs never actually formatted.
# Fake mlabel too, so this test keeps exercising preflight logic on a synthetic
# boot-resource image rather than real FAT bytes (that is
# tests/test-reproducible-assembly.py's job).
cat > "${fixture_bin}/mlabel" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${fixture_bin}/qemu-aarch64-static" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${fixture_bin}/abootimg" "${fixture_bin}/dd" \
    "${fixture_bin}/mkdosfs" "${fixture_bin}/mlabel" "${fixture_bin}/qemu-aarch64-static"

for input in libsdl3 wpa runtime launcher hwprobe gpu; do
    printf '%s fixture\n' "${input}" > "${scratch}/${input}/payload"
done
printf 'fixture SDL\n' > "${scratch}/libsdl3/libSDL3-pocketforge.so.0"
for library in libEGL_mesa.so.0 libGLX_mesa.so.0 libgbm.so; do
    printf '%s fixture\n' "${library}" > "${scratch}/mesa/usr/local/lib/${library}"
done
printf 'dri gbm fixture\n' > "${scratch}/mesa/usr/local/lib/gbm/dri_gbm.so"
printf 'provider fixture\n' > "${scratch}/mesa/pocketforge-open-gpu-stack.deb"
for firmware in fw_xr829.bin fw_xr829_bt.bin; do
    printf '%s fixture\n' "${firmware}" \
        > "${scratch}/blobs/sunxi/a133/wifi-firmware/${firmware}"
done

printf 'kernel image\n' > "${kernel_tree}/arch/arm64/boot/Image"
python3 "${repo_dir}/tests/helpers/make-cma-test-dtb.py" \
    --output "${kernel_tree}/arch/arm64/boot/dts/sunxi/pocketforge_tsp.dtb" \
    --default-cma
: > "${kernel_release_dir}/modules.builtin"
printf 'alias of:N*T*Cimg,img-rogue powervr\n' > "${kernel_release_dir}/modules.alias"
printf 'powervr fixture\n' > "${powervr_module}"
printf 'copy only from selected modules root\n' > "${kernel_release_dir}/module-root-marker"
for blob in u-boot.bin monitor.bin scp.bin boot0.img; do
    printf '%s fixture\n' "${blob}" > "${scratch}/blobs/sunxi/a133/boot-chain/${blob}"
done
python3 - "${scratch}/blobs/sunxi/a133/boot-chain/env.img" <<'PY'
from pathlib import Path
import struct
import sys
import zlib

records = [
    b"cma=64M",
    b"setargs_nand=setenv bootargs console=ttyS0 cma=${cma} rootwait",
    b"setargs_mmc=setenv bootargs console=ttyS0 cma=${cma} rootwait",
    b"bootcmd=run setargs_nand; run boot_normal",
]
payload = (b"\0".join(records) + b"\0\0").ljust(0x20000 - 5, b"\0")
Path(sys.argv[1]).write_bytes(
    struct.pack("<I", zlib.crc32(payload)) + b"\x01" + payload
)
PY

run_sd_fallback() {
    local label="$1"
    local device_id="${2:-a133-open-7x-gpu}"
    local status
    find "${scratch}/out" -mindepth 1 -delete
    set +e
    PATH="${fixture_bin}:${PATH}" \
    SRC_DIR="${fixture_src}" BLOBS_DIR="${scratch}/blobs" OUT_DIR="${scratch}/out" \
    LIBSDL3_DIR="${scratch}/libsdl3" GPU_UM_MESA_DIR="${scratch}/mesa" \
    WPA_DIR="${scratch}/wpa" RUNTIME_DIR="${scratch}/runtime" \
    LAUNCHER_DIR="${scratch}/launcher" HWPROBE_DIR="${scratch}/hwprobe" \
    KERNEL_TSP_DIR="${kernel_tree}" GPU_KM_TSP_DIR="${scratch}/gpu" \
    SOURCE_DATE_EPOCH=1700000000 PF_DEVICE_ID="${device_id}" \
    PF_KERNEL_REPO=kernel-sunxi-7.x \
    PF_GPU_MODEL=open PF_GPU_KM_MODEL=in-tree-7.x \
    PF_KERNEL_REQUIRED_MODULES=powervr PF_DISPLAY_PIPELINE=fbdev \
    bash "${repo_dir}/scripts/build-sd-image.sh" --variant release \
        > "${scratch}/${label}.out" 2> "${scratch}/${label}.err"
    status=$?
    set -e
    [ "${status}" -ne 0 ] || {
        echo "FAIL: fallback fixture ${label} unexpectedly completed a rootfs build" >&2
        exit 1
    }
}

# The real rootfs builder must discover the release below the full kernel tree's
# lib/modules subtree.  The deliberately absent owned WPA binary stops the build
# only after module and display-input preflight, avoiding a networked mmdebstrap.
run_sd_fallback modules-present
grep -F 'Building full Debian rootfs' "${scratch}/modules-present.out" >/dev/null
grep -F "kernel modules root: ${kernel_modules_root}" \
    "${scratch}/modules-present.out" >/dev/null
grep -F "required kernel module powervr (module): ${powervr_module}" \
    "${scratch}/modules-present.out" >/dev/null
grep -F "libsdl3: ${scratch}/libsdl3/libSDL3-pocketforge.so.0" \
    "${scratch}/modules-present.out" >/dev/null
grep -F 'owned wpa_supplicant not found' "${scratch}/modules-present.err" >/dev/null

# The diagnostic sibling must traverse the identical open/in-tree-7.x fallback
# contract while retaining its exact device ID.
run_sd_fallback modules-present-noradio a133-open-7x-gpu-noradio
grep -F "required kernel module powervr (module): ${powervr_module}" \
    "${scratch}/modules-present-noradio.out" >/dev/null
grep -F 'owned wpa_supplicant not found' \
    "${scratch}/modules-present-noradio.err" >/dev/null

# The CTS profile is a normal open-GPU release when the lock emits no CTS
# selector; it must reach the same preflight without staging test payloads.
run_sd_fallback modules-present-cts-release a133-open-7x-gpu-cts
grep -F "required kernel module powervr (module): ${powervr_module}" \
    "${scratch}/modules-present-cts-release.out" >/dev/null
grep -F 'owned wpa_supplicant not found' \
    "${scratch}/modules-present-cts-release.err" >/dev/null

# Missing required modules must fail in that same real preflight, before its
# later WPA sentinel.  This also prevents a fixture-only success path.
mv "${powervr_module}" "${scratch}/powervr.ko.saved"
run_sd_fallback modules-missing
grep -F "powervr.ko not found as a module under ${kernel_release_dir}" \
    "${scratch}/modules-missing.err" >/dev/null
if grep -Fq 'owned wpa_supplicant not found' "${scratch}/modules-missing.err"; then
    echo 'FAIL: missing powervr module reached a later rootfs prerequisite' >&2
    exit 1
fi
mv "${scratch}/powervr.ko.saved" "${powervr_module}"

# Execute the real customize-hook module block.  Its source tree must be the
# selected modules root, not either the full kernel tree or canonical hardcode.
# Take the block and the definitions it calls from the hook exactly as
# build-rootfs.sh generates it: the hook is its own process, so outer-script
# functions pasted in here would hide a call the hook cannot resolve
# (tsp-mc9m.41.986).
# shellcheck source=tests/lib/capture-customize-hook.sh
. "${repo_dir}/tests/lib/capture-customize-hook.sh"
generated_hook="${scratch}/generated-customize-hook.sh"
capture_customize_hook "${fixture_src}" "${scratch}/hook-capture" "${generated_hook}"
customize_modules="${scratch}/customize-modules.sh"
awk '{ print } /^install_open_gpu_module_options\(\) \{$/ { in_helper = 1 }
     in_helper && /^}$/ { exit }' "${generated_hook}" > "${customize_modules}"
[ "$(tail -n 1 "${customize_modules}")" = '}' ]
sed -n '/^# --- Kernel modules install/,/^# --- Firmware install/p' \
    "${generated_hook}" | sed '$d' >> "${customize_modules}"
grep -Fx 'install_open_gpu_module_options' "${customize_modules}" >/dev/null
cat > "${fixture_bin}/chroot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
rootfs="$1"
shift
[ "$1" = depmod ]
release="$2"
printf 'kernel/drivers/gpu/drm/imagination/powervr.ko:\n' \
    > "${rootfs}/lib/modules/${release}/modules.dep"
EOF
chmod 0755 "${fixture_bin}/chroot"

customize_root="${scratch}/customize-root"
mkdir -p "${customize_root}"
PATH="${fixture_bin}:${PATH}" \
PF_DEVICE_ID=a133-open-7x-gpu PF_GPU_MODEL=open PF_GPU_KM_MODEL=in-tree-7.x \
KERNEL_MODULES_ROOT="${kernel_modules_root}" \
bash "${customize_modules}" "${customize_root}" \
    > "${scratch}/customize.out" 2> "${scratch}/customize.err"
test -f "${customize_root}/lib/modules/${kernel_release}/module-root-marker"
test -f "${customize_root}/lib/modules/${kernel_release}/kernel/drivers/gpu/drm/imagination/powervr.ko"
test -s "${customize_root}/lib/modules/${kernel_release}/modules.dep"
[ "$(cat "${customize_root}/etc/modprobe.d/powervr-a133-open-7x-gpu.conf")" = \
    'options powervr exp_hw_support=1' ]

customize_noradio_root="${scratch}/customize-noradio-root"
mkdir -p "${customize_noradio_root}"
PATH="${fixture_bin}:${PATH}" \
PF_DEVICE_ID=a133-open-7x-gpu-noradio PF_GPU_MODEL=open PF_GPU_KM_MODEL=in-tree-7.x \
KERNEL_MODULES_ROOT="${kernel_modules_root}" \
bash "${customize_modules}" "${customize_noradio_root}" \
    > "${scratch}/customize-noradio.out" 2> "${scratch}/customize-noradio.err"
[ "$(cat "${customize_noradio_root}/etc/modprobe.d/powervr-a133-open-7x-gpu.conf")" = \
    'options powervr exp_hw_support=1' ]
grep -F 'KERNEL_MODULES_ROOT=${KERNEL_MODULES_ROOT}' \
    "${fixture_src}/scripts/build-rootfs.sh" >/dev/null

echo 'rootfs-fallback-profile=PASS'
