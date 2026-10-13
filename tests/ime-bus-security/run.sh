#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "${script_dir}/../.." && pwd)
test_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-ime-bus.XXXXXX")

cleanup() {
    status=$?
    trap - EXIT INT TERM
    find "${test_root}" -mindepth 1 -delete
    rmdir "${test_root}"
    exit "${status}"
}
trap cleanup EXIT INT TERM

mkdir -p "${test_root}/run/pf-ime" \
    "${test_root}/run/pf-ime-door/app-a" \
    "${test_root}/run/pf-ime-door/app-b"
chmod 0700 "${test_root}/run/pf-ime"
chmod 0755 "${test_root}/run/pf-ime-door" \
    "${test_root}/run/pf-ime-door/app-a" \
    "${test_root}/run/pf-ime-door/app-b"
cp /etc/passwd "${test_root}/passwd"
printf 'pf-ime:x:%s:%s:PocketForge input method:/nonexistent:/usr/sbin/nologin\n' \
    "$(id -u)" "$(id -g)" >> "${test_root}/passwd"

bwrap_args=(
    --ro-bind / /
    --dev /dev
    --proc /proc
)
if [ -d /sys/kernel/security ]; then
    bwrap_args+=(--ro-bind /sys/kernel/security /sys/kernel/security)
fi
bwrap_args+=(
    --bind "${test_root}" "${test_root}"
    --bind "${test_root}/run" /run
    --ro-bind "${test_root}/passwd" /etc/passwd
    --setenv HOME /tmp
    --setenv PF_IME_TEST_ROOT "${test_root}"
    --setenv PF_IME_REPO_ROOT "${repo_root}"
    --chdir "${repo_root}"
    /bin/bash "${script_dir}/../ime-bus-security-inner.sh"
)
bwrap "${bwrap_args[@]}"

# Reproduce pf-app@'s mount view in a separate top-level sandbox: its own door
# is rebound into the empty tmpfs, while the other app and private bus vanish.
touch "${test_root}/run/pf-ime-door/app-a/own-door"
bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /run \
    --dir /run/pf-ime-door --dir /run/pf-ime-door/app-a \
    --ro-bind "${test_root}/run/pf-ime-door/app-a" /run/pf-ime-door/app-a \
    /bin/sh -eu -c 'test -e /run/pf-ime-door/app-a/own-door; test ! -e /run/pf-ime-door/app-b; test ! -e /run/pf-ime/bus'
echo "PASS door_cannot_reach_other_door: app-a mount view exposes only app-a"

set +e
bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /run \
    --setenv DBUS_SESSION_BUS_ADDRESS unix:path=/nonexistent/pf-no-session-bus \
    dbus-send --session --print-reply --dest=org.freedesktop.DBus \
    /org/freedesktop/DBus org.freedesktop.DBus.ListNames \
    >"${test_root}/wayland-no-bus.log" 2>&1
wayland_rc=$?
set -e
if [ "${wayland_rc}" -eq 0 ]; then
    echo "FAIL: Wayland app view unexpectedly found a session bus" >&2
    exit 1
fi
echo "PASS wayland_no_bus: no session or IME bus socket is visible"
