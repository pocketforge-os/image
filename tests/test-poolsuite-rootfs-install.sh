#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${root}/scripts/install-poolsuite.sh"
unit="${root}/rootfs-overlay/etc/systemd/system/pocketforge-poolsuite.service"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

rootfs="${tmp}/rootfs"
stage="${tmp}/stage"
mkdir -p "${rootfs}/etc" "${stage}/app/themes/classic" "${stage}/app/oci"
printf 'existing\n' > "${rootfs}/etc/existing"

# The release path must be an exact filesystem no-op even when its producer and
# unit inputs do not exist. This is the script-level release file-list proof.
find "${rootfs}" -printf '%P %y %m\n' | LC_ALL=C sort > "${tmp}/before"
"${installer}" release "${rootfs}" "${tmp}/missing-stage" "${tmp}/missing-unit"
find "${rootfs}" -printf '%P %y %m\n' | LC_ALL=C sort > "${tmp}/after"
cmp "${tmp}/before" "${tmp}/after"

printf 'aarch64 elf fixture\n' > "${stage}/app/ps-app"
printf '[app]\n' > "${stage}/app/app.toml"
printf '#!/bin/sh\n' > "${stage}/app/launch"
printf '{"id":"classic"}\n' > "${stage}/app/themes/classic/manifest.json"
printf '[Slice]\n' > "${stage}/app/oci/slice.conf"
printf 'poolsuite@fixture\n' > "${stage}/.pf-poolsuite-provenance"
printf 'cmake\tfixture\n' > "${stage}/toolchain-packages.txt"
chmod 0755 "${stage}/app/ps-app" "${stage}/app/launch"

"${installer}" dev "${rootfs}" "${stage}" "${unit}"
app="${rootfs}/opt/pocketforge/apps/org.pocketforge.poolsuite"
test -x "${app}/ps-app"
test -x "${app}/launch"
test -f "${app}/app.toml"
test -f "${app}/themes/classic/manifest.json"
test -f "${app}/oci/slice.conf"
test -f "${rootfs}/usr/share/pocketforge/poolsuite-provenance"
test -f "${rootfs}/usr/share/pocketforge/poolsuite-toolchain-packages.txt"
test -f "${rootfs}/etc/systemd/system/pocketforge-poolsuite.service"
if find "${rootfs}/etc/systemd/system" -path '*.wants/*' -name 'pocketforge-poolsuite.service' | grep -q .; then
    echo 'Poolsuite unit was unexpectedly enabled' >&2
    exit 1
fi

grep -Fx 'Requires=pocketforge-foreground.target' "${unit}" >/dev/null
grep -Fx 'After=local-fs.target network-online.target pocketforge-foreground.target' "${unit}" >/dev/null
grep -Fx 'ExecStart=/opt/pocketforge/apps/org.pocketforge.poolsuite/launch' "${unit}" >/dev/null
grep -Fx 'Environment=XDG_CONFIG_HOME=/var/lib/pocketforge' "${unit}" >/dev/null
grep -Fx 'StateDirectory=pocketforge/poolsuite' "${unit}" >/dev/null
grep -Fx 'WantedBy=multi-user.target' "${unit}" >/dev/null

if "${installer}" dev "${tmp}/missing-rootfs" "${tmp}/missing-stage" "${unit}" >/dev/null 2>&1; then
    echo 'expected a missing dev stage to fail closed' >&2
    exit 1
fi

echo 'poolsuite rootfs install contract: PASS (release file list unchanged)'
