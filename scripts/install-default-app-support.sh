#!/usr/bin/env bash
# Install the generic default-app mechanism only for the A133-open profile.
#
# The atomic A133-open set: pf-app-launch, the dormant pf-app@.service template,
# the platform contract, and (bd: tsp-f3fm.202.1 B4) default-app input delivery:
# pf-input-broker with its runtime unit plus the image's app-session drop-in (never
# enabled), the pf-shell-selected ordering drop-in, libpocketforge.so.1, and the one
# staged device descriptor. The drop-ins are read from the directory that holds
# <unit> (rootfs-overlay/etc/systemd/system).
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
systemd_source="$(dirname -- "${unit}")"
descriptor_id=a133

helper="${runtime_stage}/bin/pf-app-launch"
authority="${runtime_stage}/bin/pf-session-authorityd"
platform="${runtime_stage}/share/platform-capabilities.toml"
shell="${launcher_stage}/bin/pf-shell"
broker="${runtime_stage}/bin/pf-input-broker"
broker_unit="${runtime_stage}/systemd/pf-input-broker.service"
library="${runtime_stage}/lib/libpocketforge.so.1"
descriptors="${runtime_stage}/share/devices"
descriptor="${descriptors}/${descriptor_id}/capabilities.toml"
broker_dropin="${systemd_source}/pf-input-broker.service.d/10-app-session.conf"
shell_dropin="${systemd_source}/pf-shell-selected.service.d/10-input-broker.conf"

if [ "${gpu_model}" != open ]; then
    for forbidden in "${helper}" "${authority}" "${platform}" "${shell}" \
        "${broker}" "${broker_unit}" "${library}" "${descriptors}"; do
        [ ! -e "${forbidden}" ] || {
            echo "FATAL: default-app artifact staged for non-open profile: ${forbidden}" >&2
            exit 1
        }
    done
    exit 0
fi

for required in "${helper}" "${authority}" "${platform}" "${shell}" "${unit}" \
    "${broker}" "${broker_unit}" "${library}" "${descriptor}" \
    "${broker_dropin}" "${shell_dropin}"; do
    [ -f "${required}" ] || {
        echo "FATAL: A133-open default-app artifact is missing: ${required}" >&2
        exit 1
    }
done

staged_descriptors="$(cd "${descriptors}" && find . -mindepth 1 ! -type d -print | LC_ALL=C sort)"
[ "${staged_descriptors}" = "./${descriptor_id}/capabilities.toml" ] || {
    echo "FATAL: expected exactly devices/${descriptor_id}/capabilities.toml, staged: ${staged_descriptors}" >&2
    exit 1
}

require_aarch64() {
    local binary="$1" em
    em="$(od -An -tx1 -j18 -N2 "${binary}" | tr -d ' ')"
    [ "${em}" = b700 ] || {
        echo "FATAL: ${binary} is not an aarch64 ELF (e_machine=${em}, want b700)" >&2
        exit 1
    }
}
require_static() {
    if grep -qa 'ld-musl\|ld-linux' "$1"; then
        echo "FATAL: $1 is dynamically linked (expected static musl)" >&2
        exit 1
    fi
}
require_aarch64 "${helper}"
require_static "${helper}"
require_aarch64 "${broker}"
require_static "${broker}"
require_aarch64 "${library}"

install -D -m 0755 "${helper}" "${rootfs}/usr/bin/pf-app-launch"
install -D -m 0644 "${platform}" \
    "${rootfs}/usr/share/pocketforge/platform-capabilities.toml"
install -D -m 0644 "${unit}" "${rootfs}/etc/systemd/system/pf-app@.service"

install -D -m 0755 "${broker}" "${rootfs}/usr/bin/pf-input-broker"
install -D -m 0644 "${broker_unit}" "${rootfs}/etc/systemd/system/pf-input-broker.service"
install -D -m 0644 "${broker_dropin}" \
    "${rootfs}/etc/systemd/system/pf-input-broker.service.d/10-app-session.conf"
install -D -m 0644 "${shell_dropin}" \
    "${rootfs}/etc/systemd/system/pf-shell-selected.service.d/10-input-broker.conf"
install -D -m 0644 "${library}" "${rootfs}/usr/lib/aarch64-linux-gnu/libpocketforge.so.1"
install -D -m 0644 "${descriptor}" \
    "${rootfs}/usr/share/pocketforge/devices/${descriptor_id}/capabilities.toml"

if find "${rootfs}/etc/systemd/system" -path '*.wants/*' -name 'pf-app@*.service' -print -quit \
    | grep -q .; then
    echo "FATAL: pf-app@.service must be installed but never enabled" >&2
    exit 1
fi
# The runtime unit's [Install] WantedBy=multi-user.target would grab the pad at
# boot and break pf-shell's EVIOCGRAB. It is started only as a pf-app@ dependency.
while IFS= read -r -d '' enabled; do
    echo "[customize] removing boot enable link for the app-session broker: ${enabled#"${rootfs}"}"
    rm -f -- "${enabled}"
done < <(find "${rootfs}/etc/systemd/system" -path '*.wants/*' -name 'pf-input-broker.service' -print0)
if find "${rootfs}/etc/systemd/system" -path '*.wants/*' -name 'pf-input-broker.service' -print -quit \
    | grep -q .; then
    echo "FATAL: pf-input-broker.service must be installed but never enabled" >&2
    exit 1
fi

echo "[customize] default-app helper, dormant unit template, platform contract, app-session input broker (not enabled), libpocketforge.so.1, and devices/${descriptor_id} descriptor installed"
