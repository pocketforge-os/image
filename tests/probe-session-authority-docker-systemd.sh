#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="${root}/tests/test-session-authority-systemd.sh"
probe_recipe="${root}/tests/session-authority-systemd/probe/Containerfile"
# shellcheck source=tests/session-authority-systemd/docker-argv-audit.sh
source "${root}/tests/session-authority-systemd/docker-argv-audit.sh"
# shellcheck source=tests/session-authority-systemd/probe-diagnostics.sh
source "${root}/tests/session-authority-systemd/probe-diagnostics.sh"
label_key=org.pocketforge.session-authority-probe
run_id="gha-${GITHUB_RUN_ID:-missing}-${GITHUB_RUN_ATTEMPT:-missing}-probe"
run_id="$(printf '%s' "${run_id}" | tr -c 'A-Za-z0-9_.-' '-')"
run_label="${label_key}=${run_id}"
probe_image="tsp-f3fm-211-systemd-probe:${run_id}"
test_image="${probe_image}"
systemd_container=
docker_run_profile=
ephemeral_admitted=0
allow_full_cache_prune=0
work=
cache_before=
cache_current=
cache_created=
cache_baseline_ready=0
probe_status=1
failure_reason=UNEXPECTED_EXIT
docker_root=unknown
docker_root_probe=/
docker_root_free_before_bytes=unknown
docker_root_free_after_bytes=unknown
docker_root_df_before=unknown
docker_root_df_after=unknown
docker_system_df_before=unknown
docker_system_df_after=unknown
build_cache_df_before=unknown
build_cache_df_after=unknown
build_cache_df_expected_after=unknown
cache_records_removed=0
least_allowed=none
candidate_e_result=not_run
adopted=none
owner_exception=none
gib=$((1024 * 1024 * 1024))
disk_preflight_bytes=$((8 * gib))
disk_floor_bytes=$((4 * gib))

fail() {
    failure_reason="$*"
    echo "systemd-docker-probe: FAIL: $*" >&2
    exit 1
}

probe_docker_run() {
    audit_docker_argv "$@"
    command docker "$@"
}

case "${1:-}" in
    --audit-run-fixture)
        [ "$#" -ge 5 ] \
            || fail 'USAGE: --audit-run-fixture FIXTURE_ROOT PROFILE CONTAINER ARGV...'
        "${harness}" --check-host-guard "$2"
        ephemeral_admitted=1
        docker_run_profile="$3"
        systemd_container="$4"
        shift 4
        # FIXTURE_ROOT is caller-controlled test input. This mode may exercise
        # admission and argv validation, but it must never invoke Docker.
        audit_docker_argv "$@"
        printf 'systemd-docker-probe argv-audit: PASS docker'
        printf ' %q' "$@"
        printf '\n'
        exit 0
        ;;
esac

capture_cache_ids() {
    docker buildx du --format '{{.ID}}' 2>/dev/null \
        | awk 'NF { sub(/[*]$/, "", $1); print $1 }' \
        | sort -u >"$1"
}

capture_system_df() {
    docker system df \
        --format '{{.Type}}=total:{{.TotalCount}},active:{{.Active}},size:{{.Size}},reclaimable:{{.Reclaimable}}' \
        2>/dev/null \
        | tr ' ' '_' \
        | paste -sd, -
}

extract_build_cache_df() {
    local value="$1"
    case "${value}" in
        *Build_Cache=*) printf 'Build_Cache=%s\n' "${value##*Build_Cache=}" ;;
        *) return 1 ;;
    esac
}

capture_root_df() {
    LC_ALL=C df -B1 --output=source,size,used,avail,pcent,target "${docker_root_probe}" \
        | awk 'NR == 2 {
            printf "filesystem:%s,size_bytes:%s,used_bytes:%s,available_bytes:%s,use_percent:%s,mount:%s\n", \
                $1, $2, $3, $4, $5, $6
        }'
}

measure_free() {
    LC_ALL=C df -B1 --output=avail "${docker_root_probe}" \
        | awk 'NR == 2 { print $1; exit }'
}

require_disk_floor() {
    local phase="$1" available
    available="$(measure_free)"
    if [ "${available}" -lt "${disk_floor_bytes}" ]; then
        failure_reason=DISK_FLOOR_ABORT
        echo "systemd-docker-probe: DISK_FLOOR_ABORT phase=${phase} docker_root=${docker_root} available_bytes=${available} floor_bytes=${disk_floor_bytes}" >&2
        exit 1
    fi
}

cleanup() {
    local status=$? cache_id attempt
    local -a ids=()
    trap - EXIT INT TERM
    set +e

    readarray -t ids < <(
        docker container ls --all --quiet --filter "label=${run_label}" 2>/dev/null
    )
    [ "${#ids[@]}" -eq 0 ] || docker rm --force "${ids[@]}" >/dev/null 2>&1
    docker image rm --force "${probe_image}" >/dev/null 2>&1

    if [ "${cache_baseline_ready}" -eq 1 ] && capture_cache_ids "${cache_current}"; then
        comm -13 "${cache_before}" "${cache_current}" >"${cache_created}"
        cache_records_removed="$(awk 'NF { count++ } END { print count + 0 }' "${cache_created}")"
        while IFS= read -r cache_id; do
            [ -n "${cache_id}" ] || continue
            docker buildx prune --force --filter "id=${cache_id}" >/dev/null 2>&1 || status=1
        done <"${cache_created}"
        if [ ! -s "${cache_before}" ] \
            && [ "${build_cache_df_before}" = \
                'Build_Cache=total:0,active:0,size:0B,reclaimable:0B' ]; then
            docker buildx prune --force --all >/dev/null 2>&1 || status=1
        fi
        capture_cache_ids "${cache_current}.after" || status=1
        comm -13 "${cache_before}" "${cache_current}.after" >"${work}/cache-remaining"
        [ ! -s "${work}/cache-remaining" ] || status=1
    elif [ "${cache_baseline_ready}" -eq 1 ]; then
        status=1
    fi

    [ -z "$(docker container ls --all --quiet --filter "label=${run_label}" 2>/dev/null)" ] \
        || status=1
    [ -z "$(docker image ls --quiet --filter "label=${run_label}" 2>/dev/null)" ] \
        || status=1
    docker_root_free_after_bytes="$(measure_free 2>/dev/null)" || status=1
    docker_root_df_after="$(capture_root_df 2>/dev/null)" || status=1
    for ((attempt = 1; attempt <= 10; attempt++)); do
        docker_system_df_after="$(capture_system_df)" || status=1
        build_cache_df_after="$(extract_build_cache_df "${docker_system_df_after}")" \
            || status=1
        [ "${build_cache_df_after}" != "${build_cache_df_expected_after}" ] || break
        sleep 0.2
    done
    if [ "${build_cache_df_after}" != "${build_cache_df_expected_after}" ]; then
        status=1
        failure_reason=BUILD_CACHE_USAGE_DRIFT
    fi

    if [ -n "${work}" ] && [ -d "${work}" ]; then
        find "${work}" -mindepth 1 -delete >/dev/null 2>&1
        rmdir "${work}" >/dev/null 2>&1 || status=1
    fi
    if [ "${status}" -eq 0 ] && [ "${probe_status}" -eq 0 ]; then
        result=PASS
    else
        result=FAIL
        status=1
    fi
    echo "systemd-docker-probe: ${result} receipt_reason=${failure_reason} run_id=${run_id} docker_root=${docker_root} docker_root_free_before_bytes=${docker_root_free_before_bytes} docker_root_free_after_bytes=${docker_root_free_after_bytes} docker_root_df_before=${docker_root_df_before} docker_root_df_after=${docker_root_df_after} docker_system_df_before=${docker_system_df_before} docker_system_df_after=${docker_system_df_after} build_cache_df_before=${build_cache_df_before} build_cache_df_expected_after=${build_cache_df_expected_after} build_cache_df_after=${build_cache_df_after} build_cache_records_removed=${cache_records_removed} least_allowed=${least_allowed} candidate_e=${candidate_e_result} adopted=${adopted} owner_exception=${owner_exception} cleanup_asserted=true"
    exit "${status}"
}

# This executes only guard logic; it cannot contact Docker.
"${harness}" --check-host-guard /
ephemeral_admitted=1
for command_name in docker python3 sha256sum timeout; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || { echo "systemd-docker-probe: missing ${command_name}" >&2; exit 1; }
done

docker_info="$(docker info --format '{{json .}}')"
readarray -t info_fields < <(python3 -c '
import json, sys
info = json.load(sys.stdin)
for key in ("DockerRootDir", "ServerVersion", "CgroupVersion", "CgroupDriver"):
    print(info[key])
' <<<"${docker_info}")
docker_root="${info_fields[0]}"
docker_version="${info_fields[1]}"
cgroup_version="${info_fields[2]}"
cgroup_driver="${info_fields[3]}"
docker_root_probe="${docker_root}"
while [ ! -e "${docker_root_probe}" ]; do
    parent="$(dirname -- "${docker_root_probe}")"
    [ "${parent}" != "${docker_root_probe}" ] || exit 1
    docker_root_probe="${parent}"
done
work="$(mktemp -d /tmp/tsp-f3fm-211-probe.XXXXXX)"
cache_before="${work}/cache-before"
cache_current="${work}/cache-current"
cache_created="${work}/cache-created"
trap cleanup EXIT INT TERM
docker_root_free_before_bytes="$(measure_free)"
docker_root_df_before="$(capture_root_df)"
docker_system_df_before="$(capture_system_df)"
build_cache_df_before="$(extract_build_cache_df "${docker_system_df_before}")"
build_cache_df_expected_after="${build_cache_df_before}"
[ "${docker_root_free_before_bytes}" -ge "${disk_preflight_bytes}" ] || {
    failure_reason=INSUFFICIENT_DISK
    echo "systemd-docker-probe: INSUFFICIENT_DISK docker_root=${docker_root} available_bytes=${docker_root_free_before_bytes} required_bytes=${disk_preflight_bytes}" >&2
    exit 1
}
kernel="$(uname -r)"
capture_cache_ids "${cache_before}"
cache_baseline_ready=1

echo "systemd-docker-probe: environment docker_version=${docker_version} cgroup=${cgroup_version} cgroup_driver=${cgroup_driver} kernel=${kernel} docker_root=${docker_root} docker_root_free_before_bytes=${docker_root_free_before_bytes} docker_root_df_before=${docker_root_df_before} docker_system_df_before=${docker_system_df_before}"

docker build \
    --label "${run_label}" \
    --tag "${probe_image}" \
    --file "${probe_recipe}" \
    "$(dirname "$(dirname "${probe_recipe}")")"
require_disk_floor after-probe-build

emit_lines() {
    local prefix="$1" value="$2" line
    if [ -z "${value}" ]; then
        echo "${prefix}<empty>"
        return
    fi
    while IFS= read -r line; do
        echo "${prefix}${line}"
    done <<<"${value}"
}

inspect_container_state() {
    local name="$1" state_json parsed
    local -a parsed_fields=()

    observed_inspect=unavailable
    observed_inspect_rc=125
    observed_status=unknown
    observed_exit_code=unknown
    observed_error=unknown
    observed_pid=unknown
    observed_pid1_comm=unknown
    observed_pid1_rc=125
    observed_logs=
    observed_logs_rc=125
    observed_last_log=none

    if observed_inspect="$(docker inspect -f \
        '{{.State.Status}} {{.State.ExitCode}} {{.State.Error}} {{.State.Pid}}' \
        "${name}" 2>&1)"; then
        observed_inspect_rc=0
    else
        observed_inspect_rc=$?
    fi
    if [ "${observed_inspect_rc}" -eq 0 ] \
        && state_json="$(docker inspect --format '{{json .State}}' "${name}" 2>&1)" \
        && parsed="$(python3 -c '
import json, sys
state = json.load(sys.stdin)
for key in ("Status", "ExitCode", "Error", "Pid"):
    print(str(state.get(key, "unknown")).replace("\n", "\\n"))
' <<<"${state_json}")"; then
        readarray -t parsed_fields <<<"${parsed}"
        observed_status="${parsed_fields[0]:-unknown}"
        observed_exit_code="${parsed_fields[1]:-unknown}"
        observed_error="${parsed_fields[2]:-unknown}"
        observed_pid="${parsed_fields[3]:-unknown}"
    fi
    if observed_pid1_comm="$(docker exec "${name}" cat /proc/1/comm 2>&1)"; then
        observed_pid1_rc=0
        observed_pid1_comm="${observed_pid1_comm//$'\n'/}"
    else
        observed_pid1_rc=$?
    fi
    if observed_logs="$(docker logs --tail 40 "${name}" 2>&1)"; then
        observed_logs_rc=0
    else
        observed_logs_rc=$?
    fi
    observed_last_log="$(awk 'NF { line=$0 } END { print line }' <<<"${observed_logs}")"
    observed_last_log="${observed_last_log:-none}"
}

positive_control() {
    local name="tsp-f3fm-211-probe-${run_id}-positive" result=fail reason=none
    local output inspect_quoted
    local -a run_argv

    docker rm --force "${name}" >/dev/null 2>&1 || true
    systemd_container="${name}"
    docker_run_profile=positive-control
    run_argv=(
        run
        --detach
        --tty
        --name "${name}"
        --label "${run_label}"
        --cgroupns=private
        --network none
        --tmpfs '/run:rw,nosuid,nodev,mode=755'
        --tmpfs '/run/lock:rw,nosuid,nodev,mode=755'
        --entrypoint /bin/sleep
        "${probe_image}"
        infinity
    )
    if ! output="$(probe_docker_run "${run_argv[@]}" 2>&1)"; then
        reason="run_failed_$(one_line <<<"${output}")"
    else
        inspect_container_state "${name}"
        if [ "${observed_inspect_rc}" -ne 0 ]; then
            reason="inspect_failed_rc_${observed_inspect_rc}"
        elif [ "${observed_status}" != running ]; then
            reason="state_${observed_status}_exit_${observed_exit_code}"
        elif ! [[ "${observed_pid}" =~ ^[1-9][0-9]*$ ]]; then
            reason="invalid_pid_${observed_pid}"
        elif [ "${observed_pid1_rc}" -ne 0 ] \
            || [ "${observed_pid1_comm}" != sleep ]; then
            reason="pid1_inspection_failed_rc_${observed_pid1_rc}_comm_${observed_pid1_comm}"
        else
            result=pass
            reason=ok
        fi
    fi

    printf -v inspect_quoted '%q' "${observed_inspect:-unavailable}"
    echo "probe_positive_control=${result} docker_pid1=${observed_pid:-unknown} pid1_comm=${observed_pid1_comm:-unknown} state=${observed_status:-unknown} inspect_rc=${observed_inspect_rc:-125} inspect=${inspect_quoted} logs_rc=${observed_logs_rc:-125} reason=${reason}"
    emit_lines 'probe_positive_control_log=' "${observed_logs:-}"
    docker rm --force "${name}" >/dev/null 2>&1 || true
    require_disk_floor after-positive-control
    if [ "${result}" != pass ]; then
        failure_reason=INSPECTOR_POSITIVE_CONTROL_FAILED
        exit 1
    fi
}

probe_candidate() {
    local key="$1" adoptable="$2" description="$3" pid1_mode="$4"
    local audit_profile="$5"
    shift 5
    local name="tsp-f3fm-211-probe-${run_id}-${key}"
    local state=unknown transient_start=not_run transient_stop=not_run
    local reason=none diagnostic_reason output status=1 result=fail run_rc=0
    local diagnostics_admitted=0
    local systemctl_wait_output=not_run systemctl_wait_rc=125
    local failed_units_output=not_run failed_units_rc=125
    local cgroup_mount_options=not_run cgroup_mount_rc=125
    local transient_output=not_run transient_start_rc=125
    local transient_active_output=not_run transient_active_rc=125
    local transient_stop_output=not_run transient_stop_rc=125
    local transient_still_active_rc=125
    local initial_inspect initial_inspect_rc initial_status initial_exit_code
    local initial_error initial_pid initial_pid1_comm initial_pid1_rc
    local inspect_quoted initial_inspect_quoted last_log_flat
    local -a extra=() command=() run_argv=()

    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        extra+=("$1")
        shift
    done
    if [ "${1:-}" = -- ]; then
        shift
        command=("$@")
    fi

    docker rm --force "${name}" >/dev/null 2>&1 || true
    systemd_container="${name}"
    docker_run_profile="${audit_profile}"
    run_argv=(
        run
        --detach
        --tty
        --name "${name}"
        --label "${run_label}"
        --cgroupns=private
        --network none
        --tmpfs '/run:rw,nosuid,nodev,mode=755'
        --tmpfs '/run/lock:rw,nosuid,nodev,mode=755'
        "${extra[@]}"
        "${probe_image}"
        "${command[@]}"
    )
    if output="$(probe_docker_run "${run_argv[@]}" 2>&1)"; then
        run_rc=0
    else
        run_rc=$?
    fi

    inspect_container_state "${name}"
    initial_inspect="${observed_inspect}"
    initial_inspect_rc="${observed_inspect_rc}"
    initial_status="${observed_status}"
    initial_exit_code="${observed_exit_code}"
    initial_error="${observed_error}"
    initial_pid="${observed_pid}"
    initial_pid1_comm="${observed_pid1_comm}"
    initial_pid1_rc="${observed_pid1_rc}"

    if [ "${run_rc}" -eq 0 ]; then
        collect_systemd_diagnostics "${name}"
    else
        reason="run_failed_rc_${run_rc}_$(one_line <<<"${output}")"
    fi

    inspect_container_state "${name}"
    last_log_flat="$(one_line <<<"${observed_last_log}")"
    if [ "${run_rc}" -eq 0 ]; then
        if [ "${observed_inspect_rc}" -ne 0 ]; then
            reason="inspect_failed_rc_${observed_inspect_rc}"
        elif [ "${observed_status}" != running ]; then
            reason="container_${observed_status}_exit_${observed_exit_code}_error_$(one_line <<<"${observed_error}")_last_log_${last_log_flat}"
        elif [ "${pid1_mode}" = direct ] \
            && { [ "${observed_pid1_rc}" -ne 0 ] \
                || [ "${observed_pid1_comm}" != systemd ]; }; then
            reason="pid1_mismatch_rc_${observed_pid1_rc}_comm_$(one_line <<<"${observed_pid1_comm}")"
        elif diagnostic_reason="$(candidate_diagnostics_reason)"; then
            status=0
            diagnostics_admitted=1
            reason=none
        else
            reason="${diagnostic_reason}"
        fi
    fi

    if [ "${status}" -eq 0 ]; then
        if transient_output="$(docker exec "${name}" systemd-run --quiet \
                --unit=pf-probe-transient.service \
                --property=Type=oneshot \
                --property=RemainAfterExit=yes \
                --property=PrivateTmp=yes \
                --property=ProtectSystem=strict \
                --property=ReadOnlyPaths=/usr \
                /bin/true 2>&1)"; then
            transient_start_rc=0
        else
            transient_start_rc=$?
        fi
        if transient_active_output="$(docker exec "${name}" systemctl is-active \
            pf-probe-transient.service 2>&1)"; then
            transient_active_rc=0
        else
            transient_active_rc=$?
        fi
        if [ "${transient_start_rc}" -eq 0 ] \
            && [ "${transient_active_rc}" -eq 0 ]; then
            transient_start=pass
            if transient_stop_output="$(docker exec "${name}" systemctl stop \
                pf-probe-transient.service 2>&1)"; then
                transient_stop_rc=0
            else
                transient_stop_rc=$?
            fi
            if docker exec "${name}" systemctl is-active --quiet \
                pf-probe-transient.service >/dev/null 2>&1; then
                transient_still_active_rc=0
            else
                transient_still_active_rc=$?
            fi
            if [ "${transient_stop_rc}" -eq 0 ] \
                && [ "${transient_still_active_rc}" -ne 0 ]; then
                transient_stop=pass
            else
                transient_stop=fail
                status=1
                reason="transient_stop_failed_rc_${transient_stop_rc}_active_rc_${transient_still_active_rc}_output_$(one_line <<<"${transient_stop_output}")"
            fi
        else
            transient_start=fail
            status=1
            reason="transient_start_failed_run_rc_${transient_start_rc}_active_rc_${transient_active_rc}_run_output_$(one_line <<<"${transient_output}")_active_output_$(one_line <<<"${transient_active_output}")"
        fi
    fi

    if [ "${diagnostics_admitted}" -eq 1 ]; then
        # The post-transient failed-unit and cgroup state is part of admission.
        collect_failed_units_and_cgroup "${name}"
        if ! diagnostic_reason="$(candidate_diagnostics_reason)"; then
            status=1
            reason="${diagnostic_reason}"
        fi
    fi
    inspect_container_state "${name}"

    if [ "${status}" -eq 0 ] && [ "${observed_status}" != running ]; then
        status=1
        reason="container_${observed_status}_after_transient_exit_${observed_exit_code}_last_log_$(one_line <<<"${observed_last_log}")"
    fi

    if [ "${status}" -eq 0 ]; then
        result=pass
        if [ "${adoptable}" = yes ] && [ "${least_allowed}" = none ]; then
            least_allowed="${key}"
        fi
    fi
    if [ "${adoptable}" = no ]; then
        candidate_e_result="${result}"
    fi
    printf -v initial_inspect_quoted '%q' "${initial_inspect}"
    printf -v inspect_quoted '%q' "${observed_inspect}"
    echo "probe_candidate=${key} adoptable=${adoptable} description=${description} result=${result} systemd_scope=${pid1_mode} run_rc=${run_rc} docker_pid1=${observed_pid} pid1_comm=$(one_line <<<"${observed_pid1_comm}") pid1_comm_rc=${observed_pid1_rc} docker_state=${observed_status} docker_exit_code=${observed_exit_code} docker_error=$(one_line <<<"${observed_error}") inspect_initial_rc=${initial_inspect_rc} inspect_initial=${initial_inspect_quoted} initial_state=${initial_status} initial_exit_code=${initial_exit_code} initial_error=$(one_line <<<"${initial_error}") initial_docker_pid1=${initial_pid} initial_pid1_comm=$(one_line <<<"${initial_pid1_comm}") initial_pid1_comm_rc=${initial_pid1_rc} inspect_final_rc=${observed_inspect_rc} inspect_final=${inspect_quoted} logs_rc=${observed_logs_rc} system_state=${state} systemctl_wait_rc=${systemctl_wait_rc} systemctl_wait_output=$(one_line <<<"${systemctl_wait_output}") failed_units_rc=${failed_units_rc} failed_units=$(one_line <<<"${failed_units_output}") cgroup_mount_rc=${cgroup_mount_rc} cgroup_mount_options=$(one_line <<<"${cgroup_mount_options}") transient_sandbox=private-tmp-protect-system transient_start=${transient_start} transient_start_rc=${transient_start_rc} transient_active_rc=${transient_active_rc} transient_stop=${transient_stop} transient_stop_rc=${transient_stop_rc} reason=${reason}"
    emit_lines "probe_candidate_log=${key} " "${observed_logs}"
    docker rm --force "${name}" >/dev/null 2>&1 || true
    require_disk_floor "after-candidate-${key}"
}

# Permanent approved-only matrix: harmless positive control, baseline candidate
# a, and owner-approved ephemeral-only candidate e. The broader discovery matrix
# from workflow run 36498172908 is history and must not be reintroduced here.
positive_control
probe_candidate a yes private-cgroupns-tmpfs-pty direct baseline-systemd \
    -- /sbin/init
probe_candidate e no owner-exception-ephemeral-only-cap-sys-admin-cgroup-remount direct owner-exception \
    --security-opt apparmor=unconfined \
    --cap-add=SYS_ADMIN \
    -- /usr/local/libexec/remount-cgroup-systemd

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'least_allowed=%s\n' "${least_allowed}" >>"${GITHUB_OUTPUT}"
    printf 'candidate_e=%s\n' "${candidate_e_result}" >>"${GITHUB_OUTPUT}"
fi
[ "${candidate_e_result}" = pass ] || {
    failure_reason=OWNER_EXCEPTION_CANDIDATE_E_FAILED
    exit 1
}
adopted=e
owner_exception=ephemeral-only
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'adopted=%s\n' "${adopted}" >>"${GITHUB_OUTPUT}"
    printf 'owner_exception=%s\n' "${owner_exception}" >>"${GITHUB_OUTPUT}"
fi
failure_reason=completed
probe_status=0
