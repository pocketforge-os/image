#!/usr/bin/env bash
# Verify the immutable GLES CTS artifact and materialize a stripped rootfs tree.
set -euo pipefail

die() {
    printf 'cts_bundle_status=FAIL %s\n' "$*" >&2
    exit 1
}

regular_file() {
    [ -f "$1" ] && [ ! -L "$1" ]
}

regular_dir() {
    [ -d "$1" ] && [ ! -L "$1" ]
}

[ "$#" -eq 4 ] || die 'reason=usage expected=archive,output,url,sha256'
archive=$1
output=$2
artifact_url=$3
expected_sha=$4

for name in PF_CTS_SOURCE_TAG PF_CTS_SOURCE_COMMIT PF_CTS_SOURCE_ARCHIVE_SHA256 \
        PF_CTS_LIST_COUNT PF_CTS_CASE_COUNT PF_CTS_SURFACES PF_CTS_SOURCE_DATE_EPOCH; do
    [ -n "${!name:-}" ] || die "reason=missing_expected_receipt key=${name}"
done
case "${PF_CTS_SOURCE_COMMIT}" in *[!0-9a-f]*|'') die 'reason=invalid_source_commit' ;; esac
[ "${#PF_CTS_SOURCE_COMMIT}" -eq 40 ] || die 'reason=invalid_source_commit'
case "${PF_CTS_SOURCE_ARCHIVE_SHA256}" in
    *[!0-9a-f]*|'') die 'reason=invalid_source_archive_sha256' ;;
esac
[ "${#PF_CTS_SOURCE_ARCHIVE_SHA256}" -eq 64 ] \
    || die 'reason=invalid_source_archive_sha256'
case "${PF_CTS_LIST_COUNT}:${PF_CTS_CASE_COUNT}:${PF_CTS_SOURCE_DATE_EPOCH}" in
    *[!0-9:]*) die 'reason=invalid_expected_receipt_number' ;;
esac
case "${expected_sha}" in
    *[!0-9a-f]*|'') die 'reason=invalid_expected_sha256' ;;
esac
[ "${#expected_sha}" -eq 64 ] || die 'reason=invalid_expected_sha256'
case "${artifact_url}" in
    http://*/artifacts/sha256/"${expected_sha}"/pf-deqp-gles-aarch64.tar.gz) ;;
    *) die 'reason=artifact_url_sha_mismatch' ;;
esac
regular_file "${archive}" || die 'reason=archive_missing'
[ ! -e "${output}" ] || die 'reason=output_exists'

actual_sha=$(sha256sum "${archive}" | cut -d' ' -f1)
[ "${actual_sha}" = "${expected_sha}" ] || die 'reason=archive_sha256_mismatch'

mkdir -p "$(dirname "${output}")"
work=$(mktemp -d "$(dirname "${output}")/.cts-bundle.XXXXXX")
committed=0
cleanup() {
    if [ "${committed}" -ne 1 ] && [ -d "${output}" ] && [ ! -L "${output}" ]; then
        chmod -R u+w "${output}"
        find "${output}" -mindepth 1 -delete
        rmdir "${output}"
    fi
    chmod -R u+w "${work}"
    find "${work}" -mindepth 1 -delete
    rmdir "${work}"
}
trap cleanup EXIT

member_list="${work}/archive-members"
tar -tzf "${archive}" > "${member_list}" || die 'reason=archive_unreadable'
[ -s "${member_list}" ] || die 'reason=archive_empty'
awk '
    BEGIN { ok = 1 }
    /(^|\/)\.\.($|\/)/ || /^\// || $0 !~ /^pf-deqp-gles\// { ok = 0 }
    END { exit ok ? 0 : 1 }
' "${member_list}" || die 'reason=unsafe_archive_member'

extract="${work}/extract"
mkdir -p "${extract}"
tar -xzf "${archive}" -C "${extract}" --no-same-owner --no-same-permissions \
    || die 'reason=archive_extract_failed'
bundle="${extract}/pf-deqp-gles"
regular_dir "${bundle}" || die 'reason=bundle_root_missing'
if find "${bundle}" -type l -print -quit | grep -q .; then
    die 'reason=bundle_symlink'
fi
if find "${bundle}" ! -type d ! -type f -print -quit | grep -q .; then
    die 'reason=bundle_special_file'
fi
regular_file "${bundle}/BUNDLE-SHA256SUMS" || die 'reason=bundle_manifest_missing'
if ! (cd "${bundle}" && sha256sum --strict -c BUNDLE-SHA256SUMS >/dev/null); then
    die 'reason=bundle_checksum_mismatch'
fi

receipt="${bundle}/BUILD-RECEIPT.txt"
lists="${bundle}/config/lists.tsv"
regular_file "${receipt}" || die 'reason=receipt_missing'
regular_file "${lists}" || die 'reason=list_manifest_missing'

receipt_value() {
    local key=$1 count value
    count=$(awk -F= -v key="${key}" '$1 == key { count++ } END { print count + 0 }' "${receipt}")
    [ "${count}" -eq 1 ] || die "reason=receipt_key_count key=${key} count=${count}"
    value=$(awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print }' "${receipt}")
    printf '%s' "${value}"
}

check_receipt() {
    local key=$1 expected=$2 actual
    actual=$(receipt_value "${key}")
    [ "${actual}" = "${expected}" ] || die "reason=receipt_mismatch key=${key}"
}

check_receipt source_tag "${PF_CTS_SOURCE_TAG}"
check_receipt source_commit "${PF_CTS_SOURCE_COMMIT}"
check_receipt source_archive_sha256 "${PF_CTS_SOURCE_ARCHIVE_SHA256}"
check_receipt list_count "${PF_CTS_LIST_COUNT}"
check_receipt mustpass_case_entries "${PF_CTS_CASE_COUNT}"
check_receipt build_targets 'deqp-gles2,deqp-gles3,deqp-gles31,glcts'
check_receipt deqp_target surfaceless
check_receipt surfaces "${PF_CTS_SURFACES}"
check_receipt source_date_epoch "${PF_CTS_SOURCE_DATE_EPOCH}"
list_sha=$(sha256sum "${lists}" | cut -d' ' -f1)
check_receipt list_manifest_sha256 "${list_sha}"

for binary in deqp-gles2 deqp-gles3 deqp-gles31 glcts; do
    path="${bundle}/bin/${binary}"
    regular_file "${path}" || die "reason=binary_missing binary=${binary}"
    [ -n "$(find "${path}" -maxdepth 0 -type f -perm /111 -print -quit)" ] \
        || die "reason=binary_not_executable binary=${binary}"
done
for data_dir in gles2 gles3 gles31 gl_cts; do
    regular_dir "${bundle}/bin/${data_dir}" \
        || die "reason=data_directory_missing directory=${data_dir}"
done
for required_file in LICENSE.VK-GL-CTS receipts/readelf.txt \
        receipts/file.txt receipts/build-packages.tsv; do
    regular_file "${bundle}/${required_file}" \
        || die "reason=required_file_missing path=${required_file}"
done
regular_file "${bundle}/run-chunks.sh" || die 'reason=runner_missing'
[ -n "$(find "${bundle}/run-chunks.sh" -maxdepth 0 -type f -perm /111 -print -quit)" ] \
    || die 'reason=runner_not_executable'

list_count=0
case_count=0
seen=' '
while IFS=$'\t' read -r name binary filename digest cases gl_config width height base_seed extra; do
    case "${name}" in ''|'#'*) continue ;; esac
    [ -z "${extra:-}" ] || die "reason=list_manifest_column_count list=${name}"
    case "${seen}" in *" ${name} "*) die "reason=list_manifest_duplicate list=${name}" ;; esac
    seen="${seen}${name} "
    case "${binary}" in deqp-gles2|deqp-gles3|deqp-gles31|glcts) ;; *) die "reason=list_binary list=${name}" ;; esac
    case "${filename}" in */*|''|.|..) die "reason=list_filename list=${name}" ;; esac
    case "${digest}" in *[!0-9a-f]*|'') die "reason=list_sha256 list=${name}" ;; esac
    [ "${#digest}" -eq 64 ] || die "reason=list_sha256 list=${name}"
    case "${cases}" in *[!0-9]*|'') die "reason=list_cases list=${name}" ;; esac
    list_file="${bundle}/mustpass/${filename}"
    regular_file "${list_file}" || die "reason=list_file_missing list=${name}"
    [ "$(sha256sum "${list_file}" | cut -d' ' -f1)" = "${digest}" ] \
        || die "reason=list_file_sha256 list=${name}"
    [ "$(wc -l < "${list_file}")" -eq "${cases}" ] \
        || die "reason=list_file_cases list=${name}"
    case "${gl_config}" in none|rgba8888d24s8ms0|rgba8888d24s8ms4) ;; *) die "reason=list_gl_config list=${name}" ;; esac
    case "${width}:${height}:${base_seed}" in *[!0-9:]*) die "reason=list_numeric_field list=${name}" ;; esac
    list_count=$((list_count + 1))
    case_count=$((case_count + cases))
done < "${lists}"
[ "${list_count}" -eq "${PF_CTS_LIST_COUNT}" ] || die 'reason=list_count_mismatch'
[ "${case_count}" -eq "${PF_CTS_CASE_COUNT}" ] || die 'reason=case_count_mismatch'

install -d "${output}/opt/pocketforge/cts" "${output}/usr/share/pocketforge"
cp -a "${bundle}/." "${output}/opt/pocketforge/cts/"
bundle_manifest_sha=$(sha256sum "${bundle}/BUNDLE-SHA256SUMS" | cut -d' ' -f1)
installed_file_bytes=$(find "${output}/opt/pocketforge/cts" -type f -printf '%s\n' \
    | awk '{ total += $1 } END { print total + 0 }')
cat > "${output}/usr/share/pocketforge/cts-provenance" <<EOF
schema=1
artifact_url=${artifact_url}
artifact_sha256=${expected_sha}
artifact_bytes=$(stat -c%s "${archive}")
source_tag=${PF_CTS_SOURCE_TAG}
source_commit=${PF_CTS_SOURCE_COMMIT}
list_count=${list_count}
mustpass_case_entries=${case_count}
bundle_manifest_sha256=${bundle_manifest_sha}
installed_file_bytes=${installed_file_bytes}
install_path=/opt/pocketforge/cts
EOF
chmod -R a-w "${output}"
committed=1

printf 'cts_bundle_status=PASS sha256=%s lists=%s cases=%s installed_file_bytes=%s\n' \
    "${expected_sha}" "${list_count}" "${case_count}" "${installed_file_bytes}"
