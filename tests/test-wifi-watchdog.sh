#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
watchdog="${repo_dir}/rootfs-overlay/usr/lib/pocketforge/wifi-watchdog.sh"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-wifi-watchdog.XXXXXX")"
trap 'find "${scratch}" -mindepth 1 -delete; rmdir "${scratch}"' EXIT

failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

command -v bwrap >/dev/null 2>&1 || {
    echo "BLOCKED: bwrap is required" >&2
    exit 75
}

mkdir -p "${scratch}/bin"

cat >"${scratch}/bin/sleep" <<'EOF'
#!/bin/sh
set -u
count_file="${PF_TEST_STATE}/sleep-count"
count=0
[ ! -f "${count_file}" ] || read -r count <"${count_file}"
count=$((count + 1))
printf '%s\n' "${count}" >"${count_file}"

# Bound the no-restart cases after four complete health checks. Recovery is
# bounded by the fake systemctl below before its grace sleep is reached.
if [ "${count}" -gt 4 ]; then
    kill -TERM "${PPID}"
fi
EOF

cat >"${scratch}/bin/ip" <<'EOF'
#!/bin/sh
set -u
case "$*" in
    '-4 -o addr show dev wlan0 scope global')
        count_file="${PF_TEST_STATE}/addr-count"
        count=0
        [ ! -f "${count_file}" ] || read -r count <"${count_file}"
        count=$((count + 1))
        printf '%s\n' "${count}" >"${count_file}"
        if [ "${PF_TEST_CASE}" = "lease-then-loss" ] && [ "${count}" -eq 1 ]; then
            printf '%s\n' '3: wlan0 inet 192.0.2.10/24 scope global dynamic wlan0'
        fi
        ;;
    '-4 route show default')
        # No route is intentional: a held lease remains healthy while networkd
        # finishes route installation, and lease loss is still authoritative.
        ;;
    *)
        echo "unexpected ip invocation: $*" >&2
        exit 64
        ;;
esac
EOF

cat >"${scratch}/bin/ping" <<'EOF'
#!/bin/sh
echo "unexpected ping invocation" >&2
exit 64
EOF

cat >"${scratch}/bin/systemctl" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >>"${PF_TEST_STATE}/systemctl.log"
# The recovery action is the observation this case needs; terminate before the
# production loop enters its real-time DHCP grace period.
kill -TERM "${PPID}"
EOF

chmod 0755 "${scratch}/bin/sleep" "${scratch}/bin/ip" \
    "${scratch}/bin/ping" "${scratch}/bin/systemctl"

run_case() {
    local name="$1"
    local interface="$2"
    local expected_restarts="$3"
    local state="${scratch}/${name}"
    local sys="${state}/sys"
    local output="${state}/watchdog.log"
    local rc restart_count

    mkdir -p "${state}" "${sys}/class/net"
    if [[ ${interface} == present ]]; then
        mkdir -p "${sys}/class/net/wlan0"
    fi

    set +e
    bwrap \
        --die-with-parent \
        --unshare-all \
        --ro-bind / / \
        --dev /dev \
        --bind "${state}" "${state}" \
        --bind "${sys}" /sys \
        --setenv PATH "${scratch}/bin:/usr/bin:/bin" \
        --setenv PF_TEST_CASE "${name}" \
        --setenv PF_TEST_STATE "${state}" \
        -- /bin/sh "${watchdog}" >"${output}" 2>&1
    rc=$?
    set -e

    if [[ ${rc} -ne 143 ]]; then
        fail "${name}: watchdog did not stop at the harness bound (rc=${rc})"
        sed 's/^/  watchdog: /' "${output}" >&2
    fi

    restart_count=0
    if [[ -f ${state}/systemctl.log ]]; then
        restart_count="$(awk \
            '$0 == "restart wpa_supplicant@wlan0.service" { count++ } END { print count + 0 }' \
            "${state}/systemctl.log")"
    fi
    if [[ ${restart_count} -ne ${expected_restarts} ]]; then
        fail "${name}: expected ${expected_restarts} supplicant restarts, got ${restart_count}"
    else
        echo "PASS: ${name} restarts=${restart_count}"
    fi
}

# Regression: an associated/present interface that has never held a lease must
# remain in initial acquisition even after the existing three-check threshold.
run_case initial-acquisition present 0

# Positive control: after one observed lease, three consecutive lease losses
# must retain the existing bounded recovery action.
run_case lease-then-loss present 1

# Negative control: absent hardware never reaches health probes or recovery.
run_case absent-interface absent 0

if [[ ${failures} -ne 0 ]]; then
    echo "wifi-watchdog-test=FAIL failures=${failures}" >&2
    exit 1
fi

echo 'wifi-watchdog-test=PASS initial-acquisition=held lease-loss=restarted absent-interface=ignored'
