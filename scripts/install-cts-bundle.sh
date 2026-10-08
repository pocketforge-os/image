#!/usr/bin/env bash
# Install a verified CTS producer tree into the assembled rootfs.
set -euo pipefail

die() {
    printf 'cts_install_status=FAIL %s\n' "$*" >&2
    exit 1
}

regular_file() {
    [ -f "$1" ] && [ ! -L "$1" ]
}

regular_dir() {
    [ -d "$1" ] && [ ! -L "$1" ]
}

[ "$#" -eq 4 ] || die 'reason=usage expected=producer,rootfs,mode,sha256'
producer=$1
rootfs=$2
mode=$3
expected_sha=$4

regular_dir "${rootfs}" || die 'reason=rootfs_missing'

case "${mode}" in
    not-shipped)
        if [ ! -e "${producer}" ]; then
            printf 'cts_install_status=PASS mode=not-shipped producer=absent\n'
            exit 0
        fi
        regular_dir "${producer}" || die 'reason=producer_invalid'
        regular_file "${producer}/NOT-SHIPPED" || die 'reason=not_shipped_marker_missing'
        [ "$(cat "${producer}/NOT-SHIPPED")" = 'mode=not-shipped' ] \
            || die 'reason=not_shipped_marker_invalid'
        [ ! -e "${producer}/opt/pocketforge/cts" ] \
            || die 'reason=not_shipped_payload_present'
        [ ! -e "${producer}/usr/share/pocketforge/cts-provenance" ] \
            || die 'reason=not_shipped_provenance_present'
        printf 'cts_install_status=PASS mode=not-shipped\n'
        exit 0
        ;;
    v1) ;;
    *) die 'reason=invalid_mode' ;;
esac

regular_dir "${producer}" || die 'reason=producer_missing'

case "${expected_sha}" in
    *[!0-9a-f]*|'') die 'reason=invalid_expected_sha256' ;;
esac
[ "${#expected_sha}" -eq 64 ] || die 'reason=invalid_expected_sha256'
[ ! -e "${producer}/NOT-SHIPPED" ] || die 'reason=selected_payload_is_not_shipped'

payload="${producer}/opt/pocketforge/cts"
provenance="${producer}/usr/share/pocketforge/cts-provenance"
regular_dir "${payload}" || die 'reason=payload_missing'
regular_file "${provenance}" || die 'reason=provenance_missing'
[ "$(awk -F= '$1 == "artifact_sha256" { count++; value=$2 } END { if (count == 1) print value }' "${provenance}")" = "${expected_sha}" ] \
    || die 'reason=provenance_sha256_mismatch'
if find "${payload}" -type l -print -quit | grep -q .; then
    die 'reason=payload_symlink'
fi
if find "${producer}/opt" "${producer}/usr" -perm /022 -print -quit | grep -q .; then
    die 'reason=payload_writable'
fi
regular_file "${payload}/BUNDLE-SHA256SUMS" || die 'reason=bundle_manifest_missing'
if ! (cd "${payload}" && sha256sum --strict -c BUNDLE-SHA256SUMS >/dev/null); then
    die 'reason=bundle_checksum_mismatch'
fi

destination="${rootfs}/opt/pocketforge/cts"
destination_provenance="${rootfs}/usr/share/pocketforge/cts-provenance"
[ ! -e "${destination}" ] || die 'reason=destination_collision collision at /opt/pocketforge/cts'
[ ! -e "${destination_provenance}" ] \
    || die 'reason=destination_collision collision at /usr/share/pocketforge/cts-provenance'

install -d "${rootfs}/opt/pocketforge" "${rootfs}/usr/share/pocketforge"
cp -a "${payload}" "${destination}"
cp -a "${provenance}" "${destination_provenance}"
printf 'cts_install_status=PASS mode=v1 sha256=%s\n' "${expected_sha}"
