#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="${root}/tests/test-session-authority-systemd.sh"
driver="${root}/tests/session-authority-systemd/drive.py"
recipe="${root}/tests/session-authority-systemd/Containerfile"
probe="${root}/tests/probe-session-authority-docker-systemd.sh"
probe_recipe="${root}/tests/session-authority-systemd/probe/Containerfile"
argv_audit="${root}/tests/session-authority-systemd/docker-argv-audit.sh"
probe_diagnostics="${root}/tests/session-authority-systemd/probe-diagnostics.sh"
remount_helper="${root}/tests/session-authority-systemd/remount-cgroup-systemd"
workflow="${root}/.github/workflows/session-authority-systemd.yml"
precondition_verifier="${root}/tests/verify-session-authority-systemd-preconditions.py"
tmp="$(mktemp -d /tmp/tsp-f3fm-211-safety.XXXXXX)"
fake_bin="${tmp}/bin"
fake_root="${tmp}/host"
fake_unapproved_root="${tmp}/unapproved-host"
call_log="${tmp}/docker-calls"
df_counter="${tmp}/df-counter"
stdout_log="${tmp}/stdout"
stderr_log="${tmp}/stderr"

cleanup() {
    find "${tmp}" -mindepth 1 -delete
    rmdir "${tmp}"
}
trap cleanup EXIT

mkdir -p \
    "${fake_bin}" \
    "${fake_root}/etc/pocketforge" \
    "${fake_root}/tmp/.X11-unix" \
    "${fake_root}/run/user" \
    "${fake_unapproved_root}/tmp/.X11-unix" \
    "${fake_unapproved_root}/run/user"
printf 'PF_RUNNER_USER=runner\n' >"${fake_root}/etc/pocketforge/ephemeral-runner.conf"
: >"${call_log}"
: >"${df_counter}"

cat >"${fake_bin}/hostname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${FAKE_HOSTNAME:?}"
EOF

cat >"${fake_bin}/loginctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    list-sessions)
        if [ "${FAKE_GRAPHICAL:-0}" -eq 1 ]; then
            echo '7 1000 owner seat0 tty2'
        else
            echo '42 1001 runner - pts/0'
        fi
        ;;
    show-session)
        property=
        for arg in "$@"; do
            case "${arg}" in --property=*) property="${arg#*=}" ;; esac
        done
        case "${property}" in
            Active) echo yes ;;
            Seat) [ "${FAKE_GRAPHICAL:-0}" -eq 0 ] || echo seat0 ;;
            Type)
                if [ "${FAKE_GRAPHICAL:-0}" -eq 1 ]; then echo wayland; else echo tty; fi
                ;;
            *) exit 2 ;;
        esac
        ;;
    *) exit 2 ;;
esac
EOF

cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    is-active)
        [ "${FAKE_DISPLAY_MANAGER:-0}" -eq 1 ] && exit 0
        exit 3
        ;;
    *) exit 2 ;;
esac
EOF

cat >"${fake_bin}/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    *gdm*|*gdm3*|*sddm*|*lightdm*|*xdm*)
        [ "${FAKE_DISPLAY_PROCESS:-0}" -eq 1 ] && exit 0
        ;;
esac
exit 1
EOF

cat >"${fake_bin}/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
[ ! -s "${FAKE_DF_COUNTER:?}" ] || count="$(<"${FAKE_DF_COUNTER}")"
count=$((count + 1))
printf '%s\n' "${count}" >"${FAKE_DF_COUNTER}"
case "${FAKE_DISK_MODE:-ample}" in
    ample) value=$((9 * 1024 * 1024 * 1024)) ;;
    preflight-low) value=$((7 * 1024 * 1024 * 1024)) ;;
    floor)
        if [ "${count}" -le 6 ]; then
            value=$((9 * 1024 * 1024 * 1024))
        else
            value=$((3 * 1024 * 1024 * 1024))
        fi
        ;;
    *) exit 2 ;;
esac
case "$*" in
    *source,size,used,avail,pcent,target*)
        printf 'Filesystem 1B-blocks Used Available Use%% Mounted on\n'
        printf '/dev/fake-cache 161061273600 151397597184 %s 94%% /var/cache/pf\n' "${value}"
        ;;
    *) printf 'Avail\n%s\n' "${value}" ;;
esac
EOF

cat >"${fake_bin}/du" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="${*: -1}"
printf '65536\t%s\n' "${path}"
EOF

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cmd=%s\n' "$*" >>"${DOCKER_CALL_LOG:?}"
case "${1:-}" in
    info)
        printf '%s\n' '{"DockerRootDir":"/var/cache/pf/docker","CgroupVersion":"2","CgroupDriver":"systemd","Architecture":"x86_64","ServerVersion":"29.0.1"}'
        ;;
    version)
        echo '29.0.1'
        ;;
    system)
        [ "${2:-}" = df ] || exit 2
        printf '%s\n' \
            'Images=total:1,active:0,size:1GB,reclaimable:500MB' \
            'Containers=total:0,active:0,size:0B,reclaimable:0B' \
            'Local_Volumes=total:0,active:0,size:0B,reclaimable:0B' \
            'Build_Cache=total:2,active:0,size:2GB,reclaimable:2GB'
        ;;
    buildx)
        case "${2:-}" in
            du) ;;
            prune) ;;
            *) exit 2 ;;
        esac
        ;;
    exec)
        case "$*" in
            *'systemctl is-system-running --wait'*)
                printf '%s\n' "${FAKE_PROBE_STATE:-running}"
                exit "${FAKE_PROBE_WAIT_RC:-0}"
                ;;
            *'systemctl --failed --no-legend'*)
                [ -z "${FAKE_PROBE_FAILED_OUTPUT:-}" ] \
                    || printf '%s\n' "${FAKE_PROBE_FAILED_OUTPUT}"
                exit "${FAKE_PROBE_FAILED_RC:-0}"
                ;;
            *'/proc/mounts'*)
                [ -z "${FAKE_PROBE_CGROUP_OPTIONS:-}" ] \
                    || printf '%s\n' "${FAKE_PROBE_CGROUP_OPTIONS}"
                exit "${FAKE_PROBE_CGROUP_RC:-0}"
                ;;
            *) exit 2 ;;
        esac
        ;;
    *) exit 2 ;;
esac
EOF

chmod +x "${fake_bin}"/*

reset_logs() {
    : >"${call_log}"
    : >"${df_counter}"
    : >"${stdout_log}"
    : >"${stderr_log}"
}

run_fake() {
    env \
        BASH_ENV=/dev/null \
        PATH="${fake_bin}:${PATH}" \
        GITHUB_ACTIONS="${FAKE_GITHUB_ACTIONS:-true}" \
        DOCKER_CALL_LOG="${call_log}" \
        FAKE_DF_COUNTER="${df_counter}" \
        FAKE_HOSTNAME="${FAKE_HOSTNAME:-mm-eph-build-0}" \
        FAKE_GRAPHICAL="${FAKE_GRAPHICAL:-0}" \
        FAKE_DISPLAY_MANAGER="${FAKE_DISPLAY_MANAGER:-0}" \
        FAKE_DISPLAY_PROCESS="${FAKE_DISPLAY_PROCESS:-0}" \
        FAKE_DISK_MODE="${FAKE_DISK_MODE:-ample}" \
        bash "${harness}" "$@"
}

run_probe_diagnostics() {
    env \
        BASH_ENV=/dev/null \
        PATH="${fake_bin}:${PATH}" \
        DOCKER_CALL_LOG="${call_log}" \
        FAKE_PROBE_STATE="${FAKE_PROBE_STATE:-running}" \
        FAKE_PROBE_WAIT_RC="${FAKE_PROBE_WAIT_RC:-0}" \
        FAKE_PROBE_FAILED_OUTPUT="${FAKE_PROBE_FAILED_OUTPUT:-}" \
        FAKE_PROBE_FAILED_RC="${FAKE_PROBE_FAILED_RC:-0}" \
        FAKE_PROBE_CGROUP_OPTIONS="${FAKE_PROBE_CGROUP_OPTIONS:-rw,nosuid,nodev,noexec}" \
        FAKE_PROBE_CGROUP_RC="${FAKE_PROBE_CGROUP_RC:-0}" \
        bash -c '
            set -euo pipefail
            source "$1"
            collect_systemd_diagnostics fixture-systemd
            if reason="$(candidate_diagnostics_reason)"; then
                result=pass
                status=0
            else
                status=$?
                result=fail
            fi
            echo "probe-diagnostics: result=${result} state=${state} failed_units_rc=${failed_units_rc} failed_units=$(one_line <<<"${failed_units_output}") cgroup_mount_rc=${cgroup_mount_rc} cgroup_mount_options=$(one_line <<<"${cgroup_mount_options}") reason=${reason}"
            exit "${status}"
        ' bash "${probe_diagnostics}"
}

run_probe_fake() {
    env \
        BASH_ENV=/dev/null \
        PATH="${fake_bin}:${PATH}" \
        GITHUB_ACTIONS=true \
        DOCKER_CALL_LOG="${call_log}" \
        FAKE_HOSTNAME=mm-eph-build-0 \
        FAKE_GRAPHICAL=0 \
        FAKE_DISPLAY_MANAGER=0 \
        FAKE_DISPLAY_PROCESS=0 \
        bash "${probe}" "$@"
}

reset_logs
if FAKE_PROBE_STATE=degraded \
    FAKE_PROBE_WAIT_RC=1 \
    FAKE_PROBE_FAILED_OUTPUT='broken.service loaded failed failed' \
    FAKE_PROBE_FAILED_RC=0 \
    FAKE_PROBE_CGROUP_OPTIONS=rw,nosuid,nodev,noexec \
    FAKE_PROBE_CGROUP_RC=0 \
    run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: degraded state with failed unit passed probe diagnostics' >&2
    exit 1
fi
grep -Fq 'result=fail' "${stdout_log}" || exit 1
grep -Fq 'reason=failed_units:broken.service_loaded_failed_failed_' "${stdout_log}" || exit 1

reset_logs
if FAKE_PROBE_STATE=running \
    FAKE_PROBE_WAIT_RC=0 \
    FAKE_PROBE_FAILED_OUTPUT='failed-unit query error' \
    FAKE_PROBE_FAILED_RC=5 \
    FAKE_PROBE_CGROUP_OPTIONS=rw,nosuid,nodev,noexec \
    FAKE_PROBE_CGROUP_RC=0 \
    run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: failed-unit probe error passed diagnostics' >&2
    exit 1
fi
grep -Fq 'result=fail' "${stdout_log}" || exit 1
grep -Fq 'reason=failed_units_probe_rc=5' "${stdout_log}" || exit 1

reset_logs
if FAKE_PROBE_STATE=running \
    FAKE_PROBE_WAIT_RC=0 \
    FAKE_PROBE_FAILED_OUTPUT='' \
    FAKE_PROBE_FAILED_RC=0 \
    FAKE_PROBE_CGROUP_OPTIONS='cgroup query failed' \
    FAKE_PROBE_CGROUP_RC=42 \
    run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: failed cgroup probe passed diagnostics' >&2
    exit 1
fi
grep -Fq 'result=fail' "${stdout_log}" || exit 1
grep -Fq 'reason=cgroup_probe_rc=42' "${stdout_log}" || exit 1

reset_logs
if FAKE_PROBE_STATE=running \
    FAKE_PROBE_WAIT_RC=0 \
    FAKE_PROBE_FAILED_OUTPUT='' \
    FAKE_PROBE_FAILED_RC=0 \
    FAKE_PROBE_CGROUP_OPTIONS=ro,nosuid,nodev,noexec \
    FAKE_PROBE_CGROUP_RC=0 \
    run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: read-only cgroup passed probe diagnostics' >&2
    exit 1
fi
grep -Fq 'result=fail' "${stdout_log}" || exit 1
grep -Fq 'reason=cgroup_not_rw' "${stdout_log}" || exit 1

reset_logs
FAKE_PROBE_STATE=running \
FAKE_PROBE_WAIT_RC=0 \
FAKE_PROBE_FAILED_OUTPUT='' \
FAKE_PROBE_FAILED_RC=0 \
FAKE_PROBE_CGROUP_OPTIONS=rw,nosuid,nodev,noexec \
FAKE_PROBE_CGROUP_RC=0 \
run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"
grep -Fq 'probe-diagnostics: result=pass state=running' "${stdout_log}" || exit 1
grep -Fq 'failed_units_rc=0 failed_units=_' "${stdout_log}" || exit 1
grep -Fq 'cgroup_mount_rc=0 cgroup_mount_options=rw,nosuid,nodev,noexec_ reason=none' \
    "${stdout_log}" || exit 1

reset_logs
FAKE_PROBE_STATE=degraded \
FAKE_PROBE_WAIT_RC=1 \
FAKE_PROBE_FAILED_OUTPUT='' \
FAKE_PROBE_FAILED_RC=0 \
FAKE_PROBE_CGROUP_OPTIONS=rw,nosuid,nodev,noexec \
FAKE_PROBE_CGROUP_RC=0 \
run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"
grep -Fq 'probe-diagnostics: result=pass state=degraded' "${stdout_log}" || exit 1
grep -Fq 'reason=none' "${stdout_log}" || exit 1

reset_logs
probe_audit_container=tsp-f3fm-211-probe-fixture-host-bind
probe_audit_label=org.pocketforge.session-authority-probe=gha-missing-missing-probe
probe_audit_image=tsp-f3fm-211-systemd-probe:gha-missing-missing-probe
probe_run_base=(
    run --detach --tty
    --name "${probe_audit_container}"
    --label "${probe_audit_label}"
    --cgroupns=private
    --network none
    --tmpfs '/run:rw,nosuid,nodev,mode=755'
    --tmpfs '/run/lock:rw,nosuid,nodev,mode=755'
)
probe_owner_base=(
    "${probe_run_base[@]}"
    --security-opt apparmor=unconfined
    --cap-add=SYS_ADMIN
)
live_owner_base=(
    run --detach --tty
    --name "${probe_audit_container}"
    --label "${probe_audit_label}"
    --hostname tsp-f3fm-211-systemd
    --cgroupns=private
    --network=none
    --tmpfs '/run:rw,nosuid,nodev,mode=755'
    --tmpfs '/run/lock:rw,nosuid,nodev,mode=755'
    --pids-limit=512
    --env=container=docker
    --security-opt apparmor=unconfined
    --cap-add SYS_ADMIN
)

expect_probe_admitted_audit_only() {
    local profile="$1"
    shift
    reset_logs
    run_probe_fake --audit-run-fixture \
        "${fake_root}" "${profile}" "${probe_audit_container}" "$@" \
        >"${stdout_log}" 2>"${stderr_log}"
    grep -Fq 'systemd-docker-probe argv-audit: PASS docker run ' \
        "${stdout_log}" || exit 1
    [ ! -s "${call_log}" ] || {
        echo "session-authority systemd-safety: FAIL: admitted probe fixture called Docker profile=${profile}" >&2
        exit 1
    }
}

expect_probe_rejected_no_docker() {
    local label="$1"
    shift
    reset_logs
    if run_probe_fake --audit-run-fixture \
        "${fake_root}" owner-exception "${probe_audit_container}" \
        "${live_owner_base[@]}" "$@" \
        "${probe_audit_image}" /usr/local/libexec/remount-cgroup-systemd \
        >"${stdout_log}" 2>"${stderr_log}"; then
        echo "session-authority systemd-safety: FAIL: probe accepted unapproved run option label=${label}" >&2
        exit 1
    fi
    grep -Fq 'UNSAFE_CONTAINER_ARGV:' "${stderr_log}" || {
        echo "session-authority systemd-safety: FAIL: probe refusal reason missing label=${label}" >&2
        cat "${stderr_log}" >&2
        exit 1
    }
    [ ! -s "${call_log}" ] || {
        echo "session-authority systemd-safety: FAIL: rejected probe option reached Docker label=${label}" >&2
        exit 1
    }
}

expect_probe_admitted_audit_only baseline-systemd \
    "${probe_run_base[@]}" "${probe_audit_image}" /sbin/init
expect_probe_admitted_audit_only positive-control \
    "${probe_run_base[@]}" --entrypoint /bin/sleep \
    "${probe_audit_image}" infinity
expect_probe_admitted_audit_only owner-exception \
    "${probe_owner_base[@]}" "${probe_audit_image}" \
    /usr/local/libexec/remount-cgroup-systemd

expect_probe_rejected_no_docker device-cgroup-rule \
    --device-cgroup-rule 'b *:* rwm'
expect_probe_rejected_no_docker root-volume -v /:/host
expect_probe_rejected_no_docker root-mount \
    --mount type=bind,source=/,target=/host
expect_probe_rejected_no_docker nonnormalized-dev-volume -v //dev:/hostdev
expect_probe_rejected_no_docker docker-socket-volume \
    -v /var/run/docker.sock:/var/run/docker.sock
expect_probe_rejected_no_docker host-ipc --ipc=host
expect_probe_rejected_no_docker host-uts --uts=host
expect_probe_rejected_no_docker other-container-pid --pid=container:other
expect_probe_rejected_no_docker host-cgroup-bind \
    --mount type=bind,source=/sys/fs/cgroup,target=/sys/fs/cgroup

reset_logs
FAKE_GRAPHICAL=1
if run_fake >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: graphical host passed guard' >&2
    exit 1
fi
FAKE_GRAPHICAL=0
grep -Fq 'INTERACTIVE_WORKSTATION: active session=7 seat=seat0 type=wayland' \
    "${stderr_log}" || exit 1
[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-safety: FAIL: graphical refusal reached Docker' >&2
    exit 1
}

reset_logs
run_fake --check-host-guard "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"
grep -Fqx \
    'session-authority host-guard: PASS host=mm-eph-build-0 ephemeral_slot=true' \
    "${stdout_log}" || exit 1

reset_logs
FAKE_DISPLAY_MANAGER=1
if run_fake --check-host-guard "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: display manager passed guard' >&2
    exit 1
fi
FAKE_DISPLAY_MANAGER=0
grep -Fq 'INTERACTIVE_WORKSTATION: active display-manager.service' "${stderr_log}" || exit 1

reset_logs
FAKE_GITHUB_ACTIONS=false
if run_fake --check-host-guard "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: non-Actions host passed guard' >&2
    exit 1
fi
FAKE_GITHUB_ACTIONS=true
grep -Fq 'UNAPPROVED_HOST: GITHUB_ACTIONS=true is required' "${stderr_log}" || exit 1

reset_logs
if run_fake --check-host-guard "${fake_unapproved_root}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: unmarked host passed guard' >&2
    exit 1
fi
grep -Fq 'UNAPPROVED_HOST: ephemeral runner marker missing' "${stderr_log}" || exit 1

python3 - "${fake_root}/tmp/.X11-unix/X77" <<'PY'
import socket
import sys

with socket.socket(socket.AF_UNIX) as display:
    display.bind(sys.argv[1])
PY
reset_logs
if run_fake --check-host-guard "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: X socket passed guard' >&2
    exit 1
fi
grep -Fq 'INTERACTIVE_WORKSTATION: graphical socket=' "${stderr_log}" || exit 1
find "${fake_root}/tmp/.X11-unix" -mindepth 1 -delete

reset_logs
FAKE_DISK_MODE=preflight-low
if run_fake --check-docker-probe "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: low Docker-root disk passed admission' >&2
    exit 1
fi
FAKE_DISK_MODE=ample
grep -Fq 'INSUFFICIENT_DISK: docker_root=/var/cache/pf/docker' "${stderr_log}" || exit 1

reset_logs
run_fake --check-docker-probe "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"
grep -Fq 'session-authority real-systemd: PASS ' "${stdout_log}" || exit 1
grep -Fq 'docker_root=/var/cache/pf/docker' "${stdout_log}" || exit 1
grep -Fq 'docker_root_free_before_bytes=9663676416' "${stdout_log}" || exit 1
grep -Fq 'docker_root_free_after_bytes=9663676416' "${stdout_log}" || exit 1
grep -Fq 'docker_root_df_before=filesystem:/dev/fake-cache,size_bytes:161061273600,used_bytes:151397597184,available_bytes:9663676416,use_percent:94%,mount:/var/cache/pf' \
    "${stdout_log}" || exit 1
grep -Fq 'docker_root_df_after=filesystem:/dev/fake-cache,size_bytes:161061273600,used_bytes:151397597184,available_bytes:9663676416,use_percent:94%,mount:/var/cache/pf' \
    "${stdout_log}" || exit 1
grep -Fq 'docker_system_df_before=Images=total:1,active:0,size:1GB,reclaimable:500MB,Containers=total:0,active:0,size:0B,reclaimable:0B,Local_Volumes=total:0,active:0,size:0B,reclaimable:0B,Build_Cache=total:2,active:0,size:2GB,reclaimable:2GB' \
    "${stdout_log}" || exit 1
grep -Fq 'run_scope_removed=true' "${stdout_log}" || exit 1
grep -Fq 'cmd=info --format {{json .}}' "${call_log}" || exit 1
grep -Fq 'cmd=version --format {{.Server.Version}}' "${call_log}" || exit 1
grep -Fq 'cmd=system df ' "${call_log}" || exit 1

reset_logs
FAKE_DISK_MODE=floor
if run_fake --check-docker-probe "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: Docker-root disk floor did not abort' >&2
    exit 1
fi
FAKE_DISK_MODE=ample
grep -Fq 'receipt_reason=DISK_FLOOR_ABORT' "${stderr_log}" || {
    cat "${stderr_log}" >&2
    exit 1
}
grep -Fq 'docker_root_min_free_bytes=3221225472' "${stderr_log}" || exit 1
grep -Fq 'run_scope_removed=true' "${stderr_log}" || exit 1

audit_id=fixture-audit
audit_label="org.pocketforge.session-authority-run=${audit_id}"
audit_container="tsp-f3fm-211-systemd-${audit_id}"
audit_image="tsp-f3fm-211-systemd:0589fcfa959d-${audit_id}"
dashdash=--
privileged_flag="${dashdash}privileged"

reset_logs
FAKE_GRAPHICAL=1
if run_fake --audit-systemd-spec "${fake_root}" "${audit_id}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: graphical host reached owner exception audit' >&2
    exit 1
fi
FAKE_GRAPHICAL=0
grep -Fq 'INTERACTIVE_WORKSTATION:' "${stderr_log}" || exit 1
[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-safety: FAIL: graphical owner exception audit reached Docker' >&2
    exit 1
}

reset_logs
if run_fake --audit-systemd-spec "${fake_unapproved_root}" "${audit_id}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: non-ephemeral host accepted owner exception' >&2
    exit 1
fi
grep -Fq 'UNAPPROVED_HOST: ephemeral runner marker missing' "${stderr_log}" || exit 1
[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-safety: FAIL: non-ephemeral owner exception audit reached Docker' >&2
    exit 1
}

reset_logs
run_fake --audit-systemd-spec "${fake_root}" "${audit_id}" \
    >"${stdout_log}" 2>"${stderr_log}"
safe_spec="$(cat "${stdout_log}")"
[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-safety: FAIL: admitted live argv audit called Docker' >&2
    exit 1
}
for required in \
    'docker run' \
    '--tty' \
    "--name ${audit_container}" \
    "--label ${audit_label}" \
    '--cgroupns=private' \
    '--network=none' \
    '--tmpfs /run:rw,nosuid,nodev,mode=755' \
    '--tmpfs /run/lock:rw,nosuid,nodev,mode=755' \
    '--security-opt apparmor=unconfined' \
    '--cap-add SYS_ADMIN' \
    '/usr/local/libexec/remount-cgroup-systemd'; do
    grep -Fq -- "${required}" "${stdout_log}" || {
        echo "session-authority systemd-safety: FAIL: safe spec missing ${required}" >&2
        exit 1
    }
done
forbidden_spec_regex="${privileged_flag}|--network([ =])host|--pid([ =])host|--cgroupns([ =])host|--device|(-v|--volume)(=| )[[:space:]]*/(dev|sys/fs/cgroup)"
if grep -Eq -- "${forbidden_spec_regex}" \
    <<<"${safe_spec}"; then
    echo 'session-authority systemd-safety: FAIL: safe Docker spec contains forbidden option' >&2
    exit 1
fi

expect_rejected() {
    local label="$1"
    shift
    if run_fake --audit-argv "${fake_root}" "${audit_id}" "$@" \
        >"${stdout_log}" 2>"${stderr_log}"; then
        echo "session-authority systemd-safety: FAIL: unsafe argv passed label=${label}" >&2
        exit 1
    fi
    grep -Eq 'UNSAFE_CONTAINER_ARGV:|UNSCOPED_CONTAINER_ARGV:' "${stderr_log}" || {
        echo "session-authority systemd-safety: FAIL: unsafe argv reason missing label=${label}" >&2
        cat "${stderr_log}" >&2
        exit 1
    }
}

safe_run_base=(
    run --detach --tty
    --name "${audit_container}"
    --label "${audit_label}"
    --cgroupns=private
    --network none
    --tmpfs '/run:rw,nosuid,nodev,mode=755'
    --tmpfs '/run/lock:rw,nosuid,nodev,mode=755'
)
safe_run=(
    "${safe_run_base[@]}"
    --security-opt apparmor=unconfined
    --cap-add SYS_ADMIN
)
expect_rejected unscoped-run run --detach --tty image
expect_rejected unscoped-build build --tag "${audit_image}" /scope
expect_rejected missing-apparmor "${safe_run_base[@]}" --cap-add SYS_ADMIN \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected missing-capability "${safe_run_base[@]}" \
    --security-opt apparmor=unconfined \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected duplicate-admin "${safe_run[@]}" --cap-add SYS_ADMIN \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected other-capability "${safe_run[@]}" --cap-add NET_ADMIN \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected tty-capability "${safe_run[@]}" --cap-add SYS_TTY_CONFIG \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected other-security-option "${safe_run[@]}" --security-opt seccomp=unconfined \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected wrong-entrypoint "${safe_run[@]}" "${audit_image}" /sbin/init
expect_rejected privilege "${safe_run[@]}" "${privileged_flag}" \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected device-tree "${safe_run[@]}" -v /dev:/dev \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected console-bind "${safe_run[@]}" --volume=/dev/console:/dev/console \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected tty-device "${safe_run[@]}" --device /dev/tty2 \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-pids "${safe_run[@]}" --pid=host \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-network "${safe_run[@]}" --network host \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-cgroup-namespace "${safe_run[@]}" --cgroupns host \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-user-namespace "${safe_run[@]}" --userns=host \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-cgroup-volume "${safe_run[@]}" \
    -v /sys/fs/cgroup:/sys/fs/cgroup \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-cgroup-mount "${safe_run[@]}" \
    --mount type=bind,source=/sys/fs/cgroup,target=/sys/fs/cgroup \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected device-mount "${safe_run[@]}" \
    --mount type=bind,source=/dev/console,target=/console \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected unscoped-full-cache-prune buildx prune --force --all

reset_logs
run_fake --audit-lifecycle-argv "${fake_root}" "${audit_id}" \
    >"${stdout_log}" 2>"${stderr_log}"
for command_pattern in \
    'docker run ' \
    'docker info ' \
    'docker version ' \
    'docker build ' \
    'docker exec ' \
    'docker logs ' \
    'docker container inspect ' \
    'docker container ls ' \
    'docker rm ' \
    'docker image inspect ' \
    'docker image ls ' \
    'docker image rm ' \
    'docker buildx du ' \
    'docker buildx prune '; do
    grep -Fq "${command_pattern}" "${stdout_log}" || {
        echo "session-authority systemd-safety: FAIL: lifecycle audit missed ${command_pattern}" >&2
        exit 1
    }
done

grep -Eq '^FROM docker[.]io/library/rust:1[.]85-bookworm@sha256:[0-9a-f]{64} AS runtime-builder$' \
    "${recipe}" || exit 1
grep -Fq 'cargo fetch --locked --offline' "${recipe}" || exit 1
grep -Fq 'cargo build --release --locked --offline' "${recipe}" || exit 1
grep -Fq 'ENV container=docker' "${recipe}" || exit 1
! grep -Fq 'container=podman' "${recipe}" || exit 1
[ "$(grep -Fc 'COPY --from=runtime-builder' "${recipe}")" -eq 2 ] || exit 1
for unit in getty@.service getty.target console-getty.service serial-getty@.service autovt@.service; do
    grep -Fq "/etc/systemd/system/${unit}" "${recipe}" || exit 1
done
grep -Fq 'ln -sf /dev/null' "${recipe}" || exit 1
grep -Fq 'COPY remount-cgroup-systemd /usr/local/libexec/remount-cgroup-systemd' \
    "${recipe}" || exit 1
grep -Fq 'COPY remount-cgroup-systemd /usr/local/libexec/remount-cgroup-systemd' \
    "${probe_recipe}" || exit 1
grep -Fqx 'mount -o remount,rw /sys/fs/cgroup' "${remount_helper}" || exit 1
grep -Fqx 'exec /sbin/init' "${remount_helper}" || exit 1

if grep -Eq '\bmknod\b|^[[:space:]]*[cb][+!]?[[:space:]]+/dev/fb0([[:space:]]|$)' \
    "${recipe}" "${root}/tests/session-authority-systemd/session-authority-test-tmpfiles.conf"; then
    echo 'session-authority systemd-safety: FAIL: framebuffer placeholder is a device node' >&2
    exit 1
fi
precondition_output="$(python3 "${precondition_verifier}")"
grep -Fqx \
    'session-authority path-preconditions: PASS conditions=1 providers=1 fb0=regular units=5' \
    <<<"${precondition_output}" || exit 1
unprovided_unit="${tmp}/unprovided.service"
printf '[Unit]\nConditionPathExists=/unprovided-test-path\n' >"${unprovided_unit}"
if python3 "${precondition_verifier}" --unit "${unprovided_unit}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: unprovided path condition passed audit' >&2
    exit 1
fi
grep -Fq 'unprovided ConditionPathExists=/unprovided-test-path' "${stderr_log}" || exit 1
! grep -Fq 'Path("/dev/fb0").touch()' "${driver}" || exit 1
grep -Fq 'framebuffer.is_file() and framebuffer.stat().st_size == 0' "${driver}" || exit 1
for invocation_field in clean_invocations crash_invocations; do
    grep -Fq "${invocation_field}=" "${driver}" || exit 1
done

! grep -Fq 'podman' "${harness}" || {
    echo 'session-authority systemd-safety: FAIL: host harness still references Podman' >&2
    exit 1
}
! grep -Fq 'mm-build-vm' "${harness}" || exit 1
! grep -Eq 'owned_build_lock|HOST_BUSY|Runner[.]Worker' "${harness}" || exit 1
grep -Fq 'GITHUB_ACTIONS:-' "${harness}" || exit 1
grep -Fq '/etc/pocketforge/ephemeral-runner.conf' "${harness}" || exit 1
grep -Fq 'OWNER DECISION (2026-09-28)' "${harness}" || exit 1
[ "$(grep -Fc -- '--cap-add SYS_ADMIN' "${harness}")" -eq 1 ] || exit 1
[ "$(grep -Fc -- '--security-opt apparmor=unconfined' "${harness}")" -eq 1 ] || exit 1
grep -Fq "runs-on: [self-hosted, pf-builder-vm]" "${workflow}" || exit 1
grep -Fq 'workflow_dispatch:' "${workflow}" || exit 1
grep -Fq 'pull_request:' "${workflow}" || exit 1
for path_pattern in \
    'tests/test-session-authority-systemd.sh' \
    'tests/session-authority-systemd/**' \
    'rootfs-overlay/etc/systemd/system/pf-app@.service'; do
    grep -Fq -- "- ${path_pattern}" "${workflow}" || exit 1
done
! grep -Fq -- "${privileged_flag}" "${probe}" || {
    echo 'session-authority systemd-safety: FAIL: probe contains prohibited privileged mode' >&2
    exit 1
}
[ "$(grep -Fc -- '--cap-add=SYS_ADMIN' "${probe}")" -eq 1 ] || {
    echo 'session-authority systemd-safety: FAIL: probe forbidden-capability datum drifted' >&2
    exit 1
}
grep -Fq 'docker_root_free_before_bytes=' "${probe}" || exit 1
grep -Fq 'docker_root_free_after_bytes=' "${probe}" || exit 1
grep -Fq 'docker_root_df_before=' "${probe}" || exit 1
grep -Fq 'docker_root_df_after=' "${probe}" || exit 1
grep -Fq 'docker_system_df_before=' "${probe}" || exit 1
grep -Fq 'docker_system_df_after=' "${probe}" || exit 1
grep -Fq 'build_cache_df_before=' "${probe}" || exit 1
grep -Fq 'build_cache_df_after=' "${probe}" || exit 1
grep -Fq 'probe_positive_control=${result}' "${probe}" || exit 1
grep -Fq -- '--entrypoint /bin/sleep' "${probe}" || exit 1
grep -Fq "'{{.State.Status}} {{.State.ExitCode}} {{.State.Error}} {{.State.Pid}}'" \
    "${probe}" || exit 1
grep -Fq 'systemctl is-system-running --wait' "${probe_diagnostics}" || exit 1
grep -Fq 'timeout --signal=TERM 90s' "${probe_diagnostics}" || exit 1
grep -Fq 'systemctl --failed --no-legend' "${probe_diagnostics}" || exit 1
grep -Fq 'docker logs --tail 40' "${probe}" || exit 1
grep -Fq 'cgroup_mount_options=' "${probe}" || exit 1
grep -Fq 'source "${fixtures}/docker-argv-audit.sh"' "${harness}" || exit 1
grep -Fq 'source "${root}/tests/session-authority-systemd/docker-argv-audit.sh"' \
    "${probe}" || exit 1
grep -Fq 'audit_docker_argv "$@"' "${probe}" || exit 1
grep -Fq 'systemd-docker-probe argv-audit: PASS docker' "${probe}" || exit 1
! grep -Fq 'probe_docker_run "$@"' "${probe}" || {
    echo 'session-authority systemd-safety: FAIL: probe audit fixture can execute Docker' >&2
    exit 1
}
! grep -Eq 'docker[[:space:]]+(run|create)([[:space:]]|$)' "${probe}" || {
    echo 'session-authority systemd-safety: FAIL: probe bypasses shared run auditor' >&2
    exit 1
}
[ "$(grep -Ec '^probe_candidate (a|e) ' "${probe}")" -eq 2 ] || exit 1
[ "$(grep -Ec '^probe_candidate ' "${probe}")" -eq 2 ] || exit 1
if grep -Eq -- 'source=/sys/fs/cgroup|src=/sys/fs/cgroup|seccomp=unconfined|systempaths=unconfined|--userns=host|nested-systemd|/usr/bin/unshare' \
    "${probe}" "${probe_recipe}"; then
    echo 'session-authority systemd-safety: FAIL: probe retains an unapproved discovery configuration' >&2
    exit 1
fi
grep -Fq 'UNSAFE_CONTAINER_ARGV: unapproved Docker run option=' \
    "${argv_audit}" || exit 1
grep -Fq 'baseline-systemd)' "${argv_audit}" || exit 1
grep -Fq 'positive-control)' "${argv_audit}" || exit 1
grep -Fq 'owner-exception)' "${argv_audit}" || exit 1
grep -Fq 'source "${root}/tests/session-authority-systemd/probe-diagnostics.sh"' \
    "${probe}" || exit 1
[ "$(grep -Fh 'collect_failed_units_and_cgroup "${name}"' \
    "${probe}" "${probe_diagnostics}" | wc -l)" -eq 2 ] || exit 1
[ "$(grep -Fc 'candidate_diagnostics_reason' "${probe}")" -eq 2 ] || exit 1
grep -Fq 'docker buildx prune --force --all' "${probe}" || exit 1
grep -Fq 'allow_full_cache_prune=1' "${harness}" || exit 1
! grep -Fq 'reason="boot_failed_$(docker logs' "${probe}" || exit 1
grep -Fq "grep -E '^(systemd-docker-probe:|probe_)'" "${workflow}" || exit 1
grep -Fq "needs.probe.outputs.candidate_e == 'pass'" "${workflow}" || exit 1
grep -Fq "needs.probe.outputs.adopted == 'e'" "${workflow}" || exit 1
grep -Fq "needs.probe.outputs.owner_exception == 'ephemeral-only'" "${workflow}" || exit 1
grep -Fqx 'STOPSIGNAL SIGRTMIN+3' "${probe_recipe}" || exit 1
grep -Fqx 'CMD ["/sbin/init"]' "${probe_recipe}" || exit 1
grep -Fq 'candidate_e=${candidate_e_result} adopted=${adopted} owner_exception=${owner_exception}' \
    "${probe}" || exit 1

echo 'session-authority systemd-safety: PASS graphical_refusal=ok ephemeral_guard=ok owner_exception=ephemeral-only exception_non_ephemeral=refused exception_graphical=refused-zero-docker other_forbidden=refused run_allowlist=ok probe_host_cgroup_bind=refused-zero-docker probe_fixture=audit-only probe_argv_audit=shared probe_matrix=approved-only docker_root_disk=ok disk_floor_abort=ok docker_metrics=before-after argv_audit=ok docker_lifecycle=ok builder_stage=ok path_preconditions=1 fb0=regular workflow=pf-builder-vm probe_positive_control=static probe_diagnostics=fake-docker getty_masks=5 runtime=fake-docker'
