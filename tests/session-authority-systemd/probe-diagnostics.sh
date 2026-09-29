#!/usr/bin/env bash

one_line() {
    tr '\r\n\t ' '____'
}

collect_failed_units_and_cgroup() {
    local name="$1"

    if failed_units_output="$(docker exec "${name}" \
        systemctl --failed --no-legend 2>&1)"; then
        failed_units_rc=0
    else
        failed_units_rc=$?
    fi
    if cgroup_mount_options="$(docker exec "${name}" /bin/sh -c \
        'awk '\''$2 == "/sys/fs/cgroup" && $3 == "cgroup2" { print $4; found=1 } END { if (!found) exit 1 }'\'' /proc/mounts' \
        2>&1)"; then
        cgroup_mount_rc=0
    else
        cgroup_mount_rc=$?
    fi
}

collect_systemd_diagnostics() {
    local name="$1"

    if systemctl_wait_output="$(timeout --signal=TERM 90s \
        docker exec "${name}" systemctl is-system-running --wait 2>&1)"; then
        systemctl_wait_rc=0
    else
        systemctl_wait_rc=$?
    fi
    state="$(awk '/^(running|degraded|maintenance|initializing|starting|stopping|offline|unknown)$/ { value=$0 } END { print value }' \
        <<<"${systemctl_wait_output}")"
    state="${state:-unknown}"
    collect_failed_units_and_cgroup "${name}"
}

candidate_diagnostics_reason() {
    local failed_units_flat

    if [ "${systemctl_wait_rc}" -eq 124 ]; then
        printf 'systemctl_wait_timeout_state_%s\n' "${state}"
        return 1
    fi
    case "${state}" in
        running)
            if [ "${systemctl_wait_rc}" -ne 0 ]; then
                printf 'systemctl_wait_failed_rc_%s_output_%s\n' \
                    "${systemctl_wait_rc}" "$(one_line <<<"${systemctl_wait_output}")"
                return 1
            fi
            ;;
        degraded)
            ;;
        *)
            printf 'systemctl_wait_failed_rc_%s_output_%s\n' \
                "${systemctl_wait_rc}" "$(one_line <<<"${systemctl_wait_output}")"
            return 1
            ;;
    esac

    if [ "${failed_units_rc}" -ne 0 ]; then
        printf 'failed_units_probe_rc=%s\n' "${failed_units_rc}"
        return 1
    fi
    if grep -q '[^[:space:]]' <<<"${failed_units_output}"; then
        failed_units_flat="$(one_line <<<"${failed_units_output}")"
        printf 'failed_units:%s\n' "${failed_units_flat}"
        return 1
    fi
    if [ "${cgroup_mount_rc}" -ne 0 ]; then
        printf 'cgroup_probe_rc=%s\n' "${cgroup_mount_rc}"
        return 1
    fi
    case ",${cgroup_mount_options}," in
        *,rw,*) ;;
        *)
            printf 'cgroup_not_rw\n'
            return 1
            ;;
    esac

    printf 'none\n'
}
