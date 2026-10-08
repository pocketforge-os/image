#!/bin/sh
# Fail closed unless the built rootfs has one owned Mesa vendor behind GLVND.
set -eu

if [ "$#" -ne 2 ]; then
    echo 'usage: verify-open-gpu-provider.sh ROOTFS GPU_UM_MESA_DIR' >&2
    exit 2
fi

rootfs=$1
producer=$2
status_file="$rootfs/var/lib/dpkg/status"

fatal() {
    echo "FATAL: open GPU provider: $*" >&2
    exit 1
}

[ -d "$rootfs" ] || fatal "rootfs is not a directory: $rootfs"
[ -d "$producer/usr/local" ] || fatal "producer tree is missing: $producer/usr/local"
[ -f "$status_file" ] || fatal "dpkg installed-state database is missing: $status_file"

package_is_installed() {
    awk -v wanted="$1" '
        $1 == "Package:" { package = $2 }
        $1 == "Status:" && package == wanted &&
            $2 == "install" && $3 == "ok" && $4 == "installed" { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$status_file"
}

package_field() {
    awk -v wanted="$1" -v wanted_field="$2" '
        BEGIN { in_package = 0; collecting = 0 }
        $1 == "Package:" {
            in_package = ($2 == wanted)
            collecting = 0
        }
        in_package && index($0, wanted_field ":") == 1 {
            sub("^[^:]*:[[:space:]]*", "")
            value = $0
            collecting = 1
            next
        }
        in_package && collecting && $0 ~ /^[[:space:]]/ {
            sub("^[[:space:]]+", "")
            value = value " " $0
            next
        }
        in_package && collecting { collecting = 0 }
        END {
            if (value == "") exit 1
            print value
        }
    ' "$status_file"
}

package_is_installed pocketforge-open-gpu-stack \
    || fatal 'pocketforge-open-gpu-stack is not installed'
provider_version=$(package_field pocketforge-open-gpu-stack Version) \
    || fatal 'provider Version is missing'
provider_arch=$(package_field pocketforge-open-gpu-stack Architecture) \
    || fatal 'provider Architecture is missing'
[ "$provider_arch" = arm64 ] || fatal "provider Architecture must be arm64: $provider_arch"
provider_provides=$(package_field pocketforge-open-gpu-stack Provides) \
    || fatal 'provider Provides is missing'
provider_conflicts=$(package_field pocketforge-open-gpu-stack Conflicts) \
    || fatal 'provider Conflicts is missing'
provider_replaces=$(package_field pocketforge-open-gpu-stack Replaces) \
    || fatal 'provider Replaces is missing'

for package in libegl-mesa0 libgl1-mesa-dri libglx-mesa0 libgbm1 \
    mesa-vulkan-drivers; do
    printf '%s\n' "$provider_provides" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        grep -Fx "$package (= $provider_version)" >/dev/null \
        || fatal "provider lacks versioned Provides for $package"
done
for package in mesa-opencl-icd mesa-va-drivers mesa-vdpau-drivers libosmesa6; do
    if printf '%s\n' "$provider_provides" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        grep -Eq "^$package([[:space:]]|$)"; then
        fatal "provider falsely Provides unshipped capability $package"
    fi
done
for package in libegl-mesa0 libgl1-mesa-dri libglx-mesa0 libgbm1 \
    mesa-opencl-icd mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers \
    libosmesa6; do
    for field_value in "$provider_conflicts" "$provider_replaces"; do
        printf '%s\n' "$field_value" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
            grep -Fx "$package" >/dev/null \
            || fatal "provider lacks Conflicts/Replaces coverage for $package"
    done
done
for virtual in libegl-vendor libglx-vendor; do
    printf '%s\n' "$provider_provides" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
        grep -Fx "$virtual" >/dev/null \
        || fatal "provider lacks virtual Provides for $virtual"
done

for package in libegl-mesa0 libgl1-mesa-dri libglx-mesa0 libgbm1 \
    mesa-opencl-icd mesa-va-drivers mesa-vdpau-drivers mesa-vulkan-drivers \
    libosmesa6; do
    if package_is_installed "$package"; then
        fatal "forbidden Debian Mesa driver package is installed: $package"
    fi
done
for package in libegl1 libgles2 libgl1 libglx0 libglvnd0; do
    package_is_installed "$package" \
        || fatal "neutral GLVND client package is not installed: $package"
done
package_is_installed xwayland || fatal 'Xwayland is not installed for the glamor path'
[ -x "$rootfs/usr/bin/Xwayland" ] || fatal 'Xwayland binary is missing'
[ -e "$rootfs/usr/lib/aarch64-linux-gnu/libEGL.so.1" ] \
    || fatal 'neutral GLVND libEGL.so.1 dispatcher is missing'
[ -e "$rootfs/usr/lib/aarch64-linux-gnu/libGL.so.1" ] \
    || fatal 'neutral GLVND libGL.so.1 dispatcher is missing'
[ -e "$rootfs/usr/lib/aarch64-linux-gnu/libGLX.so.0" ] \
    || fatal 'neutral GLVND libGLX.so.0 dispatcher is missing'

provider_list="$rootfs/var/lib/dpkg/info/pocketforge-open-gpu-stack.list"
if [ ! -f "$provider_list" ] || [ -L "$provider_list" ]; then
    fatal 'provider dpkg ownership list is missing or not a regular file'
fi

# Zink selection is image policy, not inherited process state. Search text
# files across the complete rootfs so environment.d, profile, systemd, launcher,
# and application-specific exports are all rejected while ELF string tables are
# ignored as binary data.
loader_override=$(find "$rootfs" -xdev -type f -exec \
    grep -IlE '(^|[^[:alnum:]_])MESA_LOADER_DRIVER_OVERRIDE[[:space:]]*=' {} + | \
    sed -n '1p')
[ -z "$loader_override" ] \
    || fatal "MESA_LOADER_DRIVER_OVERRIDE is forbidden in the rootfs: ${loader_override#"$rootfs"}"

verify_owned_artifact() {
    relative=$1
    source_path="$producer/$relative"
    rootfs_path="$rootfs/$relative"
    [ -e "$source_path" ] || fatal "gpu-um-tsp producer artifact is missing: $relative"
    [ -e "$rootfs_path" ] || fatal "rootfs gpu-um-tsp artifact is missing: $relative"
    grep -Fx "/$relative" "$provider_list" >/dev/null \
        || fatal "provider does not own rootfs artifact: /$relative"
    source_hash=$(sha256sum "$source_path" | awk '{ print $1 }')
    rootfs_hash=$(sha256sum "$rootfs_path" | awk '{ print $1 }')
    [ "$source_hash" = "$rootfs_hash" ] \
        || fatal "gpu-um-tsp artifact hash mismatch: $relative producer=$source_hash rootfs=$rootfs_hash"
    echo "open-gpu-provider-artifact=PASS path=/$relative sha256=$rootfs_hash"
}

for artifact in \
    usr/local/lib/libEGL_mesa.so.0 \
    usr/local/lib/libGLX_mesa.so.0 \
    usr/local/lib/libgbm.so.1 \
    usr/local/lib/gbm/dri_gbm.so \
    usr/local/lib/libgallium_dri.so \
    usr/local/lib/libvulkan_powervr_mesa.so; do
    verify_owned_artifact "$artifact"
done

zink_policy_relative=usr/local/share/drirc.d/10-pocketforge-zink.conf
zink_policy_source="$producer/$zink_policy_relative"
zink_policy_rootfs="$rootfs/$zink_policy_relative"
for policy_path in "$zink_policy_source" "$zink_policy_rootfs"; do
    if [ ! -f "$policy_path" ] || [ -L "$policy_path" ]; then
        fatal "Zink loader policy is missing, not regular, or symlinked: $policy_path"
    fi
done
policy_component=$rootfs
for policy_name in usr local share drirc.d; do
    policy_component=$policy_component/$policy_name
    [ ! -L "$policy_component" ] \
        || fatal "Zink loader policy boundary reached through symlink: ${policy_component#"$rootfs"}"
done
verify_owned_artifact "$zink_policy_relative"
if ! python3 - "$zink_policy_rootfs" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except (ET.ParseError, OSError) as error:
    print(f"FATAL: open GPU provider: cannot parse Zink loader policy: {error}", file=sys.stderr)
    raise SystemExit(1)

expected = [("powervr", "zink")]
actual = []
if root.tag != "driconf":
    print(f"FATAL: open GPU provider: Zink loader policy root must be driconf: {root.tag}", file=sys.stderr)
    raise SystemExit(1)
for device in list(root):
    if device.tag != "device" or set(device.attrib) != {"driver", "kernel_driver"} or device.get("driver") != "loader":
        print("FATAL: open GPU provider: Zink loader policy has a non-loader device", file=sys.stderr)
        raise SystemExit(1)
    applications = list(device)
    if len(applications) != 1 or applications[0].tag != "application" or applications[0].attrib != {"name": "PocketForge Zink"}:
        print("FATAL: open GPU provider: Zink loader policy has a non-canonical application", file=sys.stderr)
        raise SystemExit(1)
    options = list(applications[0])
    if len(options) != 1 or options[0].tag != "option" or set(options[0].attrib) != {"name", "value"} or options[0].get("name") != "dri_driver":
        print("FATAL: open GPU provider: Zink loader policy has a non-canonical option", file=sys.stderr)
        raise SystemExit(1)
    actual.append((device.get("kernel_driver"), options[0].get("value")))
if actual != expected:
    print(f"FATAL: open GPU provider: Zink loader policy mismatch: expected={expected} actual={actual}", file=sys.stderr)
    raise SystemExit(1)
PY
then
    exit 1
fi

readelf_command=${PF_OPEN_GPU_READELF:-readelf}
nm_command=${PF_OPEN_GPU_NM:-nm}
verify_aarch64_elf() {
    relative=$1
    if ! elf_header=$($readelf_command -h "$rootfs/$relative" 2>&1); then
        printf '%s\n' "$elf_header" >&2
        fatal "cannot inspect owned ELF: /$relative"
    fi
    printf '%s\n' "$elf_header" | grep -Eq 'Class:[[:space:]]+ELF64' \
        || fatal "owned artifact is not ELF64: /$relative"
    printf '%s\n' "$elf_header" | grep -Eq 'Machine:[[:space:]]+AArch64' \
        || fatal "owned artifact is not AArch64: /$relative"
}
for artifact in \
    usr/local/lib/libEGL_mesa.so.0 \
    usr/local/lib/libGLX_mesa.so.0 \
    usr/local/lib/libgbm.so.1 \
    usr/local/lib/gbm/dri_gbm.so \
    usr/local/lib/libgallium_dri.so \
    usr/local/lib/libvulkan_powervr_mesa.so; do
    verify_aarch64_elf "$artifact"
done
if ! egl_symbols=$($readelf_command -Ws \
    "$rootfs/usr/local/lib/libEGL_mesa.so.0" 2>&1); then
    printf '%s\n' "$egl_symbols" >&2
    fatal 'cannot inspect GLVND EGL vendor symbols'
fi
printf '%s\n' "$egl_symbols" | grep -Eq '[[:space:]]__egl_Main$' \
    || fatal 'GLVND EGL vendor does not export __egl_Main'
if ! glx_symbols=$($readelf_command -Ws \
    "$rootfs/usr/local/lib/libGLX_mesa.so.0" 2>&1); then
    printf '%s\n' "$glx_symbols" >&2
    fatal 'cannot inspect GLVND GLX vendor symbols'
fi
printf '%s\n' "$glx_symbols" | grep -Eq '[[:space:]]__glx_Main$' \
    || fatal 'GLVND GLX vendor does not export __glx_Main'
verify_evidence_file() {
    producer_relative=$1
    rootfs_relative=$2
    source_path="$producer/$producer_relative"
    rootfs_path="$rootfs/$rootfs_relative"
    if [ ! -f "$source_path" ] || [ -L "$source_path" ]; then
        fatal "producer evidence is missing or not regular: $producer_relative"
    fi
    if [ ! -f "$rootfs_path" ] || [ -L "$rootfs_path" ]; then
        fatal "rootfs evidence is missing or not regular: $rootfs_relative"
    fi
    grep -Fx "/$rootfs_relative" "$provider_list" >/dev/null \
        || fatal "provider does not own evidence: /$rootfs_relative"
    source_hash=$(sha256sum "$source_path" | awk '{ print $1 }')
    rootfs_hash=$(sha256sum "$rootfs_path" | awk '{ print $1 }')
    [ "$source_hash" = "$rootfs_hash" ] \
        || fatal "evidence hash mismatch: $rootfs_relative producer=$source_hash rootfs=$rootfs_hash"
}
verify_evidence_file .pf-gpu-um-provenance usr/share/pocketforge/gpu-um-mesa-provenance
verify_evidence_file .pf-gpu-um-build-options.json usr/share/pocketforge/gpu-um-mesa-build-options.json
source_sha=$(sed -n \
    's/^gpu-um-tsp@\([0-9a-f]\{40\}\) (open Mesa GLX\/GLES\/EGL\/GBM\/Vulkan userspace, GE8300 Zink)$/\1/p' \
    "$producer/.pf-gpu-um-provenance")
[ "${#source_sha}" -eq 40 ] \
    || fatal 'producer provenance does not contain one exact gpu-um-tsp source SHA'

if ! python3 - "$producer/.pf-gpu-um-build-options.json" <<'PY'
import json
import sys

options = {entry["name"]: entry["value"] for entry in json.load(open(sys.argv[1], encoding="utf-8"))}
expected = {
    "platforms": ["x11", "wayland"],
    "glvnd": "enabled",
    "glvnd-vendor-name": "mesa",
    "glx": "dri",
    "egl": "enabled",
    "gbm": "enabled",
    "xmlconfig": "enabled",
    "gallium-drivers": ["zink"],
    "vulkan-drivers": ["imagination"],
}
for name, wanted in expected.items():
    actual = options.get(name)
    if actual != wanted:
        def display(value):
            if isinstance(value, bool):
                return str(value).lower()
            if isinstance(value, list):
                return ",".join(value)
            return str(value)
        print(f"FATAL: open GPU provider: Mesa build option mismatch: {name} expected={display(wanted)} actual={display(actual)}", file=sys.stderr)
        raise SystemExit(1)
PY
then
    exit 1
fi

gallium_dri="$rootfs/usr/local/lib/libgallium_dri.so"
if ! gallium_defined_symbols=$($nm_command --defined-only "$gallium_dri" 2>&1); then
    printf '%s\n' "$gallium_defined_symbols" >&2
    fatal 'cannot inspect Gallium DRI defined symbols'
fi
gallium_defines() {
    wanted=$1
    printf '%s\n' "$gallium_defined_symbols" | awk -v wanted="$wanted" '
        $NF == wanted { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}
if gallium_defines kmsro_drm_screen_create && \
   gallium_defines zink_drm_create_screen_renderonly; then
    kmsro_evidence=static-symtab
else
    if ! gallium_sections=$($readelf_command --sections --wide \
        "$gallium_dri" 2>&1); then
        printf '%s\n' "$gallium_sections" >&2
        fatal 'cannot inspect Gallium DRI sections'
    fi
    if printf '%s\n' "$gallium_sections" | \
        awk '$2 == ".symtab" { found = 1 } END { exit(found ? 0 : 1) }'; then
        gallium_defines kmsro_drm_screen_create \
            || fatal 'Gallium DRI static symbol table does not define kmsro_drm_screen_create'
        gallium_defines zink_drm_create_screen_renderonly \
            || fatal 'Gallium DRI static symbol table does not define zink_drm_create_screen_renderonly'
    fi
    # Mesa meson.build:336 adds the KMSRO winsys whenever Zink is selected.
    # The validated build-options record therefore proves the path was built
    # when packaging has stripped the static symbol table from the shipped DSO.
    kmsro_evidence=build-options:zink-implies-kmsro
fi

reject_symlinked_boundary() {
    boundary=$1
    component=$rootfs
    old_ifs=$IFS
    IFS=/
    for name in $boundary; do
        component=$component/$name
        if [ -L "$component" ]; then
            IFS=$old_ifs
            fatal "EGL vendor boundary reached through symlink: /$boundary component=${component#"$rootfs"}"
        fi
    done
    IFS=$old_ifs
}
reject_symlinked_boundary usr/share/glvnd/egl_vendor.d

vendor_json_count=$(find "$rootfs" \( -type f -o -type l \) \
    -name '50_mesa.json' -print | wc -l)
[ "$vendor_json_count" -eq 1 ] \
    || fatal "expected exactly one 50_mesa.json, found $vendor_json_count"
vendor_json="$rootfs/usr/share/glvnd/egl_vendor.d/50_mesa.json"
if [ ! -f "$vendor_json" ] || [ -L "$vendor_json" ]; then
    fatal 'canonical EGL vendor JSON is missing or not a regular file'
fi
grep -Fx '/usr/share/glvnd/egl_vendor.d/50_mesa.json' "$provider_list" >/dev/null \
    || fatal 'provider does not own canonical EGL vendor JSON'
if ! python3 - "$vendor_json" <<'PY'
import json
import sys

path = json.load(open(sys.argv[1], encoding="utf-8")).get("ICD", {}).get("library_path")
expected = "/usr/local/lib/libEGL_mesa.so.0"
if path != expected:
    print(f"FATAL: open GPU provider: EGL vendor library_path must be {expected}: {path}", file=sys.stderr)
    raise SystemExit(1)
PY
then
    exit 1
fi

producer_icd="$producer/usr/local/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"
rootfs_icd="$rootfs/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"
[ -f "$producer_icd" ] || fatal 'producer PowerVR ICD JSON is missing'
rootfs_icd_count=$(find "$rootfs" \( -type f -o -type l \) \
    -path '*/vulkan/icd.d/*.json' -print | wc -l)
[ "$rootfs_icd_count" -eq 1 ] \
    || fatal "expected exactly one Vulkan ICD manifest, found $rootfs_icd_count"
if [ ! -f "$rootfs_icd" ] || [ -L "$rootfs_icd" ]; then
    fatal 'canonical PowerVR ICD JSON is missing or not regular'
fi
grep -Fx '/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json' "$provider_list" >/dev/null \
    || fatal 'provider does not own canonical PowerVR ICD JSON'
[ "$(sha256sum "$producer_icd" | awk '{ print $1 }')" = \
  "$(sha256sum "$rootfs_icd" | awk '{ print $1 }')" ] \
    || fatal 'canonical PowerVR ICD JSON differs from the producer'

for boundary in usr/lib/aarch64-linux-gnu lib/aarch64-linux-gnu; do
    directory="$rootfs/$boundary"
    [ -d "$directory" ] || continue
    forbidden=$(find "$directory" \
        \( -path '*/dri/*_dri.so*' -o -name 'libEGL_mesa.so*' -o \
           -name 'libGLX_mesa.so*' -o -name 'libgbm.so*' \) -print -quit)
    [ -z "$forbidden" ] \
        || fatal "forbidden Debian Mesa driver file: ${forbidden#"$rootfs"}"
done

# GLVND asks the X server for the vendor name and dlopens
# libGLX_<vendor>.so.0. With "mesa" selected, a unique provider-owned basename
# makes that route unambiguous without a GLX JSON override.
glx_vendor_count=$(find "$rootfs" \( -type f -o -type l \) \
    -name 'libGLX_mesa.so.0' -print | wc -l)
[ "$glx_vendor_count" -eq 1 ] \
    || fatal "expected exactly one GLVND Mesa GLX vendor, found $glx_vendor_count"
[ -e "$rootfs/usr/local/lib/libGLX_mesa.so.0" ] \
    || fatal 'canonical GLVND Mesa GLX vendor is missing from /usr/local/lib'

echo "open-gpu-provider=PASS provider=pocketforge-open-gpu-stack source=${source_sha} egl=glvnd:mesa vendor_json=/usr/share/glvnd/egl_vendor.d/50_mesa.json vendor_library=/usr/local/lib/libEGL_mesa.so.0 glx=glvnd:mesa glx_vendor_library=/usr/local/lib/libGLX_mesa.so.0 gbm=owned dri=zink zink_policy=drirc:powervr kmsro=present zink_renderonly=present kmsro_evidence=${kmsro_evidence} vulkan=powervr vulkan_manifests=${rootfs_icd_count} vulkan_json=/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json xwayland=glamor-capable debian_mesa=absent"
