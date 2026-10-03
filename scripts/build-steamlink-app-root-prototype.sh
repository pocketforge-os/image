#!/usr/bin/env bash
set -euo pipefail

# Offline QEMU-user-mode prototype builder for tsp-mc9m.41.996.1.  Vendor
# bytes remain in the caller-selected output directory and never enter git.

vendor_dir=/home/matt/recovery/steamlink-vendor/rpi-bookworm-arm64-1.3.32.316
qemu_dir=/home/matt/recovery/steamlink-qemu/rb2g
output=

usage() {
    printf 'usage: %s --output DIR [--vendor-dir DIR] [--qemu-dir DIR]\n' "$0" >&2
    exit 64
}

while (($#)); do
    case "$1" in
        --output) output=${2-}; shift 2 ;;
        --vendor-dir) vendor_dir=${2-}; shift 2 ;;
        --qemu-dir) qemu_dir=${2-}; shift 2 ;;
        *) usage ;;
    esac
done
[[ -n "${output}" ]] || usage

archive="${vendor_dir}/steamlink-rpi-bookworm-arm64-1.3.32.316.tar.gz"
signature="${archive}.sig"
source_note="${vendor_dir}/SOURCE.txt"
vendor_sums="${vendor_dir}/SHA256SUMS"
sysroot="${qemu_dir}/sysroot"
loader_list="${qemu_dir}/runtime-state/loader-list.txt"
image_source="${qemu_dir}/ImageSource.json"
raw_image="${qemu_dir}/Image.img"
compressed_image="${qemu_dir}/Image.img.xz"
userdata="${qemu_dir}/parts/4.userdata.img"

archive_sha=6e1e431265da01b85a7a2fb2ef652f822eb16c5b78aca03f0d0d500dc29b93d3
signature_sha=a88e79b66550f7740158f2d80385bfd794706683b023cf0ec28dc4e2cf608868
source_note_sha=c69a789967a2383fdb8fc64db67c984b164e8e320523eebf2474cbca74fbeeba
vendor_sums_sha=5b5889991d4f84cae076f878b886f692f223cca062fca7393a7af9ea1ac9b926
descriptor_sha=6e39f7de189dcd009f6cf34e7c2c1784cddf4e02532e68fa8f46bd5396d54e2f
compressed_sha=8d01225721a7a276a241e273f748a1d97a9e59b1abad1d40b50af767bc13d49c
raw_sha=5a8eb206755d3e3d1fc41f190396d04e3fb6c6ededf8afccf7a280944bb456d7
userdata_sha=ea8d2977c5408168e0e5457d66423c73ba9c7be55ce850a991a43cbe3d8fd2cb
loader_list_sha=ee60863ae48260e8703b870a0def98e9ffbaa07a784dd6af822060d5503098c5
sysroot_subset_sha=4f20616be1dcdba99e5140b3781197f101b26a1542321242c4caad2e436f08a9

for tool in awk basename chmod cp dirname du find grep mkdir mktemp mksquashfs \
            sha256sum sort stat tar touch xargs; do
    command -v "${tool}" >/dev/null || {
        printf 'FATAL: required tool is unavailable: %s\n' "${tool}" >&2
        exit 69
    }
done
for input in "${archive}" "${signature}" "${source_note}" "${vendor_sums}" \
             "${loader_list}" "${image_source}" "${raw_image}" \
             "${compressed_image}" "${userdata}"; do
    [[ -f "${input}" ]] || {
        printf 'FATAL: preserved input is missing: %s\n' "${input}" >&2
        exit 66
    }
done
[[ -d "${sysroot}" ]] || {
    printf 'FATAL: preserved sysroot is missing: %s\n' "${sysroot}" >&2
    exit 66
}
if [[ -e "${output}" ]] && find "${output}" -mindepth 1 -print -quit | grep -q .; then
    printf 'FATAL: output directory is not empty: %s\n' "${output}" >&2
    exit 73
fi
mkdir -p "${output}"
output="$(cd "${output}" && pwd)"

verify() {
    local expected=$1 path=$2 actual
    actual="$(sha256sum "${path}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]] || {
        printf 'FATAL: digest mismatch for %s: expected %s, got %s\n' \
            "${path}" "${expected}" "${actual}" >&2
        exit 65
    }
}

verify "${archive_sha}" "${archive}"
verify "${signature_sha}" "${signature}"
verify "${source_note_sha}" "${source_note}"
verify "${vendor_sums_sha}" "${vendor_sums}"
verify "${descriptor_sha}" "${image_source}"
verify "${compressed_sha}" "${compressed_image}"
verify "${raw_sha}" "${raw_image}"
verify "${userdata_sha}" "${userdata}"
verify "${loader_list_sha}" "${loader_list}"
grep -Fqx "${archive_sha}  $(basename "${archive}")" "${vendor_sums}" || {
    printf 'FATAL: archive digest is absent from preserved SHA256SUMS\n' >&2
    exit 65
}
grep -F 'The key is not independently trust-certified' "${source_note}" >/dev/null || {
    printf 'FATAL: preserved vendor trust caveat is absent\n' >&2
    exit 65
}

scratch="$(mktemp -d -t pf-steamlink-root.XXXXXXXX)"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT INT TERM

tar --extract --gzip --file "${archive}" --directory "${scratch}" --no-same-owner
vendor="${scratch}/steamlink"
[[ -x "${vendor}/bin/shell" ]] || {
    printf 'FATAL: vendor archive has no executable steamlink/bin/shell\n' >&2
    exit 65
}
dependency_count="$(awk 'NF && $1 !~ /^#/ && index($0, "=") == 0 { count++ } END { print count + 0 }' \
    "${vendor}/steamlinkdeps.txt")"
[[ "${dependency_count}" == 49 ]] || {
    printf 'FATAL: expected 49 vendor package entries, found %s\n' "${dependency_count}" >&2
    exit 65
}

app_root="${output}/app-root"
platform_root="${output}/platform-runtime"
app_dir="${app_root}/opt/pocketforge/apps/org.pocketforge.steamlink"
mkdir -p "${app_dir}" "${platform_root}" \
    "${app_root}/run/pocketforge/platform-runtime" \
    "${app_root}/var/lib/pocketforge/apps/org.pocketforge.steamlink" \
    "${app_root}/etc" "${app_root}/tmp" "${app_root}/proc" "${app_root}/dev"
cp -a "${vendor}/." "${app_dir}/"

# Vendor archives use buildbot-only 0600/0700 modes.  Preserve bytes while
# making the derivative root readable/executable by the production gamer uid.
while IFS= read -r -d '' path; do chmod 0755 "${path}"; done < <(find "${app_dir}" -type d -print0)
while IFS= read -r -d '' path; do
    if [[ -x "${path}" ]]; then chmod 0755 "${path}"; else chmod 0644 "${path}"; fi
done < <(find "${app_dir}" -type f -print0)

copy_file() {
    local source=$1 destination_root=$2 relative destination
    relative=${source#"${sysroot}/"}
    [[ "${relative}" != "${source}" && "${relative}" != *'..'* ]] || {
        printf 'FATAL: loader path escaped the preserved sysroot: %s\n' "${source}" >&2
        exit 65
    }
    destination="${destination_root}/${relative}"
    mkdir -p "$(dirname "${destination}")"
    cp -L --preserve=mode,timestamps "${source}" "${destination}"
}

is_platform_library() {
    [[ "$1" == "${sysroot}/usr/local/lib/"* ]] && return 0
    case "$(basename "$1")" in
        libavcodec.so.*|libavutil.so.*|libswresample.so.*|libdrm.so.*|libEGL.so.*|\
        libepoxy.so.*|libgbm.so.*|libGLES*.so.*|libGL*.so.*|libwayland-client.so.*|\
        libwayland-egl.so.*) return 0 ;;
        *) return 1 ;;
    esac
}

mapfile -t loader_paths < <(
    awk -v prefix="${sysroot}/" '{
        for (field = 1; field <= NF; field++) {
            if (index($field, prefix) == 1) {
                sub(/\)$/, "", $field)
                print $field
            }
        }
    }' "${loader_list}" | sort -u
)
[[ ${#loader_paths[@]} -gt 0 ]] || {
    printf 'FATAL: preserved loader closure has no sysroot paths\n' >&2
    exit 65
}

data_directories=(etc/fonts usr/share/fonts usr/share/fontconfig)
data_files=(
    etc/group
    etc/host.conf
    etc/hosts
    etc/nsswitch.conf
    etc/passwd
    etc/gai.conf
    etc/ssl/openssl.cnf
    etc/ssl/certs/ca-certificates.crt
)
mapfile -t sysroot_input_paths < <(
    {
        printf '%s\n' "${loader_paths[@]}" "${sysroot}/lib/ld-linux-aarch64.so.1"
        for relative in "${data_directories[@]}"; do
            [[ -e "${sysroot}/${relative}" ]] && find -L "${sysroot}/${relative}" -type f
        done
        for relative in "${data_files[@]}" etc/.resolv.conf.systemd-resolved.bak; do
            [[ -f "${sysroot}/${relative}" ]] && printf '%s\n' "${sysroot}/${relative}"
        done
    } | sort -u
)
sysroot_input_manifest="${scratch}/sysroot-input.manifest"
for source in "${sysroot_input_paths[@]}"; do
    [[ -f "${source}" ]] || {
        printf 'FATAL: pinned sysroot subset member is missing: %s\n' "${source}" >&2
        exit 65
    }
    relative=${source#"${sysroot}/"}
    printf '%s  %s  %s\n' \
        "$(stat -Lc %a "${source}")" \
        "$(sha256sum "${source}" | awk '{print $1}')" \
        "${relative}"
done > "${sysroot_input_manifest}"
verify "${sysroot_subset_sha}" "${sysroot_input_manifest}"

for source in "${loader_paths[@]}"; do
    [[ -f "${source}" ]] || {
        printf 'FATAL: loader closure member is missing: %s\n' "${source}" >&2
        exit 65
    }
    if is_platform_library "${source}"; then
        copy_file "${source}" "${platform_root}"
    else
        copy_file "${source}" "${app_root}"
    fi
done
# ELF PT_INTERP names /lib/ld-linux-aarch64.so.1.  Recursive ldd records its
# resolved target, so preserve the public interpreter path explicitly too.
copy_file "${sysroot}/lib/ld-linux-aarch64.so.1" "${app_root}"

# Runtime data is copied from the same pinned image root; no apt/network/host
# distro files enter the artifact.  resolv.conf is a regular mount target for
# the host-development QEMU run and contains the preserved pre-resolved value.
for relative in "${data_directories[@]}"; do
    [[ -e "${sysroot}/${relative}" ]] || continue
    mkdir -p "${app_root}/$(dirname "${relative}")"
    cp -aL "${sysroot}/${relative}" "${app_root}/${relative}"
done
for relative in "${data_files[@]}"; do
    [[ -f "${sysroot}/${relative}" ]] && copy_file "${sysroot}/${relative}" "${app_root}"
done
cp -L --preserve=mode,timestamps "${sysroot}/etc/.resolv.conf.systemd-resolved.bak" \
    "${app_root}/etc/resolv.conf"

# Reproducible derivative: fixed mtimes and a single-threaded deterministic
# squashfs.  Ownership in the image is normalized with -all-root.
while IFS= read -r -d '' path; do chmod 0755 "${path}"; done < <(
    find "${app_root}" "${platform_root}" -type d -print0
)
while IFS= read -r -d '' path; do
    if [[ -x "${path}" ]]; then chmod 0755 "${path}"; else chmod 0644 "${path}"; fi
done < <(find "${app_root}" "${platform_root}" -type f -print0)
find "${app_root}" "${platform_root}" -print0 | sort -z | \
    xargs -0 touch -h --date='@0'

platform_manifest="${output}/platform-runtime.manifest"
while IFS= read -r -d '' path; do
    relative=${path#"${platform_root}/"}
    printf '%s  %s\n' "$(sha256sum "${path}" | awk '{print $1}')" "${relative}"
done < <(find "${platform_root}" -type f -print0 | sort -z) > "${platform_manifest}"
platform_sha="$(sha256sum "${platform_manifest}" | awk '{print $1}')"

root_image="${output}/steam-link.root.raw"
mksquashfs "${app_root}" "${root_image}" -noappend -all-root -no-xattrs \
    -all-time 0 -mkfs-time 0 -comp zstd -Xcompression-level 15 \
    -processors 1 -no-progress >/dev/null
root_sha="$(sha256sum "${root_image}" | awk '{print $1}')"

app_toml="${output}/app.toml"
printf '%s\n' \
    '[app]' \
    'id = "org.pocketforge.steamlink"' \
    'name = "Steam Link"' \
    'version = "1.3.32.316"' \
    'category = "stream"' \
    'use = ["audio", "input", "vibration", "video-decode"]' \
    '' \
    '[runtime]' \
    'family = "pocketforge/a133-powervr"' \
    'abi = "1"' \
    'platform-version = "20"' \
    '' \
    '[runtime.root]' \
    'schema = 1' \
    'format = "squashfs"' \
    "digest = \"sha256:${root_sha}\"" \
    'platform-runtime = "pocketforge/bookworm-aarch64"' \
    'platform-runtime-abi = "1"' \
    "platform-runtime-version = \"sha256:${platform_sha}\"" \
    'library-paths = ["lib", "Qt-5.14.1/lib"]' \
    '' \
    '[launch]' \
    'exec = "bin/shell"' \
    'needs_network = true' \
    'takes_display = true' \
    'audio = true' > "${app_toml}"

receipt="${output}/prototype.receipt"
printf '%s\n' \
    'schema=pocketforge.steamlink-app-root-prototype/v1' \
    'measurement_class=QEMU/host-development; not A133 performance' \
    "vendor_archive_sha256=${archive_sha}" \
    "vendor_signature_sha256=${signature_sha}" \
    "vendor_source_receipt_sha256=${source_note_sha}" \
    "vendor_sha256sums_sha256=${vendor_sums_sha}" \
    'vendor_signature_status=GOOD; key not independently trust-certified' \
    'vendor_dependency_entries=49' \
    "rb2g_descriptor_sha256=${descriptor_sha}" \
    "rb2g_compressed_sha256=${compressed_sha}" \
    "rb2g_raw_sha256=${raw_sha}" \
    "rb2g_userdata_sha256=${userdata_sha}" \
    "loader_closure_entries=${#loader_paths[@]}" \
    "loader_list_sha256=${loader_list_sha}" \
    "sysroot_subset_entries=${#sysroot_input_paths[@]}" \
    "sysroot_subset_manifest_sha256=${sysroot_subset_sha}" \
    "app_root_sha256=${root_sha}" \
    "platform_runtime_sha256=${platform_sha}" \
    "app_root_bytes=$(du -sb "${app_root}" | awk '{print $1}')" \
    "app_root_squashfs_bytes=$(stat -c %s "${root_image}")" \
    "platform_runtime_bytes=$(du -sb "${platform_root}" | awk '{print $1}')" \
    "vendor_archive_bytes=$(stat -c %s "${archive}")" > "${receipt}"

printf 'prototype=PASS output=%s app_root_sha256=%s platform_runtime_sha256=%s\n' \
    "${output}" "${root_sha}" "${platform_sha}"
