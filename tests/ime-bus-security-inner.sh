#!/usr/bin/env bash
set -euo pipefail

: "${PF_IME_TEST_ROOT:?PF_IME_TEST_ROOT is required}"
: "${PF_IME_REPO_ROOT:?PF_IME_REPO_ROOT is required}"

bus_address=unix:path=/run/pf-ime/bus
focus_file=${PF_IME_TEST_ROOT}/focus
logs=${PF_IME_TEST_ROOT}/logs
mkdir -p "${logs}"
printf 'app-a\n' > "${focus_file}"

pids=()
cleanup() {
    status=$?
    trap - EXIT INT TERM
    for pid in "${pids[@]}"; do
        if kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}"
        fi
    done
    for pid in "${pids[@]}"; do
        if kill -0 "${pid}" 2>/dev/null; then
            wait "${pid}" 2>/dev/null || status=$((status == 0 ? 1 : status))
        fi
    done
    exit "${status}"
}
trap cleanup EXIT INT TERM

wait_for_socket() {
    local socket=$1
    local owner_pid=$2
    local count
    for count in $(seq 1 100); do
        if [ -S "${socket}" ]; then
            return 0
        fi
        if ! kill -0 "${owner_pid}" 2>/dev/null; then
            echo "FAIL: process ${owner_pid} exited before creating ${socket}" >&2
            return 1
        fi
        sleep 0.05
    done
    echo "FAIL: timed out waiting for ${socket}" >&2
    return 1
}

dbus-daemon \
    --config-file="${PF_IME_REPO_ROOT}/rootfs-overlay/usr/share/pocketforge/ime/bus.conf" \
    --nofork --nopidfile --nosyslog >"${logs}/bus.log" 2>&1 &
bus_pid=$!
pids+=("${bus_pid}")
wait_for_socket /run/pf-ime/bus "${bus_pid}"

if ! timeout 3 dbus-send --bus="${bus_address}" --print-reply \
    --dest=org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.ListNames >"${logs}/early-bus-probe.log" 2>&1; then
    echo "FAIL: pf-ime uid could not complete the private-bus positive control" >&2
    sed -n '1,120p' "${logs}/early-bus-probe.log" >&2
    sed -n '1,120p' "${logs}/bus.log" >&2
    exit 1
fi

DBUS_SESSION_BUS_ADDRESS="${bus_address}" python3 -B \
    "${PF_IME_REPO_ROOT}/tests/ime-bus-contract.py" serve "${focus_file}" \
    >"${logs}/stub.log" 2>&1 &
stub_pid=$!
pids+=("${stub_pid}")

for count in $(seq 1 100); do
    if grep -Fxq READY "${logs}/stub.log"; then
        break
    fi
    if ! kill -0 "${stub_pid}" 2>/dev/null; then
        echo "FAIL: contract stub exited" >&2
        sed -n '1,120p' "${logs}/stub.log" >&2
        exit 1
    fi
    sleep 0.05
done
grep -Fxq READY "${logs}/stub.log" || {
    echo "FAIL: contract stub did not become ready" >&2
    sed -n '1,120p' "${logs}/stub.log" >&2
    sed -n '1,120p' "${logs}/bus.log" >&2
    exit 1
}

mapfile -t proxy_template < <(python3 - "${PF_IME_REPO_ROOT}/rootfs-overlay/etc/systemd/system/pf-ime-door@.service" <<'PY'
import shlex
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8").replace("\\\n", " ")
line = next(line for line in text.splitlines() if line.startswith("ExecStart="))
for arg in shlex.split(line.removeprefix("ExecStart=")):
    print(arg)
PY
)

start_proxy() {
    local app=$1
    local log=${logs}/proxy-${app}.log
    local args=()
    local arg
    for arg in "${proxy_template[@]}"; do
        args+=("${arg//%i/${app}}")
    done
    (umask 0000; exec "${args[@]}") >"${log}" 2>&1 &
    proxy_pid=$!
    pids+=("${proxy_pid}")
    wait_for_socket "/run/pf-ime-door/${app}/bus" "${proxy_pid}"
}

start_proxy app-a
proxy_a_pid=${proxy_pid}
start_proxy app-b

for app in app-a app-b; do
    socket_mode=$(stat -c %a "/run/pf-ime-door/${app}/bus")
    case "${socket_mode}" in
        *2|*3|*6|*7) ;;
        *) echo "FAIL: ${app} door socket mode ${socket_mode} is not client-writable" >&2; exit 1 ;;
    esac
done

python3 -B "${PF_IME_REPO_ROOT}/tests/ime-bus-contract.py" client \
    unix:path=/run/pf-ime-door/app-a/bus \
    unix:path=/run/pf-ime-door/app-b/bus \
    "${focus_file}"

# Positive control: the pf-ime uid can use the private bus directly.
DBUS_SESSION_BUS_ADDRESS="${bus_address}" dbus-send --print-reply \
    --dest=org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.ListNames >"${logs}/private-positive.log"
echo "PASS private_bus_pf_ime_uid_accepted: direct positive control connected"

pss_kb() {
    awk '/^Pss:/ { print $2; exit }' "/proc/$1/smaps_rollup"
}
bus_pss=$(pss_kb "${bus_pid}")
proxy_pss=$(pss_kb "${proxy_a_pid}")
combined_pss=$((bus_pss + proxy_pss))
if [ "${combined_pss}" -gt 6144 ]; then
    echo "FAIL: bus + one door proxy PSS ${combined_pss} KiB exceeds 6144 KiB" >&2
    exit 1
fi
printf 'PASS ime_bus_pss_budget: bus=%s KiB proxy=%s KiB combined=%s KiB budget=6144 KiB\n' \
    "${bus_pss}" "${proxy_pss}" "${combined_pss}"

# Re-resolve the exact shipped policy with pf-ime assigned to another numeric
# uid. The same current-uid client that passed above must then fail. This tests
# the daemon's uid policy rather than merely relying on the 0700 directory.
for pid in "${proxy_a_pid}" "${proxy_pid}" "${stub_pid}" "${bus_pid}"; do
    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}"
        if wait "${pid}" 2>/dev/null; then
            :
        else
            wait_rc=$?
            if [ "${wait_rc}" -ne 143 ]; then
                echo "WARN: terminated test process ${pid} exited ${wait_rc}" >&2
            fi
        fi
    fi
done
find /run/pf-ime -mindepth 1 -delete
awk -F: '$1 != "pf-ime" { print }' "${PF_IME_TEST_ROOT}/passwd" > "${PF_IME_TEST_ROOT}/passwd.next"
printf 'pf-ime:x:65534:65534:PocketForge input method:/nonexistent:/usr/sbin/nologin\n' \
    >> "${PF_IME_TEST_ROOT}/passwd.next"
cp "${PF_IME_TEST_ROOT}/passwd.next" "${PF_IME_TEST_ROOT}/passwd"
find "${PF_IME_TEST_ROOT}/passwd.next" -delete

dbus-daemon \
    --config-file="${PF_IME_REPO_ROOT}/rootfs-overlay/usr/share/pocketforge/ime/bus.conf" \
    --nofork --nopidfile --nosyslog >"${logs}/wrong-uid-bus.log" 2>&1 &
wrong_bus_pid=$!
pids+=("${wrong_bus_pid}")
wait_for_socket /run/pf-ime/bus "${wrong_bus_pid}"
set +e
timeout 3 dbus-send --bus="${bus_address}" --print-reply \
    --dest=org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.ListNames >"${logs}/private-wrong-uid.log" 2>&1
wrong_uid_rc=$?
set -e
if [ "${wrong_uid_rc}" -eq 0 ]; then
    echo "FAIL: private bus accepted a uid other than the configured pf-ime uid" >&2
    exit 1
fi
grep -Eqi 'AccessDenied|Rejected|auth|reset|closed|denied|did not receive a reply' \
    "${logs}/private-wrong-uid.log" || {
    echo "FAIL: wrong-uid control did not produce a refusal" >&2
    sed -n '1,80p' "${logs}/private-wrong-uid.log" >&2
    exit 1
}
echo "PASS private_bus_wrong_uid_refused: exact policy rejected the non-pf-ime uid"
