#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

for input in src blobs libsdl3 wpa runtime launcher kernel gpu; do
    mkdir -p "${scratch}/${input}"
    printf '%s input\n' "${input}" > "${scratch}/${input}/payload"
done
cp "${repo_dir}/scripts/generate-build-id.sh" "${scratch}/src/generate-build-id.sh"
mkdir -p "${scratch}/out"
printf 'owned U-Boot input A\n' > "${scratch}/u-boot.bin"
[ ! -e "${scratch}/out/userdata.ext4" ] || { echo "FAIL: userdata fixture unexpectedly exists" >&2; exit 1; }

fake_builder="${scratch}/fake-build-rootfs.sh"
cat > "${fake_builder}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"${SRC_DIR}/generate-build-id.sh" > "${OUT_DIR}/build-id"
printf 'rootfs\n' > "${OUT_DIR}/userdata.ext4"
EOF
chmod +x "${fake_builder}"

run_direct() {
    local uboot_spl="${1:-}"
    SRC_DIR="${scratch}/src" BLOBS_DIR="${scratch}/blobs" \
    LIBSDL3_DIR="${scratch}/libsdl3" WPA_DIR="${scratch}/wpa" \
    RUNTIME_DIR="${scratch}/runtime" LAUNCHER_DIR="${scratch}/launcher" KERNEL_TSP_DIR="${scratch}/kernel" \
    GPU_KM_TSP_DIR="${scratch}/gpu" OUT_DIR="${scratch}/out" \
    ROOTFS_BUILDER="${fake_builder}" SOURCE_DATE_EPOCH=1700000000 \
    bash "${repo_dir}/scripts/build-rootfs-direct.sh" \
        --variant dev --uboot-spl "${uboot_spl}"
    cat "${scratch}/out/build-id"
}

first="$(run_direct "${scratch}/u-boot.bin")"
rm "${scratch}/out/userdata.ext4"
# Mutable checkout metadata is not a build input and must not perturb identity.
mkdir -p "${scratch}/src/.git"
printf 'ephemeral checkout state\n' > "${scratch}/src/.git/state"
second="$(run_direct "${scratch}/u-boot.bin")"
[ "${first}" = "${second}" ] || { echo "FAIL: identical direct inputs differed" >&2; exit 1; }

printf 'changed kernel input\n' >> "${scratch}/kernel/payload"
rm "${scratch}/out/userdata.ext4"
different="$(run_direct "${scratch}/u-boot.bin")"
[ "${first}" != "${different}" ] || { echo "FAIL: changed direct input matched" >&2; exit 1; }

# Restore the kernel input, then prove the separately selected owned bootchain is
# part of the identity even though it is outside every staged source tree.
sed -i '$d' "${scratch}/kernel/payload"
printf 'owned U-Boot input B\n' > "${scratch}/u-boot.bin"
rm "${scratch}/out/userdata.ext4"
different_uboot="$(run_direct "${scratch}/u-boot.bin")"
[ "${first}" != "${different_uboot}" ] || { echo "FAIL: changed owned U-Boot input matched" >&2; exit 1; }

rm "${scratch}/out/userdata.ext4"
vendor="$(run_direct "")"
[ "${first}" != "${vendor}" ] || { echo "FAIL: owned and explicit vendor bootchain identities matched" >&2; exit 1; }

case "${first}" in
    'device=trimui-smart-pro-a133 build='????????????) ;;
    *) echo "FAIL: direct build-id is not a single cat-readable line: ${first}" >&2; exit 1 ;;
esac

printf 'PASS direct-absent-userdata identical=%s\nPASS changed-kernel=%s\nPASS changed-owned-uboot=%s\nPASS explicit-vendor=%s\n' \
    "${first}" "${different}" "${different_uboot}" "${vendor}"
