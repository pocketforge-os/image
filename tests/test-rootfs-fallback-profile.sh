#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'find "${scratch}" -mindepth 1 -delete; rmdir "${scratch}"' EXIT

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
    "${fixture_bin}" "${scratch}/out" "${scratch}/libsdl3" \
    "${scratch}/wpa" "${scratch}/runtime" "${scratch}/launcher" \
    "${scratch}/hwprobe" "${scratch}/gpu" \
    "${scratch}/mesa/usr/local/lib/gbm" \
    "${kernel_tree}/arch/arm64/boot/dts/sunxi" \
    "$(dirname "${powervr_module}")" \
    "${scratch}/blobs/sunxi/a133/boot-chain" \
    "${scratch}/blobs/sunxi/a133/wifi-firmware"

install -m 0755 "${repo_dir}/scripts/build-rootfs-direct.sh" \
    "${fixture_src}/scripts/build-rootfs-direct.sh"
install -m 0755 "${repo_dir}/scripts/build-rootfs.sh" \
    "${fixture_src}/scripts/build-rootfs.sh"
install -m 0644 "${repo_dir}/scripts/kernel-module-form.sh" \
    "${fixture_src}/scripts/kernel-module-form.sh"
for input in rootfs-packages.txt rootfs-packages-dev.txt rootfs-packages-mainline.txt rootfs-packages-mainline-dev.txt \
    snapshot-date.txt; do
    install -m 0644 "${repo_dir}/${input}" "${fixture_src}/${input}"
done
for input in fs-uuids.env cmdline.txt boot_package.cfg; do
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

cat > "${fixture_bin}/qemu-aarch64-static" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${fixture_bin}/abootimg" "${fixture_bin}/dd" \
    "${fixture_bin}/mkdosfs" "${fixture_bin}/qemu-aarch64-static"

for input in libsdl3 wpa runtime launcher hwprobe gpu; do
    printf '%s fixture\n' "${input}" > "${scratch}/${input}/payload"
done
printf 'fixture SDL\n' > "${scratch}/libsdl3/libSDL3-pocketforge.so.0"
for library in libEGL.so libGLESv2.so libgbm.so; do
    printf '%s fixture\n' "${library}" > "${scratch}/mesa/usr/local/lib/${library}"
done
printf 'dri gbm fixture\n' > "${scratch}/mesa/usr/local/lib/gbm/dri_gbm.so"
for firmware in fw_xr829.bin fw_xr829_bt.bin; do
    printf '%s fixture\n' "${firmware}" \
        > "${scratch}/blobs/sunxi/a133/wifi-firmware/${firmware}"
done

printf 'kernel image\n' > "${kernel_tree}/arch/arm64/boot/Image"
printf 'kernel dtb\n' > "${kernel_tree}/arch/arm64/boot/dts/sunxi/pocketforge_tsp.dtb"
: > "${kernel_release_dir}/modules.builtin"
printf 'alias of:N*T*Cimg,img-rogue powervr\n' > "${kernel_release_dir}/modules.alias"
printf 'powervr fixture\n' > "${powervr_module}"
printf 'copy only from selected modules root\n' > "${kernel_release_dir}/module-root-marker"
for blob in u-boot.bin monitor.bin scp.bin boot0.img env.img; do
    printf '%s fixture\n' "${blob}" > "${scratch}/blobs/sunxi/a133/boot-chain/${blob}"
done

run_sd_fallback() {
    local label="$1"
    local status
    find "${scratch}/out" -mindepth 1 -delete
    set +e
    PATH="${fixture_bin}:${PATH}" \
    SRC_DIR="${fixture_src}" BLOBS_DIR="${scratch}/blobs" OUT_DIR="${scratch}/out" \
    LIBSDL3_DIR="${scratch}/libsdl3" GPU_UM_MESA_DIR="${scratch}/mesa" \
    WPA_DIR="${scratch}/wpa" RUNTIME_DIR="${scratch}/runtime" \
    LAUNCHER_DIR="${scratch}/launcher" HWPROBE_DIR="${scratch}/hwprobe" \
    KERNEL_TSP_DIR="${kernel_tree}" GPU_KM_TSP_DIR="${scratch}/gpu" \
    SOURCE_DATE_EPOCH=1700000000 PF_DEVICE_ID=a133-open-7x-gpu \
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
customize_modules="${scratch}/customize-modules.sh"
sed -n '/^install_open_gpu_module_options() {$/,/^}$/p' \
    "${fixture_src}/scripts/build-rootfs.sh" > "${customize_modules}"
sed -n '/^# --- Kernel modules install/,/^# --- Firmware install/p' \
    "${fixture_src}/scripts/build-rootfs.sh" | sed '$d' >> "${customize_modules}"
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
PATH="${fixture_bin}:${PATH}" ROOTFS="${customize_root}" \
PF_DEVICE_ID=a133-open-7x-gpu PF_GPU_MODEL=open PF_GPU_KM_MODEL=in-tree-7.x \
KERNEL_MODULES_ROOT="${kernel_modules_root}" \
bash "${customize_modules}" > "${scratch}/customize.out" 2> "${scratch}/customize.err"
test -f "${customize_root}/lib/modules/${kernel_release}/module-root-marker"
test -f "${customize_root}/lib/modules/${kernel_release}/kernel/drivers/gpu/drm/imagination/powervr.ko"
test -s "${customize_root}/lib/modules/${kernel_release}/modules.dep"
[ "$(cat "${customize_root}/etc/modprobe.d/powervr-a133-open-7x-gpu.conf")" = \
    'options powervr exp_hw_support=1' ]
grep -F 'KERNEL_MODULES_ROOT=${KERNEL_MODULES_ROOT}' \
    "${fixture_src}/scripts/build-rootfs.sh" >/dev/null

echo 'rootfs-fallback-profile=PASS'
