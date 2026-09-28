#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${root}/scripts/install-default-app-support.sh"
unit="${root}/rootfs-overlay/etc/systemd/system/pf-app@.service"
dockerfile="${root}/build/Dockerfile.pf"
rootfs_builder="${root}/scripts/build-rootfs.sh"
tmp="$(mktemp -d)"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT

python3 - "${unit}" <<'PY'
import sys
from pathlib import Path

expected = """[Unit]
Description=PocketForge default application %i
Requires=pocketforge-foreground.target
After=local-fs.target pocketforge-foreground.target
Conflicts=shutdown.target
Before=shutdown.target
ConditionPathExists=/dev/fb0

[Service]
Type=simple
User=gamer
Group=gamer
SupplementaryGroups=audio input video
WorkingDirectory=/opt/pocketforge/apps/%i
Environment=XDG_CONFIG_HOME=/var/lib/pocketforge/apps/%i/config
Environment=XDG_STATE_HOME=/var/lib/pocketforge/apps/%i/state
ExecStart=/usr/bin/pf-app-launch %i
StateDirectory=pocketforge/apps/%i
StateDirectoryMode=0700
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
PrivateTmp=yes
ReadOnlyPaths=/opt/pocketforge/apps/%i
ReadWritePaths=/var/lib/pocketforge/apps/%i
KillMode=control-group
KillSignal=SIGTERM
TimeoutStopSec=2s
Restart=no
MemoryMax=256M
Nice=-5
"""
actual = Path(sys.argv[1]).read_text()
assert actual == expected
assert "[Install]" not in actual
PY

rootfs="${tmp}/open-rootfs"
runtime="${tmp}/open-runtime"
launcher="${tmp}/open-launcher"
mkdir -p "${rootfs}/etc" "${runtime}/bin" "${runtime}/share" "${launcher}/bin"
printf 'existing\n' > "${rootfs}/etc/existing"
dd if=/dev/zero of="${runtime}/bin/pf-app-launch" bs=64 count=1 status=none
printf '\267\000' | dd of="${runtime}/bin/pf-app-launch" bs=1 seek=18 conv=notrunc status=none
chmod 0755 "${runtime}/bin/pf-app-launch"
printf 'authority fixture\n' > "${runtime}/bin/pf-session-authorityd"
printf 'shell fixture\n' > "${launcher}/bin/pf-shell"
printf '%s\n' \
    'schema_version = 1' \
    'runtime_family = "pocketforge/a133-powervr"' \
    'runtime_abi = "1"' \
    'platform_version = "20"' \
    'supported_capabilities = ["audio", "entropy", "input", "settings"]' \
    > "${runtime}/share/platform-capabilities.toml"

"${installer}" open "${rootfs}" "${runtime}" "${launcher}" "${unit}"
test -x "${rootfs}/usr/bin/pf-app-launch"
cmp "${runtime}/share/platform-capabilities.toml" \
    "${rootfs}/usr/share/pocketforge/platform-capabilities.toml"
cmp "${unit}" "${rootfs}/etc/systemd/system/pf-app@.service"
if find "${rootfs}/etc/systemd/system" -path '*.wants/*' -name 'pf-app@*.service' | grep -q .; then
    echo 'pf-app@.service was unexpectedly enabled' >&2
    exit 1
fi

# Non-open integration is an exact no-op, and any staged generic mechanism or
# launcher artifact makes it fail closed instead of leaking bytes.
non_open_rootfs="${tmp}/non-open-rootfs"
mkdir -p "${non_open_rootfs}/etc" "${tmp}/closed-runtime" "${tmp}/closed-launcher"
printf 'existing\n' > "${non_open_rootfs}/etc/existing"
find "${non_open_rootfs}" -printf '%P %y %m\n' | LC_ALL=C sort > "${tmp}/before"
for gpu_model in ddk none; do
    "${installer}" "${gpu_model}" "${non_open_rootfs}" \
        "${tmp}/closed-runtime" "${tmp}/closed-launcher" "${unit}"
    find "${non_open_rootfs}" -printf '%P %y %m\n' | LC_ALL=C sort > "${tmp}/after"
    cmp "${tmp}/before" "${tmp}/after"
done
mkdir -p "${tmp}/closed-runtime/bin"
printf 'leak\n' > "${tmp}/closed-runtime/bin/pf-app-launch"
if "${installer}" ddk "${non_open_rootfs}" \
    "${tmp}/closed-runtime" "${tmp}/closed-launcher" "${unit}" >/dev/null 2>&1; then
    echo 'non-open default-app artifact leak was accepted' >&2
    exit 1
fi

test ! -e "${root}/rootfs-overlay/etc/systemd/system/pocketforge-poolsuite.service"
! grep -F 'pocketforge-poolsuite.service' "${root}/scripts/install-poolsuite.sh"
grep -F 'install-default-app-support.sh' "${rootfs_builder}" >/dev/null
grep -F 'cargo build --offline --locked --release --target "${PF_RUNTIME_TARGET}" -p pf-app-launch --bin pf-app-launch' "${dockerfile}" >/dev/null
grep -F 'pf-app-launch is dynamically linked (expected static musl)' "${dockerfile}" >/dev/null
grep -F 'pf-app-validate.rs' "${dockerfile}" >/dev/null
! grep -E 'pf-app-launch|pf-app@\.service|platform-capabilities\.toml|launcher-src|PF_APP_' \
    "${root}/scripts/build-rootfs-a523.sh"

# The non-open launcher stages are source-free, while only launcher-open names
# the gated launcher context.
ddk_body="$(sed -n '/^FROM ${PF_CONTAINER} AS launcher-ddk$/,/^FROM ${PF_CONTAINER} AS launcher-none$/p' "${dockerfile}")"
none_body="$(sed -n '/^FROM ${PF_CONTAINER} AS launcher-none$/,/^# launcher-open/p' "${dockerfile}")"
! grep -F 'launcher-src' <<<"${ddk_body}"
! grep -F 'launcher-src' <<<"${none_body}"
test "$(grep -c '^COPY --from=launcher-src ' "${dockerfile}")" -eq 1

echo 'default-app rootfs contract: PASS (verbatim dormant unit and open-only install)'
