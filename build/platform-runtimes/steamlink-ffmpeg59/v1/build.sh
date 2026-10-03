#!/usr/bin/env bash
set -euo pipefail

definition_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The definition path is resolved relative to this script inside the staged
# image context; ShellCheck cannot follow that dynamic path.
# shellcheck disable=SC1091
. "${definition_dir}/source.lock"

die() { echo "steamlink-ffmpeg59: $*" >&2; exit 1; }

out="${1:?usage: build.sh OUT KERNEL_UAPI_TREE}"
kernel_tree="${2:?usage: build.sh OUT KERNEL_UAPI_TREE}"
# FFmpeg embeds its complete configure command in libavutil. A random build
# directory would therefore make all three linked libraries non-reproducible.
# This stage-private absolute path is fixed and fail-closed on a dirty caller.
work=/work/pf-steamlink-ffmpeg59-v1
[ ! -e "${work}" ] || die "fixed build directory already exists: ${work}"
mkdir "${work}"
trap 'rm -rf "${work}"' EXIT

require_equal() { [ "$2" = "$3" ] || die "$1 drift: got '$2', want '$3'"; }

# The platform lock owns the selected payload and repeats every external byte
# identity. The image source owns this fail-closed copy of the implementation
# contract so a mismatched candidate cannot silently build a different runtime.
require_equal PF_FFMPEG_DEBIAN_VERSION "${PF_FFMPEG_DEBIAN_VERSION:?}" "${FFMPEG_DEBIAN_VERSION}"
require_equal PF_FFMPEG_DSC_SHA256 "${PF_FFMPEG_DSC_SHA256:?}" "${FFMPEG_DSC_SHA256}"
require_equal PF_FFMPEG_ORIG_SHA256 "${PF_FFMPEG_ORIG_SHA256:?}" "${FFMPEG_ORIG_SHA256}"
require_equal PF_FFMPEG_ORIG_ASC_SHA256 "${PF_FFMPEG_ORIG_ASC_SHA256:?}" "${FFMPEG_ORIG_ASC_SHA256}"
require_equal PF_FFMPEG_DEBIAN_SHA256 "${PF_FFMPEG_DEBIAN_SHA256:?}" "${FFMPEG_DEBIAN_SHA256}"
require_equal PF_FFMPEG_PATCH_SERIES_SHA256 "${PF_FFMPEG_PATCH_SERIES_SHA256:?}" "${PATCH_SERIES_SHA256}"
require_equal PF_FFMPEG_UAPI_SHA "${PF_FFMPEG_UAPI_SHA:?}" "${KERNEL_UAPI_SHA}"

[ -f "${kernel_tree}/.pf-source-revision" ] || die "kernel UAPI source receipt missing"
require_equal kernel-uapi-receipt "$(cat "${kernel_tree}/.pf-source-revision")" "${KERNEL_UAPI_SHA}"

src_objects="${work}/source-objects"
mkdir -p "${src_objects}"
fetch_one() {
    local name=$1 size=$2 hash=$3
    curl --fail --location --proto '=https' --tlsv1.2 \
        --output "${src_objects}/${name}" "${FFMPEG_SNAPSHOT_BASE}/${name}"
    require_equal "${name} size" "$(stat -c%s "${src_objects}/${name}")" "${size}"
    require_equal "${name} sha256" "$(sha256sum "${src_objects}/${name}" | cut -d' ' -f1)" "${hash}"
}
fetch_one "${FFMPEG_DSC}" "${FFMPEG_DSC_SIZE}" "${FFMPEG_DSC_SHA256}"
fetch_one "${FFMPEG_ORIG}" "${FFMPEG_ORIG_SIZE}" "${FFMPEG_ORIG_SHA256}"
fetch_one "${FFMPEG_ORIG_ASC}" "${FFMPEG_ORIG_ASC_SIZE}" "${FFMPEG_ORIG_ASC_SHA256}"
fetch_one "${FFMPEG_DEBIAN}" "${FFMPEG_DEBIAN_SIZE}" "${FFMPEG_DEBIAN_SHA256}"

tar -xf "${src_objects}/${FFMPEG_ORIG}" -C "${work}"
src="${work}/ffmpeg-${FFMPEG_UPSTREAM_VERSION}"
tar -xf "${src_objects}/${FFMPEG_DEBIAN}" -C "${src}"
while IFS= read -r debian_patch; do
    case "${debian_patch}" in ''|'#'*) continue ;; esac
    patch -d "${src}" -p1 --batch --forward < "${src}/debian/patches/${debian_patch}"
done < "${src}/debian/patches/series"

cp -a "${src}" "${work}/stock"
for selected in 0001 0002 0003 0004 0009; do
    patch_file="${definition_dir}/patches/${selected}.patch"
    [ -f "${patch_file}" ] || die "selected patch missing: ${selected}"
    hash_var="PATCH_${selected}_SHA256"
    require_equal "selected patch ${selected} sha256" \
        "$(sha256sum "${patch_file}" | cut -d' ' -f1)" "${!hash_var}"
    patch -d "${src}" -p1 --batch --forward < "${patch_file}"
done

# Export only the exact kernel-7.2 userspace API used to compile the historical
# request code. Host headers follow via -idirafter and cannot override it.
make -C "${kernel_tree}" ARCH=arm64 headers_install INSTALL_HDR_PATH="${work}/uapi"

common_configure() {
    local tree=$1
    shift
    (cd "${tree}" && ./configure \
        --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu \
        --arch=aarch64 --target-os=linux --enable-cross-compile \
        --cross-prefix=aarch64-none-linux-gnu- --pkg-config=pkg-config \
        --sysroot=/opt/arm-10.3-2021.07/aarch64-none-linux-gnu/libc \
        --extra-cflags="-I${work}/uapi/include -idirafter /usr/include -idirafter /usr/include/aarch64-linux-gnu -ffile-prefix-map=${work}=." \
        --extra-ldflags='-B/usr/lib/aarch64-linux-gnu -L/usr/lib/aarch64-linux-gnu' \
        --enable-shared --disable-static --disable-programs --disable-doc --disable-debug \
        --disable-autodetect --enable-libdrm \
        --disable-avdevice --disable-avfilter --disable-avformat --disable-postproc --disable-swscale \
        "$@")
}

export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH is required}"
common_configure "${work}/stock"
common_configure "${src}" --enable-libudev --enable-v4l2-request
echo "steamlink-ffmpeg59: compiling stock comparator"
make --silent -C "${work}/stock" -j"$(nproc)"
echo "steamlink-ffmpeg59: compiling selected backport"
make --silent -C "${src}" -j"$(nproc)"

reports="${work}/reports"
mkdir -p "${reports}"
for lib in libavcodec/libavcodec.so.59 libavutil/libavutil.so.57 libswresample/libswresample.so.4; do
    report="${reports}/$(basename "${lib}").abidiff.txt"
    if abidiff --no-added-syms "${work}/stock/${lib}" "${src}/${lib}" > "${report}"; then
        abidiff_rc=0
    else
        abidiff_rc=$?
    fi
    case "${abidiff_rc}" in
        0) ;;
        # abidiff reports the additive av_buffer_pool_flush export in its status
        # even with --no-added-syms. An empty filtered report is therefore the
        # permitted additive-only result; export-set comparison below proves it.
        4) [ ! -s "${report}" ] || { cat "${report}" >&2; die "non-additive ABI delta for ${lib}"; } ;;
        *) cat "${report}" >&2; die "abidiff failed for ${lib} (status ${abidiff_rc})" ;;
    esac
done

defined_symbols() {
    readelf --wide --dyn-syms "$1" | awk '$7 != "UND" && ($5 == "GLOBAL" || $5 == "WEAK") {sub(/@.*/, "", $8); if ($8 != "") print $8}' | sort -u
}
for lib in libavcodec/libavcodec.so.59 libavutil/libavutil.so.57 libswresample/libswresample.so.4; do
    defined_symbols "${work}/stock/${lib}" > "${reports}/stock.$(basename "${lib}").exports"
    defined_symbols "${src}/${lib}" > "${reports}/patched.$(basename "${lib}").exports"
    if ! comm -23 "${reports}/stock.$(basename "${lib}").exports" \
            "${reports}/patched.$(basename "${lib}").exports" \
            > "${reports}/missing.$(basename "${lib}").exports"; then
        die "symbol comparison failed for ${lib}"
    fi
    [ ! -s "${reports}/missing.$(basename "${lib}").exports" ] \
        || die "patched export set is not a superset for ${lib}"
done

elf_contract() {
    local file=$1 expected_soname=$2 name needed max_glibc
    name="$(basename "${file}")"
    readelf -h "${file}" > "${reports}/${name}.elf-header.txt"
    grep -Eq 'Machine:[[:space:]]+AArch64' "${reports}/${name}.elf-header.txt" \
        || die "non-AArch64 runtime library: ${file}"
    readelf -d "${file}" > "${reports}/${name}.dynamic.txt"
    grep -Fq "(SONAME)" "${reports}/${name}.dynamic.txt" \
        || die "SONAME missing from ${file}"
    grep -Fq "[${expected_soname}]" "${reports}/${name}.dynamic.txt" \
        || die "SONAME drift in ${file}; expected ${expected_soname}"
    ! grep -Eq '\((RPATH|RUNPATH)\)' "${reports}/${name}.dynamic.txt" \
        || die "embedded loader path forbidden in ${file}"
    sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p' \
        "${reports}/${name}.dynamic.txt" > "${reports}/${name}.needed.txt"
    [ -s "${reports}/${name}.needed.txt" ] || die "empty dependency closure for ${file}"
    while IFS= read -r needed; do
        case "${needed}" in
            libavutil.so.57|libswresample.so.4|libdrm.so.2|libudev.so.1|libm.so.6|libc.so.6) ;;
            *) die "unexpected dependency ${needed} in ${file}" ;;
        esac
    done < "${reports}/${name}.needed.txt"
    max_glibc="$(readelf --version-info "${file}" | grep -o 'GLIBC_[0-9.]*' | sort -Vu | tail -1)"
    [ -n "${max_glibc}" ] || die "no GLIBC version requirements in ${file}"
    [ "$(printf '%s\n' "${max_glibc}" GLIBC_2.36 | sort -V | tail -1)" = GLIBC_2.36 ] \
        || die "${file} requires ${max_glibc}, newer than Bookworm GLIBC_2.36"
    printf 'max_glibc=%s\n' "${max_glibc}" > "${reports}/${name}.symbol-versions.txt"
}
elf_contract "${src}/libavcodec/libavcodec.so.59" libavcodec.so.59
elf_contract "${src}/libavutil/libavutil.so.57" libavutil.so.57
elf_contract "${src}/libswresample/libswresample.so.4" libswresample.so.4

# The ABI offsets are compile-time properties of the exact Debian headers. Use
# Debian's Bookworm cross driver for these test objects and the linked probes so
# their libc/startfiles match the target rootfs, not the older vendor sysroot.
aarch64-linux-gnu-gcc -I"${work}/stock" -c "${definition_dir}/layout.c" \
    -o "${work}/stock-layout.o"
aarch64-linux-gnu-gcc -I"${src}" -c "${definition_dir}/layout.c" \
    -o "${work}/patched-layout.o"

build_probe() {
    local tree=$1 output=$2
    aarch64-linux-gnu-gcc -I"${tree}" \
        "${definition_dir}/probe.c" -L"${tree}/libavcodec" -L"${tree}/libavutil" \
        -Wl,-rpath-link,"${tree}/libswresample" -lavcodec -lavutil -o "${output}"
}
build_probe "${work}/stock" "${work}/probe-red"
build_probe "${src}" "${work}/probe-green"
qemu-aarch64-static -L / \
    -E LD_LIBRARY_PATH="${work}/stock/libavcodec:${work}/stock/libavutil:${work}/stock/libswresample" \
    "${work}/probe-red" red | tee "${reports}/qemu-red.txt"
qemu-aarch64-static -L / \
    -E LD_LIBRARY_PATH="${src}/libavcodec:${src}/libavutil:${src}/libswresample" \
    "${work}/probe-green" green | tee "${reports}/qemu-green.txt"
grep -Eq '^RED request=0 drm-null=-[0-9]+ avcodec=3876196 avutil=3742820$' \
    "${reports}/qemu-red.txt" || die "stock RED evidence drift"
grep -Fxq 'GREEN request=1 drm-null=0 avcodec=3876196 avutil=3742820' \
    "${reports}/qemu-green.txt" || die "patched GREEN evidence drift"

dest="${out}/${RUNTIME_RELATIVE_PATH}"
libdir="${dest}/lib/aarch64-linux-gnu"
source_dest="${out}/usr/share/pocketforge/corresponding-source/${RUNTIME_ID}/${RUNTIME_REVISION}"
mkdir -p "${libdir}" "${source_dest}/patches" "${source_dest}/reports" "${dest}/metadata"
while read -r lib_name lib_version lib_soname; do
    # In-tree FFmpeg links the SONAME path; its install rule would rename that
    # byte-for-byte file to the full version. Reproduce only that deterministic
    # naming step inside the private payload (never a system prefix).
    install -m 0555 "${src}/${lib_name}/${lib_name}.so.${lib_soname}" \
        "${libdir}/${lib_name}.so.${lib_version}"
    ln -s "${lib_name}.so.${lib_version}" "${libdir}/${lib_name}.so.${lib_soname}"
done <<EOF
libavcodec ${FFMPEG_LIBAVCODEC_VERSION} 59
libavutil ${FFMPEG_LIBAVUTIL_VERSION} 57
libswresample ${FFMPEG_LIBSWRESAMPLE_VERSION} 4
EOF
cp -a "${src_objects}/." "${source_dest}/"
cp -a "${definition_dir}/patches/." "${source_dest}/patches/"
cp -a "${reports}/." "${source_dest}/reports/"
install -m 0444 "${definition_dir}/source.lock" "${source_dest}/source.lock"
install -m 0444 "${definition_dir}/README.md" "${source_dest}/README.md"
install -m 0444 "${src}/COPYING.LGPLv2.1" "${source_dest}/COPYING.LGPLv2.1"
install -m 0444 "${src}/COPYING.GPLv2" "${source_dest}/COPYING.GPLv2"
install -m 0444 "${src}/debian/copyright" "${source_dest}/debian-copyright"
normalize_config_log() {
    # configure's feature probes use random /tmp names. They have no bearing
    # on the admitted inputs or results; normalize only those known ephemera
    # while retaining the full commands, diagnostics, and selected features.
    sed -E \
        -e "s#${work}#.#g" \
        -e 's#/tmp/ffconf\.[[:alnum:]]+#/tmp/ffconf.XXXXXXXX#g' \
        -e 's#/tmp/cc[[:alnum:]]+\.[[:alnum:]]+#/tmp/ccXXXXXXXX.ext#g' \
        "$1" \
        | awk 'previous == "mktemp -u XXXXXX" && length($0) == 6 && $0 !~ /[^[:alnum:]]/ {$0 = "XXXXXX"} {print; previous = $0}'
}
normalize_config_log "${src}/ffbuild/config.log" \
    > "${source_dest}/reports/patched-config.log"
normalize_config_log "${work}/stock/ffbuild/config.log" \
    > "${source_dest}/reports/stock-config.log"

for full in "${libdir}"/*.so.*.*.*; do
    base="$(basename "${full}")"
    printf '%s  %s\n' "$(sha256sum "${full}" | cut -d' ' -f1)" "${base}"
done | sort > "${dest}/metadata/libraries.sha256"
cat > "${dest}/metadata/runtime.toml" <<EOF
schema_version = 1
runtime_id = "${RUNTIME_ID}"
revision = "${RUNTIME_REVISION}"
debian_source_version = "${FFMPEG_DEBIAN_VERSION}"
architecture = "aarch64"
libdir = "/${RUNTIME_RELATIVE_PATH}/lib/aarch64-linux-gnu"
kernel_uapi_repo = "${KERNEL_UAPI_REPO}"
kernel_uapi_sha = "${KERNEL_UAPI_SHA}"
patch_series_sha256 = "${PATCH_SERIES_SHA256}"
host_dependencies = ["libc.so.6", "libm.so.6", "libdrm.so.2", "libudev.so.1"]
EOF
find "${dest}" "${source_dest}" -type d -exec chmod 0555 {} +
find "${dest}" "${source_dest}" -type f -exec chmod a-w {} +
