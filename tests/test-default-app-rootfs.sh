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
BindsTo=pf-input-broker.service
After=local-fs.target pocketforge-foreground.target pf-input-broker.service
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
Environment=PF_DESCRIPTOR=/usr/share/pocketforge/devices/a133/capabilities.toml
Environment=PF_BROKER_SOCK=/run/pocketforge/input-broker.sock
ExecStart=/usr/bin/pf-app-launch %i
StateDirectory=pocketforge/apps/%i
StateDirectoryMode=0700
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
PrivateTmp=yes
ReadOnlyPaths=/opt/pocketforge/apps/%i
ReadWritePaths=/var/lib/pocketforge/apps/%i
InaccessiblePaths=-/run/pocketforge/session-authority.sock
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
aarch64_fixture() {
    dd if=/dev/zero of="$1" bs=64 count=1 status=none
    printf '\267\000' | dd of="$1" bs=1 seek=18 conv=notrunc status=none
}
mkdir -p "${runtime}/systemd" "${runtime}/lib" "${runtime}/share/devices/a133"
aarch64_fixture "${runtime}/bin/pf-input-broker"
chmod 0755 "${runtime}/bin/pf-input-broker"
aarch64_fixture "${runtime}/lib/libpocketforge.so.1"
printf '%s\n' '[Unit]' 'Description=runtime broker unit fixture' '[Install]' \
    'WantedBy=multi-user.target' > "${runtime}/systemd/pf-input-broker.service"
printf '[identity]\nid = "a133"\n' > "${runtime}/share/devices/a133/capabilities.toml"
printf '%s\n' \
    'schema_version = 1' \
    'runtime_family = "pocketforge/a133-powervr"' \
    'runtime_abi = "1"' \
    'platform_version = "20"' \
    'supported_capabilities = ["audio", "entropy", "input", "settings"]' \
    > "${runtime}/share/platform-capabilities.toml"

# A pre-existing boot enable link for the broker (what `systemctl enable` of the
# runtime unit would create) must not survive the open install.
mkdir -p "${rootfs}/etc/systemd/system/multi-user.target.wants"
ln -s /etc/systemd/system/pf-input-broker.service \
    "${rootfs}/etc/systemd/system/multi-user.target.wants/pf-input-broker.service"
"${installer}" open "${rootfs}" "${runtime}" "${launcher}" "${unit}"
test -x "${rootfs}/usr/bin/pf-app-launch"
cmp "${runtime}/share/platform-capabilities.toml" \
    "${rootfs}/usr/share/pocketforge/platform-capabilities.toml"
cmp "${unit}" "${rootfs}/etc/systemd/system/pf-app@.service"
if find "${rootfs}/etc/systemd/system" -path '*.wants/*' -name 'pf-app@*.service' | grep -q .; then
    echo 'pf-app@.service was unexpectedly enabled' >&2
    exit 1
fi
overlay="${root}/rootfs-overlay/etc/systemd/system"
test -x "${rootfs}/usr/bin/pf-input-broker"
cmp "${runtime}/bin/pf-input-broker" "${rootfs}/usr/bin/pf-input-broker"
cmp "${runtime}/systemd/pf-input-broker.service" \
    "${rootfs}/etc/systemd/system/pf-input-broker.service"
cmp "${overlay}/pf-input-broker.service.d/10-app-session.conf" \
    "${rootfs}/etc/systemd/system/pf-input-broker.service.d/10-app-session.conf"
cmp "${overlay}/pf-shell-selected.service.d/10-input-broker.conf" \
    "${rootfs}/etc/systemd/system/pf-shell-selected.service.d/10-input-broker.conf"
cmp "${runtime}/lib/libpocketforge.so.1" \
    "${rootfs}/usr/lib/aarch64-linux-gnu/libpocketforge.so.1"
cmp "${runtime}/share/devices/a133/capabilities.toml" \
    "${rootfs}/usr/share/pocketforge/devices/a133/capabilities.toml"
test "$(stat -c %a "${rootfs}/usr/share/pocketforge/devices/a133/capabilities.toml")" = 644
test "$(stat -c %a "${rootfs}/usr/lib/aarch64-linux-gnu/libpocketforge.so.1")" = 644
if find "${rootfs}" -path '*.wants/*' -name 'pf-input-broker.service' | grep -q .; then
    echo 'pf-input-broker.service is enabled at boot (would grab the pad under pf-shell)' >&2
    exit 1
fi

# Every open input-delivery artifact is required: removing any one fails closed.
for missing in bin/pf-input-broker systemd/pf-input-broker.service \
    lib/libpocketforge.so.1 share/devices/a133/capabilities.toml; do
    mv "${runtime}/${missing}" "${tmp}/held"
    if "${installer}" open "${tmp}/scratch-rootfs" "${runtime}" "${launcher}" "${unit}" \
        >"${tmp}/missing.log" 2>&1; then
        echo "open install accepted a missing ${missing}" >&2
        exit 1
    fi
    grep -F "FATAL: A133-open default-app artifact is missing: ${runtime}/${missing}" \
        "${tmp}/missing.log" >/dev/null
    mv "${tmp}/held" "${runtime}/${missing}"
done
# A second staged descriptor, a dynamically linked broker, or a non-aarch64
# library is refused.
mkdir -p "${runtime}/share/devices/a523"
printf '[identity]\nid = "a523"\n' > "${runtime}/share/devices/a523/capabilities.toml"
if "${installer}" open "${tmp}/scratch-rootfs" "${runtime}" "${launcher}" "${unit}" >"${tmp}/neg.log" 2>&1; then
    echo 'open install accepted a second staged descriptor' >&2
    exit 1
fi
grep -F 'FATAL: expected exactly devices/a133/capabilities.toml' "${tmp}/neg.log" >/dev/null
find "${runtime}/share/devices/a523" -delete
printf 'ld-musl-aarch64.so.1' >> "${runtime}/bin/pf-input-broker"
if "${installer}" open "${tmp}/scratch-rootfs" "${runtime}" "${launcher}" "${unit}" >"${tmp}/neg.log" 2>&1; then
    echo 'open install accepted a dynamically linked broker' >&2
    exit 1
fi
grep -F "FATAL: ${runtime}/bin/pf-input-broker is dynamically linked" "${tmp}/neg.log" >/dev/null
aarch64_fixture "${runtime}/bin/pf-input-broker"
printf '\076\000' | dd of="${runtime}/lib/libpocketforge.so.1" bs=1 seek=18 conv=notrunc status=none
if "${installer}" open "${tmp}/scratch-rootfs" "${runtime}" "${launcher}" "${unit}" >"${tmp}/neg.log" 2>&1; then
    echo 'open install accepted a non-aarch64 libpocketforge' >&2
    exit 1
fi
grep -F "FATAL: ${runtime}/lib/libpocketforge.so.1 is not an aarch64 ELF (e_machine=3e00" "${tmp}/neg.log" >/dev/null
aarch64_fixture "${runtime}/lib/libpocketforge.so.1"
"${installer}" open "${tmp}/scratch-rootfs" "${runtime}" "${launcher}" "${unit}" >/dev/null

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
for leak in bin/pf-app-launch bin/pf-input-broker systemd/pf-input-broker.service \
    lib/libpocketforge.so.1 share/devices/a133/capabilities.toml; do
    mkdir -p "$(dirname "${tmp}/closed-runtime/${leak}")"
    printf 'leak\n' > "${tmp}/closed-runtime/${leak}"
    for gpu_model in ddk none; do
        if "${installer}" "${gpu_model}" "${non_open_rootfs}" \
            "${tmp}/closed-runtime" "${tmp}/closed-launcher" "${unit}" >/dev/null 2>&1; then
            echo "non-open default-app artifact leak was accepted: ${gpu_model} ${leak}" >&2
            exit 1
        fi
    done
    find "${tmp}/closed-runtime" -mindepth 1 -delete
    find "${non_open_rootfs}" -printf '%P %y %m\n' | LC_ALL=C sort > "${tmp}/after"
    cmp "${tmp}/before" "${tmp}/after"
done

test ! -e "${root}/rootfs-overlay/etc/systemd/system/pocketforge-poolsuite.service"
! grep -F 'pocketforge-poolsuite.service' "${root}/scripts/install-poolsuite.sh"
grep -F 'install-default-app-support.sh' "${rootfs_builder}" >/dev/null
grep -F 'cargo build --offline --locked --release --target "${PF_RUNTIME_TARGET}" -p pf-app-launch --bin pf-app-launch' "${dockerfile}" >/dev/null
grep -F 'pf-app-launch is dynamically linked (expected static musl)' "${dockerfile}" >/dev/null
grep -F 'pf-app-validate.rs' "${dockerfile}" >/dev/null
! grep -E 'pf-app-launch|pf-app@\.service|platform-capabilities\.toml|launcher-src|PF_APP_|pf-input-broker|libpocketforge|PF_DEVICE_DESCRIPTOR|platform-inputs' \
    "${root}/scripts/build-rootfs-a523.sh"

# The non-open launcher stages are source-free, while only launcher-open names
# the gated launcher context.
ddk_body="$(sed -n '/^FROM ${PF_CONTAINER} AS launcher-ddk$/,/^FROM ${PF_CONTAINER} AS launcher-none$/p' "${dockerfile}")"
none_body="$(sed -n '/^FROM ${PF_CONTAINER} AS launcher-none$/,/^# launcher-open/p' "${dockerfile}")"
! grep -F 'launcher-src' <<<"${ddk_body}"
! grep -F 'launcher-src' <<<"${none_body}"
test "$(grep -c '^COPY --from=launcher-src ' "${dockerfile}")" -eq 1

echo 'default-app rootfs contract: PASS (verbatim dormant unit, open-only install incl. app-session broker never enabled, libpocketforge.so.1 and devices/a133 descriptor; non-open no-op with every leak refused)'
