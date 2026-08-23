#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

for input in src blobs libsdl3 wpa runtime kernel gpu; do
    mkdir -p "${scratch}/${input}"
    printf '%s input\n' "${input}" > "${scratch}/${input}/payload"
done
cp "${repo_dir}/scripts/generate-build-id.sh" "${scratch}/src/generate-build-id.sh"
mkdir -p "${scratch}/out"
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
    SRC_DIR="${scratch}/src" BLOBS_DIR="${scratch}/blobs" \
    LIBSDL3_DIR="${scratch}/libsdl3" WPA_DIR="${scratch}/wpa" \
    RUNTIME_DIR="${scratch}/runtime" KERNEL_TSP_DIR="${scratch}/kernel" \
    GPU_KM_TSP_DIR="${scratch}/gpu" OUT_DIR="${scratch}/out" \
    ROOTFS_BUILDER="${fake_builder}" SOURCE_DATE_EPOCH=1700000000 \
    bash "${repo_dir}/scripts/build-rootfs-direct.sh" --variant dev
    cat "${scratch}/out/build-id"
}

first="$(run_direct)"
rm "${scratch}/out/userdata.ext4"
# Mutable checkout metadata is not a build input and must not perturb identity.
mkdir -p "${scratch}/src/.git"
printf 'ephemeral checkout state\n' > "${scratch}/src/.git/state"
second="$(run_direct)"
[ "${first}" = "${second}" ] || { echo "FAIL: identical direct inputs differed" >&2; exit 1; }

printf 'changed kernel input\n' >> "${scratch}/kernel/payload"
rm "${scratch}/out/userdata.ext4"
different="$(run_direct)"
[ "${first}" != "${different}" ] || { echo "FAIL: changed direct input matched" >&2; exit 1; }

case "${first}" in
    'device=trimui-smart-pro-a133 build='????????????) ;;
    *) echo "FAIL: direct build-id is not a single cat-readable line: ${first}" >&2; exit 1 ;;
esac

printf 'PASS direct-absent-userdata identical=%s\nPASS changed-kernel=%s\n' "${first}" "${different}"
