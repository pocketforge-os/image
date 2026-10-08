#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
verifier="$root/scripts/verify-open-gpu-tools.sh"
provider_control="$root/packages/pocketforge-open-gpu-stack/DEBIAN/control"
builder="$root/scripts/build-rootfs.sh"
artifact_policy="$root/scripts/verify-no-gpu-artifacts.sh"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/open-gpu-tools.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT

test -x "$verifier"
test -x "$artifact_policy"
test -f "$provider_control"

grep -Fx 'Package: pocketforge-open-gpu-stack' "$provider_control" >/dev/null
grep -Fx 'Provides: libegl-mesa0, libegl-vendor, libglx-mesa0, libglx-vendor' \
    "$provider_control" >/dev/null
for package in libegl-mesa0 libgl1-mesa-dri libglx-mesa0 mesa-vulkan-drivers; do
    sed -n 's/^Conflicts: //p' "$provider_control" | tr ', ' '\n' | \
        grep -Fx "$package" >/dev/null
done

grep -Fq 'rootfs-packages-a133-open-7x-gpu.txt' "$builder"
grep -Fq 'pocketforge-open-gpu-stack.deb' "$builder"
test "$(grep -Fc 'scripts/verify-open-gpu-tools.sh' "$builder")" -eq 2

producer="$scratch/producer"
positive="$scratch/positive"
mkdir -p \
    "$producer/usr/local/lib/dri" \
    "$producer/usr/local/share/vulkan/icd.d" \
    "$positive/usr/local/lib/dri" \
    "$positive/usr/local/share/vulkan/icd.d" \
    "$positive/usr/share/pocketforge" \
    "$positive/usr/share/vulkan/icd.d" \
    "$positive/usr/bin" \
    "$positive/var/lib/dpkg"

for artifact in \
    libEGL.so.1.0.0 \
    libGLESv2.so.2.0.0 \
    libgbm.so.1.0.0 \
    libgallium_dri.so \
    libvulkan_powervr_mesa.so; do
    printf 'owned gpu-um-tsp artifact: %s\n' "$artifact" \
        >"$producer/usr/local/lib/$artifact"
done
printf '%s\n' 'owned gpu-um-tsp libdril megadriver' \
    >"$producer/usr/local/lib/dri/libdril_dri.so"
ln -s libdril_dri.so "$producer/usr/local/lib/dri/ili9225_dri.so"
ln -s libdril_dri.so "$producer/usr/local/lib/dri/zink_dri.so"
printf '%s\n' '{"ICD":{"library_path":"/usr/local/lib/libvulkan_powervr_mesa.so"}}' \
    >"$producer/usr/local/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"
printf '%s\n' 'gpu-um-tsp@977370a239cfe5d8e06aea7fb0e475bd0da58738 (open Mesa GLES/EGL/GBM/Vulkan userspace, GE8300 Zink)' \
    >"$producer/.pf-gpu-um-provenance"
cp -a "$producer/usr/local/." "$positive/usr/local/"
cp "$producer/usr/local/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json" \
    "$positive/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"
cp "$producer/.pf-gpu-um-provenance" \
    "$positive/usr/share/pocketforge/gpu-um-mesa-provenance"

cat >"$positive/var/lib/dpkg/status" <<'EOF'
Package: pocketforge-open-gpu-stack
Status: install ok installed
Architecture: all
Version: 1
Description: test provider
EOF

for binary in \
    glmark2-es2-drm \
    glmark2-es2-wayland \
    glmark2-es2 \
    eglinfo \
    es2gears_wayland \
    es2gears_x11 \
    kmscube \
    vkcube \
    vkcube-wayland \
    vulkaninfo; do
    case "$binary" in
        glmark2-es2-wayland|glmark2-es2)
            printf '#!/bin/sh\n# runtime GPU ABI: libEGL.so.1 libGLESv2.so.2\nexit 0\n' \
                >"$positive/usr/bin/$binary"
            ;;
        vulkaninfo)
            printf '#!/bin/sh\n# runtime Vulkan ABI: libvulkan.so.1\nexit 0\n' \
                >"$positive/usr/bin/$binary"
            ;;
        *)
            printf '#!/bin/sh\nexit 0\n' >"$positive/usr/bin/$binary"
            ;;
    esac
    chmod 0755 "$positive/usr/bin/$binary"
done

ldd_stub="$scratch/ldd-stub"
cat >"$ldd_stub" <<'EOF'
#!/bin/sh
set -eu
rootfs=$1
binary=$2
test -x "$rootfs$binary"
cat <<'OUTPUT'
libc.so.6 => /lib/aarch64-linux-gnu/libc.so.6 (0x00000000)
OUTPUT
emit_owned_gles() {
    if [ "${PF_TEST_OMIT_GLES:-0}" != 1 ]; then
        echo 'libGLESv2.so.2 => /usr/local/lib/libGLESv2.so.2 (0x00000000)'
    fi
}
case "$binary" in
    /usr/bin/glmark2-es2-drm)
        case "${PF_TEST_DRM_BINDING:-gbm}" in
            egl) echo 'libEGL.so.1 => /usr/local/lib/libEGL.so.1 (0x00000000)' ;;
            gles) emit_owned_gles ;;
            gbm) echo 'libgbm.so.1 => /usr/local/lib/libgbm.so.1 (0x00000000)' ;;
        esac
        ;;
    /usr/bin/eglinfo)
        echo 'libEGL.so.1 => /usr/local/lib/libEGL.so.1 (0x00000000)'
        emit_owned_gles
        ;;
    /usr/bin/es2gears_wayland|/usr/bin/es2gears_x11|/usr/bin/kmscube)
        echo 'libEGL.so.1 => /usr/local/lib/libEGL.so.1 (0x00000000)'
        emit_owned_gles
        echo 'libgbm.so.1 => /usr/local/lib/libgbm.so.1 (0x00000000)'
        ;;
    /usr/bin/vkcube|/usr/bin/vkcube-wayland)
        echo 'libvulkan.so.1 => /usr/lib/aarch64-linux-gnu/libvulkan.so.1 (0x00000000)'
        ;;
esac
EOF
chmod 0755 "$ldd_stub"

positive_output=$(PF_ROOTFS_LDD="$ldd_stub" "$verifier" "$positive" "$producer")
printf '%s\n' "$positive_output"
printf '%s\n' "$positive_output" | grep -Fq 'open-gpu-tools=PASS'
printf '%s\n' "$positive_output" | \
    grep -Fq 'open-gpu-stack dri-artifacts=PASS boundary=/usr/local/lib/dri producer_entries=3'
printf '%s\n' "$positive_output" | \
    grep -Fq 'binary=/usr/bin/glmark2-es2-wayland binding_mode=runtime-owned-egl-gles'
printf '%s\n' "$positive_output" | \
    grep -Fq 'binary=/usr/bin/glmark2-es2 binding_mode=runtime-owned-egl-gles'
printf '%s\n' "$positive_output" | \
    grep -Fq 'binary=/usr/bin/vulkaninfo binding_mode=runtime-vulkan-loader'

for wrong_drm_binding in egl gles; do
    if PF_TEST_DRM_BINDING="$wrong_drm_binding" PF_ROOTFS_LDD="$ldd_stub" \
        "$verifier" "$positive" "$producer" \
        >"$scratch/negative-drm-${wrong_drm_binding}.out" \
        2>"$scratch/negative-drm-${wrong_drm_binding}.err"; then
        echo "FAIL: DRM glmark2 ${wrong_drm_binding}-only negative control was accepted" >&2
        exit 1
    fi
    grep -Fq '/usr/bin/glmark2-es2-drm has no dynamic binding to gpu-um-tsp GBM' \
        "$scratch/negative-drm-${wrong_drm_binding}.err"
done

if PF_TEST_OMIT_GLES=1 PF_ROOTFS_LDD="$ldd_stub" \
    "$verifier" "$positive" "$producer" \
    >"$scratch/negative-runtime-witness.out" \
    2>"$scratch/negative-runtime-witness.err"; then
    echo 'FAIL: missing same-rootfs GLES witness negative control was accepted' >&2
    exit 1
fi
grep -Fq '/usr/bin/glmark2-es2-wayland has no same-rootfs owned EGL/GLES resolution witness' \
    "$scratch/negative-runtime-witness.err"

negative_runtime_glmark_egl="$scratch/negative-runtime-glmark-egl"
cp -a "$positive" "$negative_runtime_glmark_egl"
printf '#!/bin/sh\n# incomplete runtime GPU ABI: libGLESv2.so.2\nexit 0\n' \
    >"$negative_runtime_glmark_egl/usr/bin/glmark2-es2-wayland"
chmod 0755 "$negative_runtime_glmark_egl/usr/bin/glmark2-es2-wayland"
if PF_ROOTFS_LDD="$ldd_stub" "$verifier" \
    "$negative_runtime_glmark_egl" "$producer" \
    >"$scratch/negative-runtime-glmark-egl.out" \
    2>"$scratch/negative-runtime-glmark-egl.err"; then
    echo 'FAIL: glmark2 missing-EGL runtime identity negative control was accepted' >&2
    exit 1
fi
grep -Fq '/usr/bin/glmark2-es2-wayland does not declare runtime loading of libEGL.so.1' \
    "$scratch/negative-runtime-glmark-egl.err"

negative_runtime_glmark_gles="$scratch/negative-runtime-glmark-gles"
cp -a "$positive" "$negative_runtime_glmark_gles"
printf '#!/bin/sh\n# incomplete runtime GPU ABI: libEGL.so.1\nexit 0\n' \
    >"$negative_runtime_glmark_gles/usr/bin/glmark2-es2-wayland"
chmod 0755 "$negative_runtime_glmark_gles/usr/bin/glmark2-es2-wayland"
if PF_ROOTFS_LDD="$ldd_stub" "$verifier" \
    "$negative_runtime_glmark_gles" "$producer" \
    >"$scratch/negative-runtime-glmark-gles.out" \
    2>"$scratch/negative-runtime-glmark-gles.err"; then
    echo 'FAIL: glmark2 missing-GLES runtime identity negative control was accepted' >&2
    exit 1
fi
grep -Fq '/usr/bin/glmark2-es2-wayland does not declare runtime loading of libGLESv2.so.2' \
    "$scratch/negative-runtime-glmark-gles.err"

negative_runtime_vulkaninfo="$scratch/negative-runtime-vulkaninfo"
cp -a "$positive" "$negative_runtime_vulkaninfo"
printf '#!/bin/sh\nexit 0\n' \
    >"$negative_runtime_vulkaninfo/usr/bin/vulkaninfo"
chmod 0755 "$negative_runtime_vulkaninfo/usr/bin/vulkaninfo"
if PF_ROOTFS_LDD="$ldd_stub" "$verifier" \
    "$negative_runtime_vulkaninfo" "$producer" \
    >"$scratch/negative-runtime-vulkaninfo.out" \
    2>"$scratch/negative-runtime-vulkaninfo.err"; then
    echo 'FAIL: vulkaninfo runtime-loader identity negative control was accepted' >&2
    exit 1
fi
grep -Fq '/usr/bin/vulkaninfo does not declare runtime loading of libvulkan.so.1' \
    "$scratch/negative-runtime-vulkaninfo.err"

# Negative control in this same test invocation: install an actual synthetic
# mesa-vulkan-drivers package into a copy of the passing dpkg root, overriding
# the provider conflict solely to prove that the tripwire rejects installed
# package state rather than an error or a partial read.
negative_package_root="$scratch/mesa-vulkan-drivers-package"
negative_root="$scratch/negative-package-rootfs"
mkdir -p "$negative_package_root/DEBIAN"
chmod 0755 "$negative_package_root/DEBIAN"
cat >"$negative_package_root/DEBIAN/control" <<'EOF'
Package: mesa-vulkan-drivers
Version: 22.3.6-test
Architecture: all
Maintainer: PocketForge test <test@pocketforge.invalid>
Description: synthetic forbidden package for the negative control
EOF
dpkg-deb --build --root-owner-group "$negative_package_root" \
    "$scratch/mesa-vulkan-drivers.deb" >/dev/null
cp -a "$positive" "$negative_root"
mkdir -p "$negative_root/var/lib/dpkg/updates" "$negative_root/var/log"
if ! dpkg --force-not-root --force-conflicts --root="$negative_root" \
    --install "$scratch/mesa-vulkan-drivers.deb" >"$scratch/dpkg-install.out" 2>&1; then
    cat "$scratch/dpkg-install.out" >&2
    echo 'FAIL: could not install the synthetic mesa-vulkan-drivers negative control' >&2
    exit 1
fi
grep -A3 -Fx 'Package: mesa-vulkan-drivers' \
    "$negative_root/var/lib/dpkg/status" | grep -Fx 'Status: install ok installed' >/dev/null
if PF_ROOTFS_LDD="$ldd_stub" "$verifier" "$negative_root" "$producer" \
    >"$scratch/negative-package.out" 2>"$scratch/negative-package.err"; then
    echo 'FAIL: installed mesa-vulkan-drivers negative control was accepted' >&2
    exit 1
fi
grep -Fq 'forbidden Debian Mesa driver package is installed: mesa-vulkan-drivers' \
    "$scratch/negative-package.err"

negative_hash="$scratch/negative-hash-rootfs"
cp -a "$positive" "$negative_hash"
printf '%s\n' 'tampered Debian replacement' \
    >"$negative_hash/usr/local/lib/libEGL.so.1.0.0"
if PF_ROOTFS_LDD="$ldd_stub" "$verifier" "$negative_hash" "$producer" \
    >"$scratch/negative-hash.out" 2>"$scratch/negative-hash.err"; then
    echo 'FAIL: changed gpu-um-tsp library hash was accepted' >&2
    exit 1
fi
grep -Fq 'gpu-um-tsp artifact hash mismatch: usr/local/lib/libEGL.so.1.0.0' \
    "$scratch/negative-hash.err"

negative_provenance_hash="$scratch/negative-provenance-hash"
cp -a "$positive" "$negative_provenance_hash"
printf '%s\n' 'changed provenance' >> \
    "$negative_provenance_hash/usr/share/pocketforge/gpu-um-mesa-provenance"
if PF_ROOTFS_LDD="$ldd_stub" "$verifier" "$negative_provenance_hash" "$producer" \
    >"$scratch/negative-provenance-hash.out" 2>"$scratch/negative-provenance-hash.err"; then
    echo 'FAIL: changed gpu-um-tsp provenance negative control was accepted' >&2
    exit 1
fi
grep -Fq 'gpu-um-tsp provenance hash mismatch:' \
    "$scratch/negative-provenance-hash.err"

negative_provenance_missing="$scratch/negative-provenance-missing"
cp -a "$positive" "$negative_provenance_missing"
rm "$negative_provenance_missing/usr/share/pocketforge/gpu-um-mesa-provenance"
if PF_ROOTFS_LDD="$ldd_stub" "$verifier" "$negative_provenance_missing" "$producer" \
    >"$scratch/negative-provenance-missing.out" 2>"$scratch/negative-provenance-missing.err"; then
    echo 'FAIL: missing rootfs gpu-um-tsp provenance negative control was accepted' >&2
    exit 1
fi
grep -Fq 'rootfs gpu-um-tsp provenance is missing or not a regular file' \
    "$scratch/negative-provenance-missing.err"

negative_provenance_link="$scratch/negative-provenance-link"
cp -a "$positive" "$negative_provenance_link"
rm "$negative_provenance_link/usr/share/pocketforge/gpu-um-mesa-provenance"
ln -s ../../local/lib/libgallium_dri.so \
    "$negative_provenance_link/usr/share/pocketforge/gpu-um-mesa-provenance"
if PF_ROOTFS_LDD="$ldd_stub" "$verifier" "$negative_provenance_link" "$producer" \
    >"$scratch/negative-provenance-link.out" 2>"$scratch/negative-provenance-link.err"; then
    echo 'FAIL: symlinked rootfs gpu-um-tsp provenance negative control was accepted' >&2
    exit 1
fi
grep -Fq 'rootfs gpu-um-tsp provenance is missing or not a regular file' \
    "$scratch/negative-provenance-link.err"

negative_producer_missing="$scratch/negative-producer-missing"
cp -a "$producer" "$negative_producer_missing"
rm "$negative_producer_missing/.pf-gpu-um-provenance"
if PF_ROOTFS_LDD="$ldd_stub" "$verifier" "$positive" "$negative_producer_missing" \
    >"$scratch/negative-producer-missing.out" 2>"$scratch/negative-producer-missing.err"; then
    echo 'FAIL: missing producer gpu-um-tsp provenance negative control was accepted' >&2
    exit 1
fi
grep -Fq 'gpu-um-tsp producer provenance is missing or not a regular file' \
    "$scratch/negative-producer-missing.err"

negative_provenance_identity="$scratch/negative-provenance-identity"
negative_producer_identity="$scratch/negative-producer-identity"
cp -a "$positive" "$negative_provenance_identity"
cp -a "$producer" "$negative_producer_identity"
printf '%s\n' 'gpu-um-tsp@977370a239cfe5d8e06aea7fb0e475bd0da58738 (unknown stack)' \
    >"$negative_producer_identity/.pf-gpu-um-provenance"
cp "$negative_producer_identity/.pf-gpu-um-provenance" \
    "$negative_provenance_identity/usr/share/pocketforge/gpu-um-mesa-provenance"
if PF_ROOTFS_LDD="$ldd_stub" "$verifier" \
    "$negative_provenance_identity" "$negative_producer_identity" \
    >"$scratch/negative-provenance-identity.out" \
    2>"$scratch/negative-provenance-identity.err"; then
    echo 'FAIL: non-Zink gpu-um-tsp provenance negative control was accepted' >&2
    exit 1
fi
grep -Fq 'gpu-um-tsp producer provenance does not identify the GE8300 Zink stack' \
    "$scratch/negative-provenance-identity.err"

negative_icd="$scratch/negative-icd-rootfs"
cp -a "$positive" "$negative_icd"
printf '%s\n' '{"ICD":{"library_path":"/usr/lib/aarch64-linux-gnu/libvulkan_lvp.so"}}' \
    >"$negative_icd/usr/share/vulkan/icd.d/lvp_icd.aarch64.json"
if PF_ROOTFS_LDD="$ldd_stub" "$verifier" "$negative_icd" "$producer" \
    >"$scratch/negative-icd.out" 2>"$scratch/negative-icd.err"; then
    echo 'FAIL: foreign Vulkan ICD negative control was accepted' >&2
    exit 1
fi
grep -Fq 'foreign Vulkan ICD manifest:' "$scratch/negative-icd.err"

expect_rejection() {
    label=$1
    candidate=$2
    message=$3
    if PF_ROOTFS_LDD="$ldd_stub" "$verifier" "$candidate" "$producer" \
        >"$scratch/${label}.out" 2>"$scratch/${label}.err"; then
        echo "FAIL: ${label} negative control was accepted" >&2
        exit 1
    fi
    grep -Fq "$message" "$scratch/${label}.err"
}

# Exercise every system and image-user Vulkan loader fallback maintained by the
# repository's shared artifact policy. The two owned manifest directories also
# receive an extra manifest, proving that the allowlist is exact rather than
# merely accepting those directory names.
boundary_number=0
for boundary in $($artifact_policy --print-vulkan-icd-boundaries); do
    boundary_number=$((boundary_number + 1))
    candidate="$scratch/negative-icd-boundary-${boundary_number}"
    cp -a "$positive" "$candidate"
    mkdir -p "$candidate/$boundary"
    printf '%s\n' '{"ICD":{"library_path":"/foreign/libvulkan_lvp.so"}}' \
        >"$candidate/$boundary/foreign_icd.json"
    expect_rejection "negative-icd-boundary-${boundary_number}" "$candidate" \
        'foreign Vulkan ICD manifest:'
done

# A lexical scan must not be bypassable by replacing any discovery path
# component with a link.
negative_boundary_link="$scratch/negative-boundary-link"
cp -a "$positive" "$negative_boundary_link"
mkdir -p "$negative_boundary_link/etc"
ln -s /outside-rootfs "$negative_boundary_link/etc/vulkan"
expect_rejection negative-boundary-link "$negative_boundary_link" \
    'GPU driver discovery boundary reached through symlink:'

# Cover both Mesa's Debian multiarch directory and gpu-um-tsp's copied DRI
# directory. The pinned producer installs its unified Zink megadriver at
# /usr/local/lib/libgallium_dri.so, so no per-driver DRI payload is accepted.
dri_boundary_number=0
for boundary in $($artifact_policy --print-mesa-dri-boundaries) usr/local/lib/dri; do
    dri_boundary_number=$((dri_boundary_number + 1))
    candidate="$scratch/negative-dri-boundary-${dri_boundary_number}"
    cp -a "$positive" "$candidate"
    mkdir -p "$candidate/$boundary"
    printf '%s\n' 'foreign Mesa DRI payload' \
        >"$candidate/$boundary/swrast_dri.so"
    expect_rejection "negative-dri-boundary-${dri_boundary_number}" "$candidate" \
        'foreign Mesa DRI driver:'
done

negative_zink_alias="$scratch/negative-zink-alias"
cp -a "$positive" "$negative_zink_alias"
rm "$negative_zink_alias/usr/local/lib/dri/zink_dri.so"
printf '%s\n' 'unowned zink alias' \
    >"$negative_zink_alias/usr/local/lib/dri/zink_dri.so"
expect_rejection negative-zink-alias "$negative_zink_alias" \
    'gpu-um-tsp DRI artifact mismatch: /usr/local/lib/dri/zink_dri.so rootfs=regular producer=non-regular'

negative_zink_target="$scratch/negative-zink-target"
cp -a "$positive" "$negative_zink_target"
rm "$negative_zink_target/usr/local/lib/dri/zink_dri.so"
ln -s ../libEGL.so.1.0.0 \
    "$negative_zink_target/usr/local/lib/dri/zink_dri.so"
expect_rejection negative-zink-target "$negative_zink_target" \
    'gpu-um-tsp DRI artifact mismatch: /usr/local/lib/dri/zink_dri.so rootfs_target=../libEGL.so.1.0.0 producer_target=libdril_dri.so'

negative_dri_hash="$scratch/negative-dri-hash"
cp -a "$positive" "$negative_dri_hash"
printf '%s\n' 'shadow replacement' \
    >>"$negative_dri_hash/usr/local/lib/dri/libdril_dri.so"
expect_rejection negative-dri-hash "$negative_dri_hash" \
    'gpu-um-tsp DRI artifact mismatch: /usr/local/lib/dri/libdril_dri.so rootfs_sha256='

missing_owned_alias="$scratch/missing-owned-alias"
cp -a "$positive" "$missing_owned_alias"
rm "$missing_owned_alias/usr/local/lib/dri/ili9225_dri.so"
expect_rejection missing-owned-alias "$missing_owned_alias" \
    'gpu-um-tsp DRI artifact missing from rootfs: /usr/local/lib/dri/ili9225_dri.so'

echo "open-gpu-tools-test=PASS positive=owned-stack-with-producer-dri-mirror negative=drm-egl-only,drm-gles-only,runtime-owned-witness,runtime-glmark-egl-identity,runtime-glmark-gles-identity,runtime-vulkaninfo-identity,installed-mesa-vulkan-drivers,changed-hash,changed-provenance,missing-rootfs-provenance,missing-producer-provenance,symlinked-provenance,non-zink-provenance,foreign-icd,all-icd-boundaries,symlinked-boundary,all-dri-boundaries,foreign-zink-alias,changed-zink-target,changed-dri-hash,missing-owned-alias icd_boundaries=${boundary_number} dri_boundaries=${dri_boundary_number}"
