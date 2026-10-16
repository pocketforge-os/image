#!/usr/bin/env bash
# Emit a SHA-bound capability receipt from an authenticated kernel source tree.
set -euo pipefail
umask 022

if [ "$#" -ne 4 ]; then
    echo "usage: $0 KERNEL_SOURCE OUTPUT KERNEL_REPO KERNEL_SHA" >&2
    exit 2
fi

kernel_source="$1"
output="$2"
kernel_repo="$3"
kernel_sha="$4"
checker="${kernel_source}/scripts/test-check-a133-axp717-low-soc.py"
capability=axp717-low-soc-alarm-irqs-v1
result=absent

[ -d "${kernel_source}" ] || {
    echo "kernel capability: source tree is absent: ${kernel_source}" >&2
    exit 1
}
case "${kernel_sha}" in
    *[!0-9a-f]*|'')
        echo "kernel capability: identity must be 40 or 64 lowercase hex characters" >&2
        exit 1
        ;;
esac
[ "${#kernel_sha}" -eq 40 ] || [ "${#kernel_sha}" -eq 64 ] || {
    echo "kernel capability: identity must be 40 or 64 lowercase hex characters" >&2
    exit 1
}
[ ! -L "${output}" ] || {
    echo "kernel capability: output must not be a symlink: ${output}" >&2
    exit 1
}

# kernel-sunxi-7.x#106 introduced this semantic source checker alongside the
# feature. It validates the MFD resources, bank/bit mapping, REG1B programming
# and readback, notification-only handlers, and exact wake policy, including
# its own structural mutation controls. Descendants retain the capability as
# long as their authenticated source still passes that contract.
if [ "${kernel_repo}" = kernel-sunxi-7.x ] && [ -f "${checker}" ] \
    && [ ! -L "${checker}" ]; then
    if python3 -B "${checker}"; then
        result=present
    else
        echo "kernel capability: semantic checker refused ${kernel_repo}@${kernel_sha}" >&2
    fi
else
    echo "kernel capability: semantic checker unavailable for ${kernel_repo}@${kernel_sha}" >&2
fi

install -d -m 0755 "$(dirname "${output}")"
tmp="${output}.tmp.$$"
cleanup() {
    rm -f "${tmp}"
}
trap cleanup EXIT
{
    printf 'schema=1\n'
    printf 'capability=%s\n' "${capability}"
    printf 'result=%s\n' "${result}"
    printf 'kernel_repo=%s\n' "${kernel_repo}"
    printf 'kernel_sha=%s\n' "${kernel_sha}"
} > "${tmp}"
chmod 0444 "${tmp}"
mv "${tmp}" "${output}"
trap - EXIT

printf 'kernel capability: %s result=%s kernel=%s@%s\n' \
    "${capability}" "${result}" "${kernel_repo}" "${kernel_sha}"
