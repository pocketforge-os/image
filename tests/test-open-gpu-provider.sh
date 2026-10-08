#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
packager="$root/build/package-open-gpu-stack.sh"
verifier="$root/scripts/verify-open-gpu-provider.sh"
control="$root/packages/pocketforge-open-gpu-stack/DEBIAN/control"
zink_policy="$root/packages/pocketforge-open-gpu-stack/10-pocketforge-zink.conf"
builder="$root/scripts/build-rootfs.sh"
dockerfile="$root/build/Dockerfile.pf"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/open-gpu-provider.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT

test -x "$packager" || {
    echo "FAIL: source-built open GPU provider packager is missing: $packager" >&2
    exit 1
}
test -x "$verifier" || {
    echo "FAIL: built-image open GPU provider gate is missing: $verifier" >&2
    exit 1
}
test "$(grep -Fc 'scripts/verify-open-gpu-provider.sh' "$builder")" -eq 2
grep -F -- '-Dglvnd=enabled -Dglvnd-vendor-name=mesa' "$dockerfile" >/dev/null
grep -F -- '-Dglx=dri -Degl=enabled -Dgbm=enabled' "$dockerfile" >/dev/null
grep -F -- '-Dplatforms=x11,wayland' "$dockerfile" >/dev/null
grep -F -- '-Dxmlconfig=enabled' "$dockerfile" >/dev/null
grep -F 'libexpat1-dev:arm64' "$dockerfile" >/dev/null
grep -F 'packages/pocketforge-open-gpu-stack/10-pocketforge-zink.conf /tmp/10-pocketforge-zink.conf' \
    "$dockerfile" >/dev/null

# Exercise the production package-list merge in isolation. A package named as
# an explicit apt root wins over a virtual provider, so the provider-backed
# profile must remove every Debian Mesa implementation name before mmdebstrap.
package_section="$scratch/package-section.sh"
# shellcheck disable=SC2016 # Match the literal build-script variable.
sed -n '/^PKG_FILE=/,/^echo "  package list: ${PKG_LIST}"$/p' \
    "$builder" >"$package_section"
resolve_packages() {
    source_root=$1
    device_id=$2
    gamescope_mode=$3
    SRC_DIR="$source_root" VARIANT=release PF_GPU_MODEL=open \
        PF_DEVICE_ID="$device_id" PF_GAMESCOPE_MODE="$gamescope_mode" \
        PF_HAS_DISPLAY=1 sh "$package_section" |
        sed -n 's/^  package list: //p'
}

check_provider_package_solve() {
    label=$1
    resolved_packages=$2
    for package in libegl-mesa0 libgl1-mesa-dri libglx-mesa0 libgbm1 \
        mesa-opencl-icd mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers \
        libosmesa6; do
        if printf '%s\n' "$resolved_packages" | tr ',' '\n' | grep -Fx "$package" >/dev/null; then
            echo "FAIL: $label retains explicit Debian Mesa root: $package" >&2
            return 1
        fi
    done
    for package in libegl1 libgles2 xwayland; do
        printf '%s\n' "$resolved_packages" | tr ',' '\n' | grep -Fx "$package" >/dev/null || {
            echo "FAIL: $label omits neutral client package: $package" >&2
            return 1
        }
    done
}

# The provider contract applies to every shipping and build-only member of the
# A133 open-GPU profile family. In particular, noradio has no Gamescope package
# closure to accidentally supply Xwayland for the provider's glamor path.
for profile_and_mode in \
    a133-open-7x-gpu:g1 \
    a133-open-7x-gpu-cts:g1 \
    a133-open-7x-gpu-noradio:not-shipped; do
    profile=${profile_and_mode%:*}
    mode=${profile_and_mode#*:}
    check_provider_package_solve "$profile" \
        "$(resolve_packages "$root" "$profile" "$mode")"
done

# Negative control in the same invocation: removing the shared Xwayland root
# must make the noradio provider solve fail even though the two Gamescope
# profiles would still obtain Xwayland from their compositor closure.
negative_root="$scratch/source-without-shared-xwayland"
mkdir -p "$negative_root"
cp "$root"/rootfs-packages*.txt "$negative_root/"
sed -i '/^xwayland$/d' \
    "$negative_root/rootfs-packages-a133-open-7x-gpu.txt"
if check_provider_package_solve "negative noradio solve" \
    "$(resolve_packages "$negative_root" a133-open-7x-gpu-noradio not-shipped)" \
    >"$scratch/package-negative.out" 2>"$scratch/package-negative.err"; then
    echo 'FAIL: package negative control accepted a solve without shared Xwayland' >&2
    exit 1
fi
grep -F 'negative noradio solve omits neutral client package: xwayland' \
    "$scratch/package-negative.err" >/dev/null
echo 'open-gpu-provider-package-negative=PASS mutation=remove-shared-xwayland profile=a133-open-7x-gpu-noradio'

producer="$scratch/producer"
rootfs="$scratch/rootfs"
mkdir -p \
    "$producer/usr/local/lib" \
    "$producer/usr/local/lib/gbm" \
    "$producer/usr/local/lib/pkgconfig" \
    "$producer/usr/local/share/drirc.d" \
    "$producer/usr/local/share/glvnd/egl_vendor.d" \
    "$producer/usr/local/share/vulkan/icd.d" \
    "$producer/usr/share/pocketforge/mesa-cache" \
    "$rootfs/usr/lib/aarch64-linux-gnu" \
    "$rootfs/usr/bin" \
    "$rootfs/var/lib/dpkg/info"

for artifact in \
    libEGL_mesa.so.0.0.0 \
    libGLX_mesa.so.0.0.0 \
    libgbm.so.1.0.0 \
    libgallium_dri.so \
    libvulkan_powervr_mesa.so; do
    printf 'gpu-um-tsp fixture: %s\n' "$artifact" \
        >"$producer/usr/local/lib/$artifact"
done
ln -s libEGL_mesa.so.0.0.0 "$producer/usr/local/lib/libEGL_mesa.so.0"
ln -s libGLX_mesa.so.0.0.0 "$producer/usr/local/lib/libGLX_mesa.so.0"
ln -s libgbm.so.1.0.0 "$producer/usr/local/lib/libgbm.so.1"
printf 'gpu-um-tsp fixture: dri_gbm.so\n' \
    >"$producer/usr/local/lib/gbm/dri_gbm.so"
printf 'Name: dri\nVersion: 26.1.7\n' \
    >"$producer/usr/local/lib/pkgconfig/dri.pc"
printf '%s\n' '{"file_format_version":"1.0.0","ICD":{"library_path":"libEGL_mesa.so.0"}}' \
    >"$producer/usr/local/share/glvnd/egl_vendor.d/50_mesa.json"
printf '%s\n' '{"ICD":{"library_path":"/usr/local/lib/libvulkan_powervr_mesa.so"}}' \
    >"$producer/usr/local/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"
test -f "$zink_policy"
if grep -F 'kernel_driver="sun4i-drm"' "$zink_policy" >/dev/null; then
    echo 'FAIL: source Zink loader policy maps sun4i-drm' >&2
    exit 1
fi
cp "$zink_policy" \
    "$producer/usr/local/share/drirc.d/10-pocketforge-zink.conf"
printf '%s\n' \
    'gpu-um-tsp@1234567890abcdef1234567890abcdef12345678 (open Mesa GLX/GLES/EGL/GBM/Vulkan userspace, GE8300 Zink)' \
    >"$producer/.pf-gpu-um-provenance"
cat >"$producer/.pf-gpu-um-build-options.json" <<'EOF'
[
  {"name":"platforms","value":["x11","wayland"]},
  {"name":"glvnd","value":"enabled"},
  {"name":"glvnd-vendor-name","value":"mesa"},
  {"name":"glx","value":"dri"},
  {"name":"egl","value":"enabled"},
  {"name":"gbm","value":"enabled"},
  {"name":"xmlconfig","value":"enabled"},
  {"name":"gallium-drivers","value":["zink"]},
  {"name":"vulkan-drivers","value":["imagination"]}
]
EOF
printf '%s\n' 'fixture Gamescope PVR cache provenance' \
    >"$producer/.pf-gamescope-pvr-cache-provenance"
printf '%s\n' 'fixture foz data' \
    >"$producer/usr/share/pocketforge/mesa-cache/pocketforge-gamescope-ge8300.foz"
printf '%s\n' 'fixture foz index' \
    >"$producer/usr/share/pocketforge/mesa-cache/pocketforge-gamescope-ge8300_idx.foz"
printf '%s/%s/%s\n' mesa_shader_cache_sf \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    >"$producer/usr/share/pocketforge/mesa-cache/pocketforge-gamescope-ge8300.relative-dir"
printf '#!/bin/sh\nexit 0\n' >"$scratch/open-gpu-probe"
chmod 0755 "$scratch/open-gpu-probe"
cat >"$scratch/readelf" <<'EOF'
#!/bin/sh
set -eu
case "$1" in
    -h)
        machine=AArch64
        case "$2" in *red-wrong-arch*) machine='Advanced Micro Devices X86-64' ;; esac
        printf '  Class:                             ELF64\n'
        printf '  Machine:                           %s\n' "$machine"
        ;;
    -Ws)
        case "$2" in
            *red-missing-egl-main*) printf '  1: 0000000000000000 0 FUNC GLOBAL DEFAULT 1 __glx_Main\n' ;;
            *red-missing-glx-main*) printf '  1: 0000000000000000 0 FUNC GLOBAL DEFAULT 1 __egl_Main\n' ;;
            *red-missing-kmsro-screen*/usr/local/lib/libgallium_dri.so) printf '  1: 0000000000000000 0 FUNC GLOBAL DEFAULT 1 zink_drm_create_screen_renderonly\n' ;;
            *red-missing-zink-renderonly*/usr/local/lib/libgallium_dri.so) printf '  1: 0000000000000000 0 FUNC GLOBAL DEFAULT 1 kmsro_drm_screen_create\n' ;;
            *) printf '  1: 0000000000000000 0 FUNC GLOBAL DEFAULT 1 __egl_Main\n  2: 0000000000000000 0 FUNC GLOBAL DEFAULT 1 __glx_Main\n  3: 0000000000000000 0 FUNC GLOBAL DEFAULT 1 kmsro_drm_screen_create\n  4: 0000000000000000 0 FUNC GLOBAL DEFAULT 1 zink_drm_create_screen_renderonly\n' ;;
        esac
        ;;
    *) exit 2 ;;
esac
EOF
chmod 0755 "$scratch/readelf"
export PF_OPEN_GPU_READELF="$scratch/readelf"

SOURCE_DATE_EPOCH=1700000000 "$packager" \
    "$producer" "$scratch/open-gpu-probe" "$control" \
    1234567890abcdef1234567890abcdef12345678 "$scratch/provider-a.deb"
SOURCE_DATE_EPOCH=1700000000 "$packager" \
    "$producer" "$scratch/open-gpu-probe" "$control" \
    1234567890abcdef1234567890abcdef12345678 "$scratch/provider-b.deb"
cmp "$scratch/provider-a.deb" "$scratch/provider-b.deb"

test "$(dpkg-deb -f "$scratch/provider-a.deb" Package)" = pocketforge-open-gpu-stack
test "$(dpkg-deb -f "$scratch/provider-a.deb" Architecture)" = arm64
dpkg-deb -c "$scratch/provider-a.deb" | sed -n '1p' | \
    grep -E '^drwxr-xr-x[[:space:]]+root/root' >/dev/null
package_listing=$(dpkg-deb -c "$scratch/provider-a.deb")
for package_path in \
    usr/share/pocketforge/gamescope-pvr-cache-provenance \
    usr/share/pocketforge/mesa-cache/pocketforge-gamescope-ge8300.foz \
    usr/share/pocketforge/mesa-cache/pocketforge-gamescope-ge8300_idx.foz \
    usr/share/pocketforge/mesa-cache/pocketforge-gamescope-ge8300.relative-dir; do
    printf '%s\n' "$package_listing" | \
        grep -E "^-rw-r--r--[[:space:]]+root/root.*\\./${package_path}$" >/dev/null || {
        echo "provider package does not own mode-0644 cache artifact: ${package_path}" >&2
        exit 1
    }
done
provider_version=$(dpkg-deb -f "$scratch/provider-a.deb" Version)
case "$provider_version" in
    1:26.1.7+pf.1234567890ab) ;;
    *) echo "unexpected provider version: $provider_version" >&2; exit 1 ;;
esac
provides=$(dpkg-deb -f "$scratch/provider-a.deb" Provides)
for package in libegl-mesa0 libegl-vendor libgl1-mesa-dri libglx-mesa0 \
    libglx-vendor libgbm1 mesa-vulkan-drivers; do
    printf '%s\n' "$provides" | grep -F "$package" >/dev/null || {
        echo "Provides omits real artifact capability $package" >&2
        exit 1
    }
done
for package in mesa-opencl-icd mesa-va-drivers mesa-vdpau-drivers libosmesa6; do
    if printf '%s\n' "$provides" | grep -F "$package" >/dev/null; then
        echo "Provides falsely claims unshipped capability $package" >&2
        exit 1
    fi
done
for field in Conflicts Replaces; do
    metadata=$(dpkg-deb -f "$scratch/provider-a.deb" "$field")
    for package in libegl-mesa0 libgl1-mesa-dri libglx-mesa0 libgbm1 \
        mesa-opencl-icd mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers \
        libosmesa6; do
        printf '%s\n' "$metadata" | grep -F "$package" >/dev/null || {
            echo "$field omits forbidden Debian package $package" >&2
            exit 1
        }
    done
done

dpkg-deb -x "$scratch/provider-a.deb" "$rootfs"
if [ -e "$rootfs/usr/local/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json" ]; then
    echo 'FAIL: provider package retains duplicate /usr/local Vulkan ICD manifest' >&2
    exit 1
fi
cp "$producer/.pf-gpu-um-provenance" \
    "$rootfs/usr/share/pocketforge/gpu-um-mesa-provenance"
cp "$producer/.pf-gpu-um-build-options.json" \
    "$rootfs/usr/share/pocketforge/gpu-um-mesa-build-options.json"
printf 'neutral GLVND dispatcher\n' \
    >"$rootfs/usr/lib/aarch64-linux-gnu/libEGL.so.1"
printf 'neutral GLVND dispatcher\n' \
    >"$rootfs/usr/lib/aarch64-linux-gnu/libGL.so.1"
printf 'neutral GLVND dispatcher\n' \
    >"$rootfs/usr/lib/aarch64-linux-gnu/libGLX.so.0"
printf '#!/bin/sh\nexit 0\n' >"$rootfs/usr/bin/Xwayland"
chmod 0755 "$rootfs/usr/bin/Xwayland"

cat >"$rootfs/var/lib/dpkg/status" <<EOF
Package: pocketforge-open-gpu-stack
Status: install ok installed
Architecture: arm64
Version: $provider_version
Provides: libegl-mesa0 (= $provider_version), libegl-vendor, libgl1-mesa-dri (= $provider_version), libglx-mesa0 (= $provider_version), libglx-vendor, libgbm1 (= $provider_version), mesa-vulkan-drivers (= $provider_version)
Conflicts: libegl-mesa0, libgl1-mesa-dri, libglx-mesa0, libgbm1, mesa-opencl-icd, mesa-va-drivers, mesa-vdpau-drivers, mesa-vulkan-drivers, libosmesa6
Replaces: libegl-mesa0, libgl1-mesa-dri, libglx-mesa0, libgbm1, mesa-opencl-icd, mesa-va-drivers, mesa-vdpau-drivers, mesa-vulkan-drivers, libosmesa6
Description: fixture provider

Package: libegl1
Status: install ok installed
Architecture: arm64
Version: 1.6.0-1

Package: libgles2
Status: install ok installed
Architecture: arm64
Version: 1.6.0-1

Package: libgl1
Status: install ok installed
Architecture: arm64
Version: 1.6.0-1

Package: libglx0
Status: install ok installed
Architecture: arm64
Version: 1.6.0-1

Package: libglvnd0
Status: install ok installed
Architecture: arm64
Version: 1.6.0-1

Package: xwayland
Status: install ok installed
Architecture: arm64
Version: 2:22.1.9-1
EOF
dpkg-deb --fsys-tarfile "$scratch/provider-a.deb" | tar -tf - | \
    sed 's|^\./|/|' >"$rootfs/var/lib/dpkg/info/pocketforge-open-gpu-stack.list"

positive_output=$("$verifier" "$rootfs" "$producer")
printf '%s\n' "$positive_output"
printf '%s\n' "$positive_output" | grep -Fx \
    'open-gpu-provider=PASS provider=pocketforge-open-gpu-stack source=1234567890abcdef1234567890abcdef12345678 egl=glvnd:mesa vendor_json=/usr/share/glvnd/egl_vendor.d/50_mesa.json vendor_library=/usr/local/lib/libEGL_mesa.so.0 glx=glvnd:mesa glx_vendor_library=/usr/local/lib/libGLX_mesa.so.0 gbm=owned dri=zink zink_policy=drirc:powervr kmsro=present zink_renderonly=present vulkan=powervr vulkan_manifests=1 vulkan_json=/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json xwayland=glamor-capable debian_mesa=absent' \
    >/dev/null

expect_rejection() {
    label=$1
    candidate=$2
    expected=$3
    if "$verifier" "$candidate" "$producer" \
        >"$scratch/$label.out" 2>"$scratch/$label.err"; then
        echo "FAIL: $label fixture was accepted" >&2
        exit 1
    fi
    grep -F "$expected" "$scratch/$label.err" >/dev/null || {
        cat "$scratch/$label.err" >&2
        echo "FAIL: $label did not report: $expected" >&2
        exit 1
    }
}

# An inherited loader override is not a reliable image policy: clean or
# sandboxed process environments silently lose it. The built-image gate must
# reject every occurrence and require the provider-owned drirc policy instead.
candidate="$scratch/red-loader-environment"
cp -a "$rootfs" "$candidate"
mkdir -p "$candidate/etc/environment.d"
printf '%s\n' 'MESA_LOADER_DRIVER_OVERRIDE=zink' \
    >"$candidate/etc/environment.d/60-pocketforge-zink.conf"
expect_rejection red-loader-environment "$candidate" \
    'MESA_LOADER_DRIVER_OVERRIDE is forbidden in the rootfs:'

candidate="$scratch/red-missing-zink-policy"
cp -a "$rootfs" "$candidate"
rm "$candidate/usr/local/share/drirc.d/10-pocketforge-zink.conf"
expect_rejection red-missing-zink-policy "$candidate" \
    'Zink loader policy is missing, not regular, or symlinked:'

candidate="$scratch/red-old-two-block-zink-policy"
producer_bad="$scratch/producer-old-two-block-zink-policy"
cp -a "$rootfs" "$candidate"
cp -a "$producer" "$producer_bad"
for policy in \
    "$candidate/usr/local/share/drirc.d/10-pocketforge-zink.conf" \
    "$producer_bad/usr/local/share/drirc.d/10-pocketforge-zink.conf"; do
    cat >"$policy" <<'EOF'
<?xml version="1.0" standalone="yes"?>
<driconf>
  <device driver="loader" kernel_driver="powervr">
    <application name="PocketForge Zink">
      <option name="dri_driver" value="zink" />
    </application>
  </device>
  <device driver="loader" kernel_driver="sun4i-drm">
    <application name="PocketForge Zink">
      <option name="dri_driver" value="zink" />
    </application>
  </device>
</driconf>
EOF
done
if "$verifier" "$candidate" "$producer_bad" \
    >"$scratch/red-old-two-block-zink-policy.out" 2>"$scratch/red-old-two-block-zink-policy.err"; then
    echo 'FAIL: red-old-two-block-zink-policy fixture was accepted' >&2
    exit 1
fi
grep -F 'Zink loader policy mismatch:' \
    "$scratch/red-old-two-block-zink-policy.err" >/dev/null

for fixture in zink_dri libEGL_mesa libGLX_mesa libgbm; do
    candidate="$scratch/red-$fixture"
    cp -a "$rootfs" "$candidate"
    case "$fixture" in
        zink_dri)
            mkdir -p "$candidate/usr/lib/aarch64-linux-gnu/dri"
            : >"$candidate/usr/lib/aarch64-linux-gnu/dri/zink_dri.so"
            ;;
        *) : >"$candidate/usr/lib/aarch64-linux-gnu/$fixture.so.0" ;;
    esac
    expect_rejection "red-$fixture" "$candidate" 'forbidden Debian Mesa driver file:'
done

for package in libegl-mesa0 libgl1-mesa-dri libglx-mesa0 libgbm1 \
    mesa-opencl-icd mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers \
    libosmesa6; do
    candidate="$scratch/red-installed-$package"
    cp -a "$rootfs" "$candidate"
    cat >>"$candidate/var/lib/dpkg/status" <<EOF

Package: $package
Status: install ok installed
Architecture: arm64
Version: 22.3.6-1
EOF
    grep -A1 -Fx "Package: $package" "$candidate/var/lib/dpkg/status" | \
        grep -Fx 'Status: install ok installed' >/dev/null
    expect_rejection "red-installed-$package" "$candidate" \
        "forbidden Debian Mesa driver package is installed: $package"
done

candidate="$scratch/red-duplicate-egl-json"
cp -a "$rootfs" "$candidate"
mkdir -p "$candidate/usr/local/share/glvnd/egl_vendor.d"
cp "$candidate/usr/share/glvnd/egl_vendor.d/50_mesa.json" \
    "$candidate/usr/local/share/glvnd/egl_vendor.d/50_mesa.json"
expect_rejection red-duplicate-egl-json "$candidate" \
    'expected exactly one 50_mesa.json, found 2'

candidate="$scratch/red-duplicate-vulkan-icd"
cp -a "$rootfs" "$candidate"
mkdir -p "$candidate/usr/local/share/vulkan/icd.d"
cp "$candidate/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json" \
    "$candidate/usr/local/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"
expect_rejection red-duplicate-vulkan-icd "$candidate" \
    'expected exactly one Vulkan ICD manifest, found 2'

# The loader does not care about the manifest filename. A differently named
# alias to the same library also enumerates the physical device twice.
candidate="$scratch/red-duplicate-vulkan-alias"
cp -a "$rootfs" "$candidate"
cp "$candidate/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json" \
    "$candidate/usr/share/vulkan/icd.d/powervr_alias.json"
expect_rejection red-duplicate-vulkan-alias "$candidate" \
    'expected exactly one Vulkan ICD manifest, found 2'

candidate="$scratch/red-relative-egl-json"
cp -a "$rootfs" "$candidate"
printf '%s\n' '{"file_format_version":"1.0.0","ICD":{"library_path":"libEGL_mesa.so.0"}}' \
    >"$candidate/usr/share/glvnd/egl_vendor.d/50_mesa.json"
expect_rejection red-relative-egl-json "$candidate" \
    'EGL vendor library_path must be /usr/local/lib/libEGL_mesa.so.0'

candidate="$scratch/red-wrong-target-egl-json"
cp -a "$rootfs" "$candidate"
printf '%s\n' '{"file_format_version":"1.0.0","ICD":{"library_path":"/usr/lib/aarch64-linux-gnu/libEGL_mesa.so.0"}}' \
    >"$candidate/usr/share/glvnd/egl_vendor.d/50_mesa.json"
expect_rejection red-wrong-target-egl-json "$candidate" \
    'EGL vendor library_path must be /usr/local/lib/libEGL_mesa.so.0'

candidate="$scratch/red-egl-boundary-link"
cp -a "$rootfs" "$candidate"
mv "$candidate/usr/share/glvnd/egl_vendor.d" "$candidate/vendor-real"
ln -s ../../../../vendor-real "$candidate/usr/share/glvnd/egl_vendor.d"
expect_rejection red-egl-boundary-link "$candidate" \
    'EGL vendor boundary reached through symlink:'

candidate="$scratch/red-missing-egl-vendor"
cp -a "$rootfs" "$candidate"
rm "$candidate/usr/local/lib/libEGL_mesa.so.0"
expect_rejection red-missing-egl-vendor "$candidate" \
    'rootfs gpu-um-tsp artifact is missing: usr/local/lib/libEGL_mesa.so.0'

candidate="$scratch/red-missing-glx-vendor"
cp -a "$rootfs" "$candidate"
rm "$candidate/usr/local/lib/libGLX_mesa.so.0"
expect_rejection red-missing-glx-vendor "$candidate" \
    'rootfs gpu-um-tsp artifact is missing: usr/local/lib/libGLX_mesa.so.0'

candidate="$scratch/red-changed-gallium"
cp -a "$rootfs" "$candidate"
printf 'tampered\n' >"$candidate/usr/local/lib/libgallium_dri.so"
expect_rejection red-changed-gallium "$candidate" \
    'gpu-um-tsp artifact hash mismatch: usr/local/lib/libgallium_dri.so'

candidate="$scratch/red-wrong-arch"
cp -a "$rootfs" "$candidate"
expect_rejection red-wrong-arch "$candidate" \
    'owned artifact is not AArch64: /usr/local/lib/libEGL_mesa.so.0'

candidate="$scratch/red-missing-egl-main"
cp -a "$rootfs" "$candidate"
expect_rejection red-missing-egl-main "$candidate" \
    'GLVND EGL vendor does not export __egl_Main'

candidate="$scratch/red-missing-glx-main"
cp -a "$rootfs" "$candidate"
expect_rejection red-missing-glx-main "$candidate" \
    'GLVND GLX vendor does not export __glx_Main'

candidate="$scratch/red-missing-kmsro-screen"
cp -a "$rootfs" "$candidate"
expect_rejection red-missing-kmsro-screen "$candidate" \
    'Gallium DRI does not export kmsro_drm_screen_create'

candidate="$scratch/red-missing-zink-renderonly"
cp -a "$rootfs" "$candidate"
expect_rejection red-missing-zink-renderonly "$candidate" \
    'Gallium DRI does not export zink_drm_create_screen_renderonly'

candidate="$scratch/red-glx-disabled"
producer_bad="$scratch/producer-glx-disabled"
cp -a "$rootfs" "$candidate"
cp -a "$producer" "$producer_bad"
sed -i 's/"name":"glx","value":"dri"/"name":"glx","value":"disabled"/' \
    "$producer_bad/.pf-gpu-um-build-options.json"
cp "$producer_bad/.pf-gpu-um-build-options.json" \
    "$candidate/usr/share/pocketforge/gpu-um-mesa-build-options.json"
if "$verifier" "$candidate" "$producer_bad" \
    >"$scratch/red-glx-disabled.out" 2>"$scratch/red-glx-disabled.err"; then
    echo 'FAIL: red-glx-disabled fixture was accepted' >&2
    exit 1
fi
grep -F 'Mesa build option mismatch: glx expected=dri actual=disabled' \
    "$scratch/red-glx-disabled.err" >/dev/null

candidate="$scratch/red-xmlconfig-disabled"
producer_bad="$scratch/producer-xmlconfig-disabled"
cp -a "$rootfs" "$candidate"
cp -a "$producer" "$producer_bad"
sed -i 's/"name":"xmlconfig","value":"enabled"/"name":"xmlconfig","value":"disabled"/' \
    "$producer_bad/.pf-gpu-um-build-options.json"
cp "$producer_bad/.pf-gpu-um-build-options.json" \
    "$candidate/usr/share/pocketforge/gpu-um-mesa-build-options.json"
if "$verifier" "$candidate" "$producer_bad" \
    >"$scratch/red-xmlconfig-disabled.out" 2>"$scratch/red-xmlconfig-disabled.err"; then
    echo 'FAIL: red-xmlconfig-disabled fixture was accepted' >&2
    exit 1
fi
grep -F 'Mesa build option mismatch: xmlconfig expected=enabled actual=disabled' \
    "$scratch/red-xmlconfig-disabled.err" >/dev/null

echo 'open-gpu-provider-test=PASS green=source-package+glvnd-egl+glx-routing+drirc-powervr+kmsro+zink-renderonly red=loader-environment,missing-zink-policy,old-two-block-zink-policy,false-provides,debian-zink,debian-egl,debian-glx,debian-gbm,all-forbidden-packages,duplicate-egl-json,duplicate-vulkan-icd,duplicate-vulkan-alias,relative-json,wrong-target-json,symlink-boundary,missing-egl-vendor,missing-glx-vendor,changed-hash,wrong-arch,missing-egl-main,missing-glx-main,missing-kmsro-screen,missing-zink-renderonly,glx-disabled,xmlconfig-disabled'
