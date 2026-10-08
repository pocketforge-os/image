#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${root}/scripts/install-platform-runtime.sh"
dockerfile="${root}/build/Dockerfile.pf"
builder="${root}/build/platform-runtimes/steamlink-ffmpeg59/v1/build.sh"
scratch="$(mktemp -d)"
cleanup() {
    chmod -R u+w "${scratch}"
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

make_fixture() {
    local producer=$1
    local runtime="${producer}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1"
    local source="${producer}/usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1"
    mkdir -p "${runtime}/lib/aarch64-linux-gnu" "${runtime}/metadata" "${source}"
    while read -r name soname version; do
        printf '%s\n' "${name}-${version}" > "${runtime}/lib/aarch64-linux-gnu/${name}.so.${version}"
        chmod 0444 "${runtime}/lib/aarch64-linux-gnu/${name}.so.${version}"
        ln -s "${name}.so.${version}" "${runtime}/lib/aarch64-linux-gnu/${name}.so.${soname}"
    done <<'EOF'
libavcodec 59 59.37.100
libavutil 57 57.28.100
libswresample 4 4.7.100
EOF
    for full in "${runtime}/lib/aarch64-linux-gnu"/*.so.*.*.*; do
        base="$(basename "${full}")"
        printf '%s  %s\n' "$(sha256sum "${full}" | cut -d' ' -f1)" "${base}"
    done | sort > "${runtime}/metadata/libraries.sha256"
    printf '%s\n' 'schema_version = 1' 'runtime_id = "steamlink-ffmpeg59"' \
        > "${runtime}/metadata/runtime.toml"
    printf '%s\n' source > "${source}/README.md"
    (cd "${producer}" && find \
        usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1 \
        usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1 \
        -type f ! -path '*/metadata/payload.sha256' -print0 \
        | LC_ALL=C sort -z | xargs -0 sha256sum) > "${runtime}/metadata/payload.sha256"
    chmod -R a-w "${producer}"
}

producer="${scratch}/producer"
rootfs="${scratch}/rootfs"
make_fixture "${producer}"
mkdir -p "${rootfs}/usr/lib/aarch64-linux-gnu"
printf '%s\n' system-ffmpeg > "${rootfs}/usr/lib/aarch64-linux-gnu/libavcodec.so.59.37.100"
system_before="$(sha256sum "${rootfs}/usr/lib/aarch64-linux-gnu/libavcodec.so.59.37.100")"
mkdir -p "${rootfs}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v0"
printf '%s\n' rollback > "${rootfs}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v0/sentinel"
before="$(sha256sum "${rootfs}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v0/sentinel")"
"${installer}" "${producer}" "${rootfs}"
after="$(sha256sum "${rootfs}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v0/sentinel")"
[ "${before}" = "${after}" ]
[ "${system_before}" = "$(sha256sum "${rootfs}/usr/lib/aarch64-linux-gnu/libavcodec.so.59.37.100")" ]
[ ! -e "${rootfs}/etc/ld.so.conf.d/steamlink-ffmpeg59.conf" ]

if "${installer}" "${producer}" "${rootfs}" 2>"${scratch}/collision.err"; then
    echo 'FAIL: collision was accepted' >&2; exit 1
fi
grep -F 'collision at' "${scratch}/collision.err" >/dev/null

# A source-side collision is found in preflight, before the runtime half is
# copied, so installation is transactional with respect to validation failure.
source_collision_root="${scratch}/source-collision-root"
mkdir -p "${source_collision_root}/usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1"
printf '%s\n' occupied > "${source_collision_root}/usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1/sentinel"
if "${installer}" "${producer}" "${source_collision_root}" 2>"${scratch}/source-collision.err"; then
    echo 'FAIL: source collision was accepted' >&2; exit 1
fi
grep -F 'collision at /usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1' \
    "${scratch}/source-collision.err" >/dev/null
[ ! -e "${source_collision_root}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1" ]

bad="${scratch}/bad"
make_fixture "${bad}"
chmod u+w "${bad}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1/metadata/runtime.toml"
if "${installer}" "${bad}" "${scratch}/bad-root" 2>"${scratch}/writable.err"; then
    echo 'FAIL: writable producer was accepted' >&2; exit 1
fi
grep -F 'writable producer file rejected' "${scratch}/writable.err" >/dev/null

unsafe_link="${scratch}/unsafe-link"
make_fixture "${unsafe_link}"
unsafe_libdir="${unsafe_link}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1/lib/aarch64-linux-gnu"
chmod u+w "${unsafe_libdir}"
ln -s ../escape "${unsafe_libdir}/escape.so"
chmod a-w "${unsafe_libdir}"
if "${installer}" "${unsafe_link}" "${scratch}/unsafe-root" 2>"${scratch}/unsafe.err"; then
    echo 'FAIL: unsafe producer symlink was accepted' >&2; exit 1
fi
grep -F 'unsafe symlink rejected' "${scratch}/unsafe.err" >/dev/null
[ ! -e "${scratch}/unsafe-root/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1" ]

symlink_root="${scratch}/symlink-root"
mkdir -p "${symlink_root}/usr/lib" "${scratch}/outside"
ln -s "${scratch}/outside" "${symlink_root}/usr/lib/pocketforge"
if "${installer}" "${producer}" "${symlink_root}" 2>"${scratch}/ancestor.err"; then
    echo 'FAIL: symlinked destination ancestor was accepted' >&2; exit 1
fi
grep -F 'symlinked destination ancestor rejected' "${scratch}/ancestor.err" >/dev/null
[ ! -e "${scratch}/outside/platform-runtimes/steamlink-ffmpeg59/v1" ]

corrupt_source="${scratch}/corrupt-source"
make_fixture "${corrupt_source}"
corrupt_readme="${corrupt_source}/usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1/README.md"
chmod u+w "${corrupt_readme}"
printf '%s\n' corrupted > "${corrupt_readme}"
chmod a-w "${corrupt_readme}"
if "${installer}" "${corrupt_source}" "${scratch}/corrupt-root" 2>"${scratch}/corrupt.err"; then
    echo 'FAIL: corrupt corresponding source was accepted' >&2; exit 1
fi
grep -F 'payload hash verification failed' "${scratch}/corrupt.err" >/dev/null
[ ! -e "${scratch}/corrupt-root/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1" ]

bad_library_manifest="${scratch}/bad-library-manifest"
make_fixture "${bad_library_manifest}"
bad_runtime="${bad_library_manifest}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1"
chmod u+w "${bad_runtime}/metadata/libraries.sha256" \
    "${bad_runtime}/metadata/payload.sha256"
{
    printf '%064d  libavcodec.so.59.37.100\n' 0
    for library in libavutil.so.57.28.100 libswresample.so.4.7.100; do
        printf '%s  %s\n' \
            "$(sha256sum "${bad_runtime}/lib/aarch64-linux-gnu/${library}" | cut -d' ' -f1)" \
            "${library}"
    done
} > "${bad_runtime}/metadata/libraries.sha256"
(cd "${bad_library_manifest}" && find \
    usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1 \
    usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1 \
    -type f ! -path '*/metadata/payload.sha256' -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum) > "${bad_runtime}/metadata/payload.sha256"
chmod -R a-w "${bad_library_manifest}"
bad_library_root="${scratch}/bad-library-root"
if "${installer}" "${bad_library_manifest}" "${bad_library_root}" \
        2>"${scratch}/bad-library.err"; then
    echo 'FAIL: payload-authenticated malformed library manifest was accepted' >&2
    exit 1
fi
grep -F 'library hash verification failed' "${scratch}/bad-library.err" >/dev/null
[ ! -e "${bad_library_root}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1" ]
[ ! -e "${bad_library_root}/usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1" ]

missing_libraries="${scratch}/missing-libraries"
make_fixture "${missing_libraries}"
missing_runtime="${missing_libraries}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1"
missing_libdir="${missing_runtime}/lib/aarch64-linux-gnu"
chmod u+w "${missing_libdir}" "${missing_runtime}/metadata/libraries.sha256" \
    "${missing_runtime}/metadata/payload.sha256"
rm "${missing_libdir}"/*.so.*.*.*
printf '%s\n' unrelated > "${missing_libdir}/unrelated.txt"
(cd "${missing_libdir}" && sha256sum unrelated.txt) \
    > "${missing_runtime}/metadata/libraries.sha256"
(cd "${missing_libraries}" && find \
    usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1 \
    usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1 \
    -type f ! -path '*/metadata/payload.sha256' -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum) > "${missing_runtime}/metadata/payload.sha256"
chmod -R a-w "${missing_libraries}"
missing_libraries_root="${scratch}/missing-libraries-root"
if "${installer}" "${missing_libraries}" "${missing_libraries_root}" \
        2>"${scratch}/missing-libraries.err"; then
    echo 'FAIL: payload-authenticated missing runtime libraries were accepted' >&2
    exit 1
fi
grep -F 'unexpected library manifest entry unrelated.txt' \
    "${scratch}/missing-libraries.err" >/dev/null
[ ! -e "${missing_libraries_root}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1" ]
[ ! -e "${missing_libraries_root}/usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1" ]

symlinked_runtime="${scratch}/symlinked-runtime"
make_fixture "${symlinked_runtime}"
symlinked_runtime_parent="${symlinked_runtime}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59"
chmod u+w "${symlinked_runtime_parent}"
mv "${symlinked_runtime_parent}/v1" "${symlinked_runtime_parent}/alternate"
ln -s alternate "${symlinked_runtime_parent}/v1"
chmod a-w "${symlinked_runtime_parent}"
symlinked_runtime_root="${scratch}/symlinked-runtime-root"
if "${installer}" "${symlinked_runtime}" "${symlinked_runtime_root}" \
        2>"${scratch}/symlinked-runtime.err"; then
    echo 'FAIL: symlinked runtime payload root was accepted' >&2
    exit 1
fi
grep -F 'runtime payload missing or symlinked' "${scratch}/symlinked-runtime.err" >/dev/null
[ ! -e "${symlinked_runtime_root}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1" ]
[ ! -e "${symlinked_runtime_root}/usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1" ]

symlinked_source="${scratch}/symlinked-source"
make_fixture "${symlinked_source}"
symlinked_source_parent="${symlinked_source}/usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59"
chmod u+w "${symlinked_source_parent}"
mv "${symlinked_source_parent}/v1" "${symlinked_source_parent}/alternate"
ln -s alternate "${symlinked_source_parent}/v1"
chmod a-w "${symlinked_source_parent}"
symlinked_source_root="${scratch}/symlinked-source-root"
if "${installer}" "${symlinked_source}" "${symlinked_source_root}" \
        2>"${scratch}/symlinked-source.err"; then
    echo 'FAIL: symlinked corresponding-source root was accepted' >&2
    exit 1
fi
grep -F 'corresponding source missing or symlinked' "${scratch}/symlinked-source.err" >/dev/null
[ ! -e "${symlinked_source_root}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1" ]
[ ! -e "${symlinked_source_root}/usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1" ]

mkdir -p "${scratch}/not-shipped" "${scratch}/empty-root"
printf '%s\n' 'mode=not-shipped' > "${scratch}/not-shipped/NOT-SHIPPED"
"${installer}" "${scratch}/not-shipped" "${scratch}/empty-root" not-shipped
"${installer}" "${scratch}/missing" "${scratch}/empty-root" not-shipped
if "${installer}" "${scratch}/missing" "${scratch}/empty-root" v1 \
        2>"${scratch}/selected-missing.err"; then
    echo 'FAIL: selected v1 accepted a missing producer' >&2; exit 1
fi
grep -F 'runtime payload missing' "${scratch}/selected-missing.err" >/dev/null
if "${installer}" "${scratch}/not-shipped" "${scratch}/empty-root" v1 \
        2>"${scratch}/selector-mismatch.err"; then
    echo 'FAIL: v1 accepted a NOT-SHIPPED producer' >&2; exit 1
fi
grep -F 'v1 producer contains NOT-SHIPPED marker' "${scratch}/selector-mismatch.err" >/dev/null

grep -F 'AS platform-runtime-steamlink-ffmpeg59-v1' "${dockerfile}" >/dev/null
grep -F 'AS platform-runtime-steamlink-ffmpeg59-not-shipped' "${dockerfile}" >/dev/null
# Literal Dockerfile interpolation must remain unexpanded here.
# shellcheck disable=SC2016
selector='FROM platform-runtime-steamlink-ffmpeg59-${PF_STEAMLINK_FFMPEG59_MODE} AS platform-runtime-steamlink-ffmpeg59'
grep -F "${selector}" "${dockerfile}" >/dev/null
grep -F 'AS platform-runtime-steamlink-ffmpeg59-export' "${dockerfile}" >/dev/null
grep -F 'COPY --from=platform-runtime-steamlink-ffmpeg59 /out /' "${dockerfile}" >/dev/null
grep -F 'COPY --from=platform-runtime-steamlink-ffmpeg59 /out /work/platform-runtime' "${dockerfile}" >/dev/null
# shellcheck disable=SC2016
grep -F 'PF_STEAMLINK_FFMPEG59_MODE="${PF_STEAMLINK_FFMPEG59_MODE}"' "${dockerfile}" >/dev/null
if find "${root}/build/platform-runtimes/steamlink-ffmpeg59" \
        \( -name app.toml -o -name '*.service' \) -print | grep -q .; then
    echo 'FAIL: platform payload duplicated app-runtime ownership' >&2; exit 1
fi
grep -F 'work=/work/pf-steamlink-ffmpeg59-v1' "${builder}" >/dev/null
# These are literal source patterns, not commands for this test shell.
# shellcheck disable=SC2016
random_work='work="$(mktemp -d)"'
if grep -F "${random_work}" "${builder}" >/dev/null; then
    echo 'FAIL: random build path reintroduced' >&2; exit 1
fi
grep -F '/tmp/ffconf.XXXXXXXX' "${builder}" >/dev/null
# shellcheck disable=SC2016
awk_length='length($0) == 6'
grep -F "${awk_length}" "${builder}" >/dev/null

# Exercise the producer's fail-closed lock admission before any source fetch.
# A matching platform/image lock advances to the deliberately absent receipt,
# while the previous platform pin fails first with PF_FFMPEG_UAPI_SHA drift.
mkdir -p "${scratch}/contract-kernel"
run_contract_builder() {
    local platform_uapi_sha=$1
    (
        # shellcheck disable=SC1091
        . "${root}/build/platform-runtimes/steamlink-ffmpeg59/v1/source.lock"
        export SOURCE_DATE_EPOCH=0
        export PF_FFMPEG_DEBIAN_VERSION="${FFMPEG_DEBIAN_VERSION}"
        export PF_FFMPEG_DSC_SHA256="${FFMPEG_DSC_SHA256}"
        export PF_FFMPEG_ORIG_SHA256="${FFMPEG_ORIG_SHA256}"
        export PF_FFMPEG_ORIG_ASC_SHA256="${FFMPEG_ORIG_ASC_SHA256}"
        export PF_FFMPEG_DEBIAN_SHA256="${FFMPEG_DEBIAN_SHA256}"
        export PF_FFMPEG_PATCH_SERIES_SHA256="${PATCH_SERIES_SHA256}"
        export PF_FFMPEG_UAPI_SHA="${platform_uapi_sha}"
        "${builder}" "${scratch}/contract-out" "${scratch}/contract-kernel"
    )
}

previous_uapi_sha=a65b6107b0ab0938a80cee810d103e759da8f8c2
if run_contract_builder "${previous_uapi_sha}" \
        >"${scratch}/stale-uapi.log" 2>&1; then
    echo 'FAIL: previous platform UAPI pin was accepted' >&2
    exit 1
fi
grep -Fxq \
    "steamlink-ffmpeg59: PF_FFMPEG_UAPI_SHA drift: got '${previous_uapi_sha}', want '4684f03b7630fd032bea2ddaac40e2d2a034ab16'" \
    "${scratch}/stale-uapi.log"
if grep -Fq 'kernel UAPI source receipt missing' "${scratch}/stale-uapi.log"; then
    echo 'FAIL: stale platform UAPI pin reached the kernel receipt gate' >&2
    exit 1
fi

if run_contract_builder 4684f03b7630fd032bea2ddaac40e2d2a034ab16 \
        >"${scratch}/contract.log" 2>&1; then
    echo 'FAIL: lock admission reached a missing kernel receipt without failing' >&2
    exit 1
fi
if ! grep -Fxq 'steamlink-ffmpeg59: kernel UAPI source receipt missing' \
        "${scratch}/contract.log"; then
    cat "${scratch}/contract.log" >&2
    echo 'FAIL: platform runtime UAPI lock did not reach the receipt gate' >&2
    exit 1
fi

echo 'PASS: steamlink FFmpeg 59 runtime isolation/collision/rollback contract'
