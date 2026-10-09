#!/usr/bin/env bash
# Verify that every unversioned library literal dlopened by the CTS binaries
# resolves to an AArch64 ELF in the assembled rootfs.
set -euo pipefail

die() {
    printf 'cts_runtime_libraries=FAIL %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 1 ] || die 'reason=usage expected=rootfs'
rootfs=$1
if [ ! -d "${rootfs}" ] || [ -L "${rootfs}" ]; then
    die 'reason=rootfs_missing'
fi

readelf_command=${PF_CTS_READELF:-readelf}
command -v "${readelf_command}" >/dev/null 2>&1 || die 'reason=readelf_unavailable'
command -v strings >/dev/null 2>&1 || die 'reason=strings_unavailable'

work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-cts-runtime.XXXXXX")
cleanup() {
    find "${work}" -mindepth 1 -delete
    rmdir "${work}"
}
trap cleanup EXIT
names_file="${work}/dlopen-names"
: > "${names_file}"

for binary in deqp-gles2 deqp-gles3 deqp-gles31 glcts; do
    path="${rootfs}/opt/pocketforge/cts/bin/${binary}"
    if [ ! -f "${path}" ] || [ -L "${path}" ]; then
        die "reason=binary_missing binary=${binary}"
    fi
    if binary_names=$(strings -a "${path}" \
            | LC_ALL=C grep -E '^lib[A-Za-z0-9_+.-]+\.so$'); then
        printf '%s\n' "${binary_names}" >> "${names_file}"
    else
        status=$?
        [ "${status}" -eq 1 ] || die "reason=binary_scan_failed binary=${binary}"
    fi
done

LC_ALL=C sort -u -o "${names_file}" "${names_file}"
[ -s "${names_file}" ] || die 'reason=dlopen_names_missing'

resolved_names=
while IFS= read -r library; do
    resolved=
    for directory in usr/local/lib usr/lib/aarch64-linux-gnu lib/aarch64-linux-gnu; do
        candidate="${rootfs}/${directory}/${library}"
        if [ -e "${candidate}" ] || [ -L "${candidate}" ]; then
            resolved=${candidate}
            break
        fi
    done
    [ -n "${resolved}" ] || die "reason=library_missing library=${library}"
    [ -L "${resolved}" ] || die "reason=library_not_symlink library=${library}"
    target=$(readlink -f "${resolved}") \
        || die "reason=library_target_missing library=${library}"
    case "${target}" in
        "${rootfs}"/*) ;;
        *) die "reason=library_target_outside_rootfs library=${library}" ;;
    esac
    if [ ! -f "${target}" ] || [ -L "${target}" ]; then
        die "reason=library_target_not_regular library=${library}"
    fi
    if ! header=$("${readelf_command}" -h "${target}" 2>&1); then
        die "reason=library_target_not_elf library=${library}"
    fi
    printf '%s\n' "${header}" | grep -Eq 'Machine:[[:space:]]+AArch64' \
        || die "reason=library_target_not_aarch64 library=${library}"
    resolved_names="${resolved_names}${resolved_names:+,}${library}"
done < "${names_file}"

printf 'cts_runtime_libraries=PASS libraries=%s evidence=cts-binary-strings rootfs=exact\n' \
    "${resolved_names}"
