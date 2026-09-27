#!/usr/bin/env bash
# Install the source-built Poolsuite E8 tree into an already-created rootfs.
# Release is intentionally a byte-for-byte no-op: the release producer is empty
# and this helper must not even create directory scaffolding.
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: install-poolsuite.sh <dev|release> <rootfs> <stage> <unit>" >&2
    exit 2
fi

variant="$1"
rootfs="$2"
stage="$3"
unit="$4"

case "${variant}" in
    release)
        exit 0
        ;;
    dev)
        ;;
    *)
        echo "install-poolsuite.sh: invalid variant '${variant}'" >&2
        exit 2
        ;;
esac

app_stage="${stage}/app"
app_root="${rootfs}/opt/pocketforge/apps/org.pocketforge.poolsuite"

for path in ps-app app.toml launch oci/slice.conf; do
    [ -f "${app_stage}/${path}" ] || {
        echo "FATAL: Poolsuite dev stage is incomplete: missing ${app_stage}/${path}" >&2
        exit 1
    }
done
[ -d "${app_stage}/themes" ] || {
    echo "FATAL: Poolsuite dev stage is incomplete: missing ${app_stage}/themes" >&2
    exit 1
}
[ -f "${stage}/.pf-poolsuite-provenance" ] || {
    echo "FATAL: Poolsuite dev stage lacks provenance: ${stage}/.pf-poolsuite-provenance" >&2
    exit 1
}
[ -f "${stage}/toolchain-packages.txt" ] || {
    echo "FATAL: Poolsuite dev stage lacks toolchain package inventory" >&2
    exit 1
}
[ -f "${unit}" ] || {
    echo "FATAL: Poolsuite systemd unit is missing: ${unit}" >&2
    exit 1
}

install -d "${app_root}/themes" "${app_root}/oci"
install -m 0755 "${app_stage}/ps-app" "${app_root}/ps-app"
install -m 0644 "${app_stage}/app.toml" "${app_root}/app.toml"
install -m 0755 "${app_stage}/launch" "${app_root}/launch"
cp -a "${app_stage}/themes/." "${app_root}/themes/"
install -m 0644 "${app_stage}/oci/slice.conf" "${app_root}/oci/slice.conf"
install -D -m 0644 "${stage}/.pf-poolsuite-provenance" \
    "${rootfs}/usr/share/pocketforge/poolsuite-provenance"
install -D -m 0644 "${stage}/toolchain-packages.txt" \
    "${rootfs}/usr/share/pocketforge/poolsuite-toolchain-packages.txt"
install -D -m 0644 "${unit}" \
    "${rootfs}/etc/systemd/system/pocketforge-poolsuite.service"

echo "[customize] Poolsuite installed for dev (service installed disabled)"
