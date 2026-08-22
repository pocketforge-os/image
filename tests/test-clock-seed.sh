#!/bin/bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT
TEST_UID="$(id -u)"
TEST_GID="$(id -g)"

mkdir -p "${SCRATCH}/etc"
printf 'systemd-timesync:x:%s:%s:systemd Time Synchronization:/:/usr/sbin/nologin\n' \
    "${TEST_UID}" "${TEST_GID}" > "${SCRATCH}/etc/passwd"
printf 'systemd-timesync:x:%s:\n' "${TEST_GID}" > "${SCRATCH}/etc/group"

SOURCE_DATE_EPOCH=1777248000 \
    "${SRC_DIR}/scripts/seed-build-clock.sh" "${SCRATCH}"

# Mirror the builders' whole-rootfs clamp before mke2fs -d assembly.
find "${SCRATCH}" -depth -print0 | \
    xargs -0 touch --no-dereference --date='@1777248000'

CLOCK="${SCRATCH}/var/lib/systemd/timesync/clock"
test "$(stat -c %Y "${CLOCK}")" = 1777248000
test "$(stat -c %u:%g:%a "${CLOCK}")" = "${TEST_UID}:${TEST_GID}:644"
test "$(stat -c %u:%g:%a "$(dirname "${CLOCK}")")" = "${TEST_UID}:${TEST_GID}:755"
test "$(cat "${SCRATCH}/etc/pocketforge-build-epoch")" = 1777248000
test "$(stat -c %a "${SCRATCH}/etc/pocketforge-build-epoch")" = 644

stat -c 'clock mtime=%Y owner=%u:%g mode=%a' "${CLOCK}"
printf 'build epoch content=%s mode=%s\n' \
    "$(cat "${SCRATCH}/etc/pocketforge-build-epoch")" \
    "$(stat -c %a "${SCRATCH}/etc/pocketforge-build-epoch")"
