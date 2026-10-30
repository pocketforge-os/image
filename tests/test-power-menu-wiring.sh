#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dockerfile="${root}/build/Dockerfile.pf"
builder="${root}/scripts/build-rootfs.sh"
shell_unit="${root}/rootfs-overlay/etc/systemd/system/pf-shell-selected.service"

for needle in \
    '-p pf-powerd --bin pf-powerd' \
    'install -D -m 0755 "${POWERD_BIN}" /out/bin/pf-powerd' \
    'install -D -m 0644 systemd/pf-powerd.service /out/systemd/pf-powerd.service'; do
    grep -F -- "${needle}" "${dockerfile}" >/dev/null
done

for needle in \
    'install -D -m 0755 "${POWERD_BIN}" "${ROOTFS}/usr/bin/pf-powerd"' \
    '"${ROOTFS}/etc/systemd/system/pf-powerd.service"' \
    '"${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-powerd.service"'; do
    grep -F -- "${needle}" "${builder}" >/dev/null
done

grep -Fx 'Wants=pf-powerd.service' "${shell_unit}" >/dev/null
grep -E '^After=.*[[:space:]]pf-powerd\.service([[:space:]]|$)' "${shell_unit}" >/dev/null
grep -Fx 'Environment=PF_POWER_SOCK=/run/pocketforge-power/power.sock' "${shell_unit}" >/dev/null

policy="${root}/rootfs-overlay/etc/systemd/logind.conf.d/60-pocketforge-power-key.conf"
grep -Fx 'HandlePowerKey=ignore' "${policy}" >/dev/null
grep -Fx 'HandlePowerKeyLongPress=poweroff' "${policy}" >/dev/null
grep -F '"${ROOTFS}/etc/systemd/logind.conf.d/60-pocketforge-power-key.conf"' "${builder}" >/dev/null

echo 'PASS power menu authority is built, installed, enabled, and ordered before pf-shell'
