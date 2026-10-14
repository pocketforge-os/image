#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prepare="${root}/scripts/prepare-cts-bundle.sh"
install_bundle="${root}/scripts/install-cts-bundle.sh"
verify_runtime="${root}/scripts/verify-cts-runtime-libraries.sh"
dockerfile="${root}/build/Dockerfile.pf"
rootfs_builder="${root}/scripts/build-rootfs.sh"
workflow="${root}/.github/workflows/hermetic-tests.yml"
makefile="${root}/Makefile"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-cts-image.XXXXXX")"

cleanup() {
    chmod -R u+w "${scratch}"
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

# Fixture CTS binaries are shell scripts, so the library names the runtime gate
# scans for are carried as literal lines: bare `lib*.so[.N]` lines stand in for
# dlopen literals, and `# NEEDED:` lines stand in for dynamic NEEDED entries
# (the stub readelf below turns them back into `readelf -d` output).
write_cts_binary() {
    local destination=$1 literals=$2
    {
        printf '#!/bin/sh\nexit 0\n'
        case "${literals}" in
            unversioned)
                printf '%s\n' libEGL.so libGLESv2.so libGL.so
                ;;
            versioned)
                printf '%s\n' libGLESv2.so.2 libEGL.so.1 libvulkan.so.1
                printf '%s\n' '# NEEDED: libEGL.so.1' '# NEEDED: libGL.so.1'
                ;;
            none)
                printf '%s\n' 'no library names here'
                ;;
            *)
                echo "FAIL: unknown fixture literal set: ${literals}" >&2
                exit 1
                ;;
        esac
    } > "${destination}"
    chmod 0755 "${destination}"
}

make_bundle() {
    local destination=$1 receipt_commit=$2 corrupt_member=$3
    local literals=${4:-unversioned}
    local tree="${scratch}/tree" bundle="${scratch}/tree/pf-deqp-gles"
    if [ -d "${tree}" ]; then
        find "${tree}" -mindepth 1 -delete
    fi
    mkdir -p "${bundle}/bin/gles2" "${bundle}/bin/gles3" \
        "${bundle}/bin/gles31" "${bundle}/bin/gl_cts" \
        "${bundle}/config" "${bundle}/mustpass" "${bundle}/receipts"

    for binary in deqp-gles2 deqp-gles3 deqp-gles31 glcts; do
        write_cts_binary "${bundle}/bin/${binary}" "${literals}"
    done
    printf '#!/bin/sh\nexit 0\n' > "${bundle}/run-chunks.sh"
    chmod 0755 "${bundle}/run-chunks.sh"
    printf 'fixture licence\n' > "${bundle}/LICENSE.VK-GL-CTS"
    printf 'fixture receipt\n' > "${bundle}/receipts/file.txt"
    printf 'fixture readelf receipt\n' > "${bundle}/receipts/readelf.txt"
    printf 'fixture=1\n' > "${bundle}/receipts/build-packages.tsv"

    printf '%s\n' \
        'source_tag=opengl-es-cts-3.2.14.1' \
        "source_commit=${receipt_commit}" \
        'source_archive_sha256=ce9f37f536373b6d616cdf854876477be79503999b655d90bb2e0e9483d502df' \
        'list_manifest_sha256=fixture-generated-below' \
        'list_count=13' \
        'mustpass_case_entries=124248' \
        'build_targets=deqp-gles2,deqp-gles3,deqp-gles31,glcts' \
        'deqp_target=surfaceless' \
        'surfaces=pbuffer:256x256,pbuffer:64x64' \
        'source_date_epoch=0' > "${bundle}/BUILD-RECEIPT.txt"

    printf '# name\tbinary\tfilename\tsha256\tcases\tgl_config\twidth\theight\tbase_seed\n' \
        > "${bundle}/config/lists.tsv"
    while read -r name binary cases config width height; do
        file="${bundle}/mustpass/${name}.txt"
        awk -v n="${cases}" -v prefix="${name}" \
            'BEGIN { for (i = 1; i <= n; i++) print prefix ".case." i }' > "${file}"
        digest="$(sha256sum "${file}" | cut -d' ' -f1)"
        printf '%s\t%s\t%s.txt\t%s\t%s\t%s\t%s\t%s\t1\n' \
            "${name}" "${binary}" "${name}" "${digest}" "${cases}" \
            "${config}" "${width}" "${height}" \
            >> "${bundle}/config/lists.tsv"
    done <<'EOF'
gles2-main deqp-gles2 17165 rgba8888d24s8ms0 256 256
gles3-main deqp-gles3 44766 rgba8888d24s8ms0 256 256
gles3-multisample deqp-gles3 4635 rgba8888d24s8ms4 256 256
gles31-main deqp-gles31 37802 rgba8888d24s8ms0 256 256
gles31-multisample deqp-gles31 239 rgba8888d24s8ms4 256 256
gles2-khr-main glcts 473 rgba8888d24s8ms0 64 64
gles3-khr-main glcts 6498 rgba8888d24s8ms0 64 64
gles31-khr-main glcts 4101 rgba8888d24s8ms0 64 64
gles32-khr-main glcts 1405 rgba8888d24s8ms0 64 64
gles32-khr-glesext glcts 1097 rgba8888d24s8ms0 64 64
gles32-khr-single glcts 6053 rgba8888d24s8ms0 64 64
gles2-khr-noctx-main glcts 1 none 64 64
gles32-khr-noctx-main glcts 13 none 64 64
EOF
    list_sha="$(sha256sum "${bundle}/config/lists.tsv" | cut -d' ' -f1)"
    sed -i "s/list_manifest_sha256=fixture-generated-below/list_manifest_sha256=${list_sha}/" \
        "${bundle}/BUILD-RECEIPT.txt"
    (
        cd "${bundle}"
        find . -type f ! -name BUNDLE-SHA256SUMS -print0 \
            | LC_ALL=C sort -z | xargs -0 sha256sum > "${scratch}/bundle-manifest"
    )
    mv "${scratch}/bundle-manifest" "${bundle}/BUNDLE-SHA256SUMS"
    if [ "${corrupt_member}" = yes ]; then
        printf 'corrupt after manifest\n' >> "${bundle}/mustpass/gles32-khr-main.txt"
    fi
    tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
        -C "${tree}" -cf - pf-deqp-gles | gzip -n -9 > "${destination}"
}

good_archive="${scratch}/good.tar.gz"
make_bundle "${good_archive}" 067e8832315e79817ede1c4863804e440f5d1c80 no
good_sha="$(sha256sum "${good_archive}" | cut -d' ' -f1)"
good_url="http://artifact.invalid/artifacts/sha256/${good_sha}/pf-deqp-gles-aarch64.tar.gz"
export PF_CTS_SOURCE_TAG=opengl-es-cts-3.2.14.1
export PF_CTS_SOURCE_COMMIT=067e8832315e79817ede1c4863804e440f5d1c80
export PF_CTS_SOURCE_ARCHIVE_SHA256=ce9f37f536373b6d616cdf854876477be79503999b655d90bb2e0e9483d502df
export PF_CTS_LIST_COUNT=13
export PF_CTS_CASE_COUNT=124248
export PF_CTS_SURFACES=pbuffer:256x256,pbuffer:64x64
export PF_CTS_SOURCE_DATE_EPOCH=0
producer="${scratch}/producer"
"${prepare}" "${good_archive}" "${producer}" "${good_url}" "${good_sha}"

test -x "${producer}/opt/pocketforge/cts/bin/deqp-gles3"
test -x "${producer}/opt/pocketforge/cts/bin/glcts"
test -x "${producer}/opt/pocketforge/cts/run-chunks.sh"
test -f "${producer}/opt/pocketforge/cts/config/lists.tsv"
grep -Fx "artifact_sha256=${good_sha}" \
    "${producer}/usr/share/pocketforge/cts-provenance" >/dev/null
grep -Fx 'list_count=13' "${producer}/usr/share/pocketforge/cts-provenance" >/dev/null
grep -Fx 'mustpass_case_entries=124248' \
    "${producer}/usr/share/pocketforge/cts-provenance" >/dev/null

wrong_sha="$(printf '0%.0s' {1..64})"
if "${prepare}" "${good_archive}" "${scratch}/wrong-sha" \
        "http://artifact.invalid/artifacts/sha256/${wrong_sha}/pf-deqp-gles-aarch64.tar.gz" \
        "${wrong_sha}" >"${scratch}/wrong-sha.out" 2>"${scratch}/wrong-sha.err"; then
    echo 'FAIL: wrong CTS bundle SHA was accepted' >&2
    exit 1
fi
grep -F 'reason=archive_sha256_mismatch' "${scratch}/wrong-sha.err" >/dev/null
test ! -e "${scratch}/wrong-sha"

bad_receipt_archive="${scratch}/bad-receipt.tar.gz"
make_bundle "${bad_receipt_archive}" 167e8832315e79817ede1c4863804e440f5d1c80 no
bad_receipt_sha="$(sha256sum "${bad_receipt_archive}" | cut -d' ' -f1)"
if "${prepare}" "${bad_receipt_archive}" "${scratch}/bad-receipt" \
        "http://artifact.invalid/artifacts/sha256/${bad_receipt_sha}/pf-deqp-gles-aarch64.tar.gz" \
        "${bad_receipt_sha}" >"${scratch}/bad-receipt.out" 2>"${scratch}/bad-receipt.err"; then
    echo 'FAIL: wrong embedded CTS receipt was accepted' >&2
    exit 1
fi
grep -F 'reason=receipt_mismatch key=source_commit' "${scratch}/bad-receipt.err" >/dev/null
test ! -e "${scratch}/bad-receipt"

bad_manifest_archive="${scratch}/bad-manifest.tar.gz"
make_bundle "${bad_manifest_archive}" 067e8832315e79817ede1c4863804e440f5d1c80 yes
bad_manifest_sha="$(sha256sum "${bad_manifest_archive}" | cut -d' ' -f1)"
if "${prepare}" "${bad_manifest_archive}" "${scratch}/bad-manifest" \
        "http://artifact.invalid/artifacts/sha256/${bad_manifest_sha}/pf-deqp-gles-aarch64.tar.gz" \
        "${bad_manifest_sha}" >"${scratch}/bad-manifest.out" 2>"${scratch}/bad-manifest.err"; then
    echo 'FAIL: corrupt embedded CTS member was accepted' >&2
    exit 1
fi
grep -F 'reason=bundle_checksum_mismatch' "${scratch}/bad-manifest.err" >/dev/null
test ! -e "${scratch}/bad-manifest"

make_runtime_rootfs() {
    local destination=$1
    mkdir -p "${destination}/usr/lib/aarch64-linux-gnu"
    for library in libEGL.so.1 libGLESv2.so.2 libGL.so.1 libvulkan.so.1; do
        printf '\177ELF fixture %s\n' "${library}" \
            > "${destination}/usr/lib/aarch64-linux-gnu/${library}"
    done
}

rootfs="${scratch}/rootfs"
make_runtime_rootfs "${rootfs}"
fake_readelf="${scratch}/readelf"
cat > "${fake_readelf}" <<'STUB'
#!/bin/sh
case "$1" in
    -h) printf '  Machine:                           %s\n' "${PF_TEST_MACHINE:-AArch64}" ;;
    -d) sed -n 's|^# NEEDED: \(.*\)$|  0x0000000000000001 (NEEDED)             Shared library: [\1]|p' "$2" ;;
    *) exit 2 ;;
esac
STUB
chmod 0755 "${fake_readelf}"
"${install_bundle}" "${producer}" "${rootfs}" v1 "${good_sha}"
cmp "${producer}/usr/share/pocketforge/cts-provenance" \
    "${rootfs}/usr/share/pocketforge/cts-provenance"
test -x "${rootfs}/opt/pocketforge/cts/bin/deqp-gles31"
for library in libEGL.so libGLESv2.so libGL.so; do
    if [ ! -L "${rootfs}/usr/lib/aarch64-linux-gnu/${library}" ]; then
        echo "FAIL: CTS dlopen library missing: ${library}" >&2
        exit 1
    fi
done
PF_CTS_READELF="${fake_readelf}" "${verify_runtime}" "${rootfs}"

negative_rootfs="${scratch}/negative-rootfs"
cp -a "${rootfs}" "${negative_rootfs}"
rm "${negative_rootfs}/usr/lib/aarch64-linux-gnu/libEGL.so" \
    "${negative_rootfs}/usr/lib/aarch64-linux-gnu/libGLESv2.so" \
    "${negative_rootfs}/usr/lib/aarch64-linux-gnu/libGL.so"
if PF_CTS_READELF="${fake_readelf}" "${verify_runtime}" "${negative_rootfs}" \
        >"${scratch}/negative.out" 2>"${scratch}/negative.err"; then
    echo 'FAIL: CTS rootfs without dlopen symlinks passed' >&2
    exit 1
fi
grep -F 'reason=library_missing library=libEGL.so' \
    "${scratch}/negative.err" >/dev/null

# Versioned-soname payload (bd tsp-mc9m.41.924.24.39): the pinned CTS bundle
# dlopens only versioned names, so the runtime gate must resolve those as well,
# including a soname that appears only as a dynamic NEEDED entry.
versioned_archive="${scratch}/versioned.tar.gz"
make_bundle "${versioned_archive}" 067e8832315e79817ede1c4863804e440f5d1c80 no versioned
versioned_sha="$(sha256sum "${versioned_archive}" | cut -d' ' -f1)"
versioned_producer="${scratch}/versioned-producer"
"${prepare}" "${versioned_archive}" "${versioned_producer}" \
    "http://artifact.invalid/artifacts/sha256/${versioned_sha}/pf-deqp-gles-aarch64.tar.gz" \
    "${versioned_sha}"
versioned_rootfs="${scratch}/versioned-rootfs"
make_runtime_rootfs "${versioned_rootfs}"
"${install_bundle}" "${versioned_producer}" "${versioned_rootfs}" v1 "${versioned_sha}"
versioned_out="${scratch}/versioned.out"
PF_CTS_READELF="${fake_readelf}" "${verify_runtime}" "${versioned_rootfs}" \
    > "${versioned_out}"
grep -F 'cts_runtime_libraries=PASS' "${versioned_out}" >/dev/null
for library in libEGL.so.1 libGLESv2.so.2 libvulkan.so.1 libGL.so.1; do
    if ! sed -n 's/^cts_runtime_libraries=PASS libraries=\([^ ]*\).*/\1/p' \
            "${versioned_out}" | tr ',' '\n' | grep -Fx "${library}" >/dev/null; then
        echo "FAIL: versioned runtime library not resolved: ${library}" >&2
        exit 1
    fi
done
cat "${versioned_out}"

# Negative control: a NEEDED-only soname the rootfs does not carry.
needed_missing_rootfs="${scratch}/versioned-needed-missing"
cp -a "${versioned_rootfs}" "${needed_missing_rootfs}"
rm "${needed_missing_rootfs}/usr/lib/aarch64-linux-gnu/libGL.so.1"
if PF_CTS_READELF="${fake_readelf}" "${verify_runtime}" "${needed_missing_rootfs}" \
        >"${scratch}/needed-missing.out" 2>"${scratch}/needed-missing.err"; then
    echo 'FAIL: versioned rootfs without a NEEDED soname passed' >&2
    exit 1
fi
grep -F 'reason=library_missing library=libGL.so.1' \
    "${scratch}/needed-missing.err" >/dev/null

# Negative control: a versioned soname resolving outside the rootfs.
outside_dir="${scratch}/outside-lib"
mkdir -p "${outside_dir}"
printf '\177ELF fixture outside libvulkan.so.1\n' > "${outside_dir}/libvulkan.so.1"
outside_rootfs="${scratch}/versioned-outside"
cp -a "${versioned_rootfs}" "${outside_rootfs}"
rm "${outside_rootfs}/usr/lib/aarch64-linux-gnu/libvulkan.so.1"
ln -s "${outside_dir}/libvulkan.so.1" \
    "${outside_rootfs}/usr/lib/aarch64-linux-gnu/libvulkan.so.1"
if PF_CTS_READELF="${fake_readelf}" "${verify_runtime}" "${outside_rootfs}" \
        >"${scratch}/outside.out" 2>"${scratch}/outside.err"; then
    echo 'FAIL: versioned soname resolving outside the rootfs passed' >&2
    exit 1
fi
grep -F 'reason=library_target_outside_rootfs library=libvulkan.so.1' \
    "${scratch}/outside.err" >/dev/null

# Negative control: a versioned soname resolving to a non-AArch64 object.
if PF_TEST_MACHINE=ARM PF_CTS_READELF="${fake_readelf}" \
        "${verify_runtime}" "${versioned_rootfs}" \
        >"${scratch}/arch.out" 2>"${scratch}/arch.err"; then
    echo 'FAIL: non-AArch64 versioned runtime library passed' >&2
    exit 1
fi
grep -F 'reason=library_target_not_aarch64' "${scratch}/arch.err" >/dev/null

# Fail-closed control: a payload without any library name still dies.
nameless_archive="${scratch}/nameless.tar.gz"
make_bundle "${nameless_archive}" 067e8832315e79817ede1c4863804e440f5d1c80 no none
nameless_sha="$(sha256sum "${nameless_archive}" | cut -d' ' -f1)"
nameless_producer="${scratch}/nameless-producer"
"${prepare}" "${nameless_archive}" "${nameless_producer}" \
    "http://artifact.invalid/artifacts/sha256/${nameless_sha}/pf-deqp-gles-aarch64.tar.gz" \
    "${nameless_sha}"
nameless_rootfs="${scratch}/nameless-rootfs"
make_runtime_rootfs "${nameless_rootfs}"
"${install_bundle}" "${nameless_producer}" "${nameless_rootfs}" v1 "${nameless_sha}"
if PF_CTS_READELF="${fake_readelf}" "${verify_runtime}" "${nameless_rootfs}" \
        >"${scratch}/nameless.out" 2>"${scratch}/nameless.err"; then
    echo 'FAIL: CTS payload without any library name passed' >&2
    exit 1
fi
grep -F 'reason=dlopen_names_missing' "${scratch}/nameless.err" >/dev/null
if "${install_bundle}" "${producer}" "${rootfs}" v1 "${good_sha}" \
        >"${scratch}/collision.out" 2>"${scratch}/collision.err"; then
    echo 'FAIL: CTS destination collision was accepted' >&2
    exit 1
fi
grep -F 'collision at /opt/pocketforge/cts' "${scratch}/collision.err" >/dev/null

mkdir -p "${scratch}/not-shipped" "${scratch}/release-rootfs"
printf 'mode=not-shipped\n' > "${scratch}/not-shipped/NOT-SHIPPED"
"${install_bundle}" "${scratch}/not-shipped" "${scratch}/release-rootfs" not-shipped ''
test ! -e "${scratch}/release-rootfs/opt/pocketforge/cts"
test ! -e "${scratch}/release-rootfs/usr/share/pocketforge/cts-provenance"
test ! -e "${scratch}/release-rootfs/usr/lib/aarch64-linux-gnu/libEGL.so"
test ! -e "${scratch}/release-rootfs/usr/lib/aarch64-linux-gnu/libGLESv2.so"
test ! -e "${scratch}/release-rootfs/usr/lib/aarch64-linux-gnu/libGL.so"
"${install_bundle}" "${scratch}/absent-producer" "${scratch}/release-rootfs" not-shipped ''
test ! -e "${scratch}/release-rootfs/opt/pocketforge/cts"

grep -F 'AS cts-bundle-v1' "${dockerfile}" >/dev/null
grep -F 'AS cts-bundle-not-shipped' "${dockerfile}" >/dev/null
# Literal Dockerfile interpolation must remain unexpanded here.
# shellcheck disable=SC2016
grep -F 'FROM cts-bundle-${PF_CTS_BUNDLE_MODE} AS cts-bundle' "${dockerfile}" >/dev/null
grep -F 'COPY --from=cts-bundle /out /work/cts-bundle' "${dockerfile}" >/dev/null
# Literal source-contract assertion.
# shellcheck disable=SC2016
grep -F '"${SRC_DIR}/scripts/install-cts-bundle.sh"' "${rootfs_builder}" >/dev/null
# Literal source-contract assertion.
# shellcheck disable=SC2016
grep -F 'PF_CTS_BUNDLE_SHA256=${PF_CTS_BUNDLE_SHA256}' "${rootfs_builder}" >/dev/null
# Literal source-contract assertion.
# shellcheck disable=SC2016
grep -F '"${SRC_DIR}/scripts/verify-cts-runtime-libraries.sh" "${ROOTFS_EXTRACTED}"' \
    "${rootfs_builder}" >/dev/null
test "$(grep -Fxc '            tests/test-cts-bundle-image.sh' "${workflow}")" -eq 1
grep -Fx 'test-cts-bundle-image:' "${makefile}" >/dev/null

echo 'PASS: CTS image payload rejects wrong SHA/receipt/checksums, resolves versioned runtime sonames, and installs only when selected'
