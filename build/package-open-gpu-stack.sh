#!/bin/sh
# Build the deterministic, file-owning Debian provider for the open GPU stack.
set -eu

if [ "$#" -ne 5 ]; then
    echo 'usage: package-open-gpu-stack.sh PRODUCER PROBE CONTROL SOURCE_SHA OUTPUT_DEB' >&2
    exit 2
fi

producer=$1
probe=$2
control=$3
source_sha=$4
output_deb=$5
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set}"

case "$source_sha" in
    *[!0-9a-f]*|'') echo "invalid gpu-um-tsp source SHA: $source_sha" >&2; exit 2 ;;
esac
[ "${#source_sha}" -eq 40 ] || {
    echo "gpu-um-tsp source SHA must contain 40 hex characters: $source_sha" >&2
    exit 2
}
[ -d "$producer/usr/local" ] || {
    echo "gpu-um-tsp install tree is missing: $producer/usr/local" >&2
    exit 1
}
[ -f "$producer/.pf-gpu-um-provenance" ] || {
    echo "gpu-um-tsp provenance is missing: $producer/.pf-gpu-um-provenance" >&2
    exit 1
}
[ -f "$producer/.pf-gpu-um-build-options.json" ] || {
    echo "gpu-um-tsp Meson option evidence is missing: $producer/.pf-gpu-um-build-options.json" >&2
    exit 1
}
[ -x "$probe" ] || { echo "open GPU probe is missing: $probe" >&2; exit 1; }
[ -f "$control" ] || { echo "provider control template is missing: $control" >&2; exit 1; }

for artifact in \
    libEGL_mesa.so.0 \
    libGLX_mesa.so.0 \
    libgbm.so.1 \
    libgallium_dri.so \
    libvulkan_powervr_mesa.so; do
    [ -e "$producer/usr/local/lib/$artifact" ] || {
        echo "required gpu-um-tsp provider artifact is missing: usr/local/lib/$artifact" >&2
        exit 1
    }
done

short_sha=$(printf '%.12s' "$source_sha")
mesa_pc="$producer/usr/local/lib/pkgconfig/dri.pc"
[ -f "$mesa_pc" ] || { echo "Mesa version evidence is missing: $mesa_pc" >&2; exit 1; }
[ "$(grep -Ec '^Version:[[:space:]]*[^[:space:]]+[[:space:]]*$' "$mesa_pc")" -eq 1 ] || {
    echo "Mesa version evidence must contain exactly one Version field: $mesa_pc" >&2
    exit 1
}
mesa_version=$(sed -n 's/^Version:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' "$mesa_pc")
printf '%s\n' "$mesa_version" | grep -Eq '^[0-9][0-9A-Za-z.+~:-]*$' || {
    echo "invalid Mesa version for Debian package: $mesa_version" >&2
    exit 1
}
provider_version="1:${mesa_version}+pf.${short_sha}"
stage=$(mktemp -d "${TMPDIR:-/tmp}/pocketforge-open-gpu-stack.XXXXXX")
trap 'find "$stage" -mindepth 1 -delete; rmdir "$stage"' EXIT

chmod 0755 "$stage"
install -d -m 0755 "$stage/DEBIAN" "$stage/usr"
sed "s/@PROVIDER_VERSION@/${provider_version}/g" "$control" \
    >"$stage/DEBIAN/control"
grep -F '@PROVIDER_VERSION@' "$stage/DEBIAN/control" >/dev/null && {
    echo 'unexpanded provider version placeholder' >&2
    exit 1
}

# Preserve Mesa's complete installed /usr/local tree byte-for-byte. The one
# exception is GLVND's vendor manifest: normalize it into the system discovery
# directory below so the image has exactly one canonical route.
cp -a "$producer/usr/local" "$stage/usr/local"
if [ -d "$stage/usr/local/share/glvnd/egl_vendor.d" ]; then
    find "$stage/usr/local/share/glvnd/egl_vendor.d" -mindepth 1 \
        -maxdepth 1 -name '50_mesa.json' -delete
fi
# Vulkan's loader searches both /usr/local/share and /usr/share. Keep the
# producer manifest as the hash source, but package only the canonical system
# route below so one physical device is not enumerated twice.
if [ -d "$stage/usr/local/share/vulkan/icd.d" ]; then
    find "$stage/usr/local/share/vulkan/icd.d" -mindepth 1 \
        -maxdepth 1 -name 'powervr_mesa_icd.aarch64.json' -delete
fi

install -D -m 0644 "$producer/.pf-gpu-um-provenance" \
    "$stage/usr/share/pocketforge/gpu-um-mesa-provenance"
install -D -m 0644 "$producer/.pf-gpu-um-build-options.json" \
    "$stage/usr/share/pocketforge/gpu-um-mesa-build-options.json"
install -D -m 0755 "$probe" \
    "$stage/usr/lib/pocketforge/open-gpu-probe"

install -d -m 0755 "$stage/usr/share/glvnd/egl_vendor.d"
cat >"$stage/usr/share/glvnd/egl_vendor.d/50_mesa.json" <<'EOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "/usr/local/lib/libEGL_mesa.so.0"
    }
}
EOF

producer_icd="$producer/usr/local/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"
[ -f "$producer_icd" ] || {
    echo "PowerVR ICD manifest is missing: $producer_icd" >&2
    exit 1
}
install -D -m 0644 "$producer_icd" \
    "$stage/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json"

# dpkg-deb honors SOURCE_DATE_EPOCH; normalizing the staging mtimes also makes
# the data archive stable across two otherwise identical producer invocations.
find "$stage" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
dpkg-deb --build --root-owner-group "$stage" "$output_deb" >/dev/null
echo "open-gpu-provider-package=PASS version=${provider_version} source=${source_sha} output=${output_deb}"
