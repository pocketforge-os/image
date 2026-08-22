#!/bin/sh
# Seed systemd-timesyncd's persistent clock floor from the image build epoch.
set -eu

ROOTFS="${1:?usage: seed-build-clock.sh ROOTFS}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set by the rootfs builder}"

case "${SOURCE_DATE_EPOCH}" in
    *[!0-9]*|'')
        echo "FATAL: SOURCE_DATE_EPOCH must be a decimal timestamp" >&2
        exit 2
        ;;
esac

PASSWD_FILE="${ROOTFS}/etc/passwd"
GROUP_FILE="${ROOTFS}/etc/group"
TIMESYNC_UID="$(awk -F: '$1 == "systemd-timesync" { print $3; exit }' "${PASSWD_FILE}")"
TIMESYNC_GID="$(awk -F: '$1 == "systemd-timesync" { print $4; exit }' "${PASSWD_FILE}")"

if [ -z "${TIMESYNC_UID}" ] || [ -z "${TIMESYNC_GID}" ] || \
   ! awk -F: -v gid="${TIMESYNC_GID}" '$3 == gid { found=1 } END { exit !found }' "${GROUP_FILE}"; then
    echo "FATAL: target rootfs has no complete systemd-timesync account" >&2
    exit 1
fi

# systemd-timesyncd.service declares User=systemd-timesync and
# StateDirectory=systemd/timesync. Match that account before first boot;
# systemd will maintain the same ownership when it prepares StateDirectory.
install -d -m 0755 -o "${TIMESYNC_UID}" -g "${TIMESYNC_GID}" \
    "${ROOTFS}/var/lib/systemd/timesync"
install -m 0644 -o "${TIMESYNC_UID}" -g "${TIMESYNC_GID}" /dev/null \
    "${ROOTFS}/var/lib/systemd/timesync/clock"
printf '%s\n' "${SOURCE_DATE_EPOCH}" > "${ROOTFS}/etc/pocketforge-build-epoch"
chmod 0644 "${ROOTFS}/etc/pocketforge-build-epoch"
