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
printf '%s\n' 'owned gpu-um-tsp artifact: zink_dri.so' \
    >"$producer/usr/local/lib/dri/zink_dri.so"
printf '%s\n' '{"ICD":{"library_path":"/usr/local/lib/libvulkan_powervr_mesa.so"}}' \
    >"$producer/usr/local/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"
cp -a "$producer/usr/local/." "$positive/usr/local/"
cp "$producer/usr/local/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json" \
    "$positive/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"

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
    printf '#!/bin/sh\nexit 0\n' >"$positive/usr/bin/$binary"
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
libEGL.so.1 => /usr/local/lib/libEGL.so.1 (0x00000000)
libGLESv2.so.2 => /usr/local/lib/libGLESv2.so.2 (0x00000000)
libgbm.so.1 => /usr/local/lib/libgbm.so.1 (0x00000000)
libvulkan.so.1 => /usr/lib/aarch64-linux-gnu/libvulkan.so.1 (0x00000000)
libc.so.6 => /lib/aarch64-linux-gnu/libc.so.6 (0x00000000)
OUTPUT
EOF
chmod 0755 "$ldd_stub"

positive_output=$(PF_ROOTFS_LDD="$ldd_stub" "$verifier" "$positive" "$producer")
printf '%s\n' "$positive_output"
printf '%s\n' "$positive_output" | grep -Fq 'open-gpu-tools=PASS'

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
# directory. Only the already hash-checked local zink_dri.so is accepted.
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

echo "open-gpu-tools-test=PASS positive=owned-stack negative=installed-mesa-vulkan-drivers,changed-hash,foreign-icd,all-icd-boundaries,symlinked-boundary,all-dri-boundaries icd_boundaries=${boundary_number} dri_boundaries=${dri_boundary_number}"
