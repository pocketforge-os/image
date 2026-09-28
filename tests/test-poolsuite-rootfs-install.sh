#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${root}/scripts/install-poolsuite.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

rootfs="${tmp}/rootfs"
stage="${tmp}/stage"
mkdir -p "${rootfs}/etc" "${stage}/app/themes/classic" "${stage}/app/oci"
printf 'existing\n' > "${rootfs}/etc/existing"

# The release path must be an exact filesystem no-op for every GPU model even
# when its producer input does not exist. This is the release byte-identity fixture.
find "${rootfs}" -printf '%P %y %m\n' | LC_ALL=C sort > "${tmp}/before"
for gpu_model in open ddk none; do
    "${installer}" release "${gpu_model}" "${rootfs}" "${tmp}/missing-stage"
    find "${rootfs}" -printf '%P %y %m\n' | LC_ALL=C sort > "${tmp}/after"
    cmp "${tmp}/before" "${tmp}/after"
done

# A133 vendor/default dev is the intentional migration: its source-free stub
# returns before any payload install and leaves no tree, service, or marker.
mkdir -p "${tmp}/not-shipped"
"${installer}" dev ddk "${rootfs}" "${tmp}/not-shipped"
find "${rootfs}" -printf '%P %y %m\n' | LC_ALL=C sort > "${tmp}/after"
cmp "${tmp}/before" "${tmp}/after"
test ! -e "${rootfs}/opt/pocketforge/apps/org.pocketforge.poolsuite"
test ! -e "${rootfs}/etc/systemd/system/pocketforge-poolsuite.service"
test ! -e "${rootfs}/usr/share/pocketforge/poolsuite-provenance"

printf 'aarch64 elf fixture\n' > "${stage}/app/ps-app"
printf '[app]\n' > "${stage}/app/app.toml"
printf '#!/bin/sh\n' > "${stage}/app/launch"
printf '{"id":"classic"}\n' > "${stage}/app/themes/classic/manifest.json"
printf '[Slice]\n' > "${stage}/app/oci/slice.conf"
printf 'poolsuite@fixture\n' > "${stage}/.pf-poolsuite-provenance"
printf 'cmake\tfixture\n' > "${stage}/toolchain-packages.txt"
chmod 0755 "${stage}/app/ps-app" "${stage}/app/launch"

"${installer}" dev open "${rootfs}" "${stage}"
app="${rootfs}/opt/pocketforge/apps/org.pocketforge.poolsuite"
test -x "${app}/ps-app"
test -x "${app}/launch"
test -f "${app}/app.toml"
test -f "${app}/themes/classic/manifest.json"
test -f "${app}/oci/slice.conf"
test -f "${rootfs}/usr/share/pocketforge/poolsuite-provenance"
test -f "${rootfs}/usr/share/pocketforge/poolsuite-toolchain-packages.txt"
test ! -e "${rootfs}/etc/systemd/system/pocketforge-poolsuite.service"
test ! -e "${root}/rootfs-overlay/etc/systemd/system/pocketforge-poolsuite.service"
if grep -Eq 'systemd|unit' "${installer}"; then
    echo 'Poolsuite installer still contains dedicated unit installation logic' >&2
    exit 1
fi

if "${installer}" dev open "${tmp}/missing-rootfs" "${tmp}/missing-stage" >/dev/null 2>&1; then
    echo 'expected a missing dev stage to fail closed' >&2
    exit 1
fi

mkdir -p "${tmp}/bad-non-open/app"
if "${installer}" dev ddk "${rootfs}" "${tmp}/bad-non-open" >/dev/null 2>&1; then
    echo 'expected a non-open Poolsuite payload to fail closed' >&2
    exit 1
fi

echo 'poolsuite rootfs install contract: PASS (migration and release file lists unchanged)'
