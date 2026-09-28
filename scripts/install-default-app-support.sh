#!/usr/bin/env bash
# Install the generic default-app mechanism only for the A133-open profile.
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "usage: install-default-app-support.sh <gpu-model> <rootfs> <runtime-stage> <launcher-stage> <unit>" >&2
    exit 2
fi

gpu_model="$1"
rootfs="$2"
runtime_stage="$3"
launcher_stage="$4"
unit="$5"

helper="${runtime_stage}/bin/pf-app-launch"
authority="${runtime_stage}/bin/pf-session-authorityd"
platform="${runtime_stage}/share/platform-capabilities.toml"
shell="${launcher_stage}/bin/pf-shell"

if [ "${gpu_model}" != open ]; then
    for forbidden in "${helper}" "${authority}" "${platform}" "${shell}"; do
        [ ! -e "${forbidden}" ] || {
            echo "FATAL: default-app artifact staged for non-open profile: ${forbidden}" >&2
            exit 1
        }
    done
    exit 0
fi

for required in "${helper}" "${authority}" "${platform}" "${shell}" "${unit}"; do
    [ -f "${required}" ] || {
        echo "FATAL: A133-open default-app artifact is missing: ${required}" >&2
        exit 1
    }
done

helper_em="$(od -An -tx1 -j18 -N2 "${helper}" | tr -d ' ')"
[ "${helper_em}" = b700 ] || {
    echo "FATAL: ${helper} is not an aarch64 ELF (e_machine=${helper_em}, want b700)" >&2
    exit 1
}
if grep -qa 'ld-musl\|ld-linux' "${helper}"; then
    echo "FATAL: ${helper} is dynamically linked (expected static musl)" >&2
    exit 1
fi

install -D -m 0755 "${helper}" "${rootfs}/usr/bin/pf-app-launch"
install -D -m 0644 "${platform}" \
    "${rootfs}/usr/share/pocketforge/platform-capabilities.toml"
install -D -m 0644 "${unit}" "${rootfs}/etc/systemd/system/pf-app@.service"

if find "${rootfs}/etc/systemd/system" -path '*.wants/*' -name 'pf-app@*.service' -print -quit \
    | grep -q .; then
    echo "FATAL: pf-app@.service must be installed but never enabled" >&2
    exit 1
fi

echo "[customize] default-app helper, dormant unit template, and platform contract installed"
