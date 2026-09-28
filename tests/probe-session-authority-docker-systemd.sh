#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="${root}/tests/test-session-authority-systemd.sh"
probe_recipe="${root}/tests/session-authority-systemd/probe/Containerfile"
label_key=org.pocketforge.session-authority-probe
run_id="gha-${GITHUB_RUN_ID:-missing}-${GITHUB_RUN_ATTEMPT:-missing}-probe"
run_id="$(printf '%s' "${run_id}" | tr -c 'A-Za-z0-9_.-' '-')"
run_label="${label_key}=${run_id}"
probe_image="tsp-f3fm-211-systemd-probe:${run_id}"
work="$(mktemp -d /tmp/tsp-f3fm-211-probe.XXXXXX)"
cache_before="${work}/cache-before"
cache_current="${work}/cache-current"
cache_created="${work}/cache-created"
probe_status=1
docker_root=unknown
docker_root_probe=/
docker_root_free_before_bytes=unknown
docker_root_free_after_bytes=unknown
docker_root_df_before=unknown
docker_root_df_after=unknown
docker_system_df_before=unknown
docker_system_df_after=unknown
cache_records_removed=0
least_allowed=none
forbidden_result=not_run
gib=$((1024 * 1024 * 1024))
disk_preflight_bytes=$((8 * gib))
disk_floor_bytes=$((4 * gib))

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
        echo "systemd-docker-probe: DISK_FLOOR_ABORT phase=${phase} docker_root=${docker_root} available_bytes=${available} floor_bytes=${disk_floor_bytes}" >&2
        exit 1
    fi
}

cleanup() {
    local status=$? cache_id
    local -a ids=()
    trap - EXIT INT TERM
    set +e

    readarray -t ids < <(
        docker container ls --all --quiet --filter "label=${run_label}" 2>/dev/null
    )
    [ "${#ids[@]}" -eq 0 ] || docker rm --force "${ids[@]}" >/dev/null 2>&1
    docker image rm --force "${probe_image}" >/dev/null 2>&1

    if capture_cache_ids "${cache_current}"; then
        comm -13 "${cache_before}" "${cache_current}" >"${cache_created}"
        cache_records_removed="$(awk 'NF { count++ } END { print count + 0 }' "${cache_created}")"
        while IFS= read -r cache_id; do
            [ -n "${cache_id}" ] || continue
            docker buildx prune --force --filter "id=${cache_id}" >/dev/null 2>&1 || status=1
        done <"${cache_created}"
        capture_cache_ids "${cache_current}.after" || status=1
        comm -13 "${cache_before}" "${cache_current}.after" >"${work}/cache-remaining"
        [ ! -s "${work}/cache-remaining" ] || status=1
    else
        status=1
    fi

    [ -z "$(docker container ls --all --quiet --filter "label=${run_label}" 2>/dev/null)" ] \
        || status=1
    [ -z "$(docker image ls --quiet --filter "label=${run_label}" 2>/dev/null)" ] \
        || status=1
    docker_root_free_after_bytes="$(measure_free 2>/dev/null)" || status=1
    docker_root_df_after="$(capture_root_df 2>/dev/null)" || status=1
    docker_system_df_after="$(capture_system_df)" || status=1

    find "${work}" -mindepth 1 -delete >/dev/null 2>&1
    rmdir "${work}" >/dev/null 2>&1 || status=1
    if [ "${status}" -eq 0 ] && [ "${probe_status}" -eq 0 ]; then
        result=PASS
    else
        result=FAIL
        status=1
    fi
    echo "systemd-docker-probe: ${result} run_id=${run_id} docker_root=${docker_root} docker_root_free_before_bytes=${docker_root_free_before_bytes} docker_root_free_after_bytes=${docker_root_free_after_bytes} docker_root_df_before=${docker_root_df_before} docker_root_df_after=${docker_root_df_after} docker_system_df_before=${docker_system_df_before} docker_system_df_after=${docker_system_df_after} build_cache_records_removed=${cache_records_removed} least_allowed=${least_allowed} forbidden_cap_sys_admin=${forbidden_result} cleanup_asserted=true"
    exit "${status}"
}

# This executes only guard logic; it cannot contact Docker.
"${harness}" --check-host-guard /
for command_name in docker python3 sha256sum; do
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
docker_root_free_before_bytes="$(measure_free)"
[ "${docker_root_free_before_bytes}" -ge "${disk_preflight_bytes}" ] || {
    echo "systemd-docker-probe: INSUFFICIENT_DISK docker_root=${docker_root} available_bytes=${docker_root_free_before_bytes} required_bytes=${disk_preflight_bytes}" >&2
    exit 1
}
docker_root_df_before="$(capture_root_df)"
docker_system_df_before="$(capture_system_df)"
kernel="$(uname -r)"
capture_cache_ids "${cache_before}"
trap cleanup EXIT INT TERM

echo "systemd-docker-probe: environment docker_version=${docker_version} cgroup=${cgroup_version} cgroup_driver=${cgroup_driver} kernel=${kernel} docker_root=${docker_root} docker_root_free_before_bytes=${docker_root_free_before_bytes} docker_root_df_before=${docker_root_df_before} docker_system_df_before=${docker_system_df_before}"

docker build \
    --label "${run_label}" \
    --tag "${probe_image}" \
    --file "${probe_recipe}" \
    "$(dirname "${probe_recipe}")"
require_disk_floor after-probe-build

probe_candidate() {
    local key="$1" adoptable="$2" description="$3" pid1_mode="$4"
    shift 4
    local name="tsp-f3fm-211-probe-${run_id}-${key}"
    local state=unreachable transient_start=not_run transient_stop=not_run
    local reason=none output transient_output status=1 pid1_comm=unknown
    local -a extra=() command=()

    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        extra+=("$1")
        shift
    done
    if [ "${1:-}" = -- ]; then
        shift
        command=("$@")
    fi

    docker rm --force "${name}" >/dev/null 2>&1 || true
    if ! output="$(docker run --detach --tty \
        --name "${name}" \
        --label "${run_label}" \
        --cgroupns=private \
        --network none \
        --tmpfs /run:rw,nosuid,nodev,mode=755 \
        --tmpfs /run/lock:rw,nosuid,nodev,mode=755 \
        "${extra[@]}" \
        "${probe_image}" \
        "${command[@]}" 2>&1)"; then
        reason="run_failed_$(tr '\n ' '__' <<<"${output}" | cut -c1-240)"
    else
        for _ in $(seq 1 100); do
            state="$(docker exec "${name}" systemctl is-system-running 2>/dev/null || true)"
            case "${state}" in
                running|degraded) status=0; break ;;
            esac
            [ "$(docker inspect --format '{{.State.Running}}' "${name}" 2>/dev/null)" = true ] \
                || break
            sleep 0.1
        done
        pid1_comm="$(docker exec "${name}" cat /proc/1/comm 2>/dev/null || true)"
        if [ "${pid1_mode}" = direct ] && [ "${pid1_comm}" != systemd ]; then
            status=1
            reason="docker_pid1_is_${pid1_comm:-missing}"
        fi
        if [ "${status}" -eq 0 ]; then
            if transient_output="$(docker exec "${name}" systemd-run --quiet \
                --unit=pf-probe-transient.service \
                --property=Type=oneshot \
                --property=RemainAfterExit=yes \
                --property=PrivateTmp=yes \
                --property=ProtectSystem=strict \
                --property=ReadOnlyPaths=/usr \
                /bin/true 2>&1)" \
                && docker exec "${name}" systemctl is-active --quiet \
                    pf-probe-transient.service; then
                transient_start=pass
                if docker exec "${name}" systemctl stop pf-probe-transient.service \
                    >/dev/null 2>&1 \
                    && ! docker exec "${name}" systemctl is-active --quiet \
                        pf-probe-transient.service; then
                    transient_stop=pass
                else
                    transient_stop=fail
                    status=1
                    reason="transient_stop_failed_$(docker exec "${name}" systemctl status --no-pager pf-probe-transient.service 2>&1 | tail -n 8 | tr '\n ' '__' | cut -c1-240)"
                fi
            else
                transient_start=fail
                status=1
                reason="transient_start_failed_$(printf '%s' "${transient_output}" | tr '\n ' '__' | cut -c1-240)"
            fi
        else
            reason="boot_failed_$(docker logs "${name}" 2>&1 | tail -n 12 \
                | tr '\n ' '__' | cut -c1-240)"
        fi
    fi
    docker rm --force "${name}" >/dev/null 2>&1 || true
    require_disk_floor "after-candidate-${key}"

    if [ "${status}" -eq 0 ]; then
        result=pass
        if [ "${adoptable}" = yes ] && [ "${least_allowed}" = none ]; then
            least_allowed="${key}"
        fi
    else
        result=fail
    fi
    if [ "${adoptable}" = no ]; then
        forbidden_result="${result}"
    fi
    echo "probe_candidate=${key} adoptable=${adoptable} description=${description} docker_pid1=${pid1_comm:-unknown} systemd_scope=${pid1_mode} result=${result} system_state=${state:-unknown} transient_sandbox=private-tmp-protect-system transient_start=${transient_start} transient_stop=${transient_stop} reason=${reason}"
}

# Least privilege first. Candidate e is evidence only and can never be selected.
probe_candidate a yes private-cgroupns-tmpfs-pty direct
probe_candidate b yes private-cgroupns-rw-cgroup-bind direct \
    --mount type=bind,source=/sys/fs/cgroup,target=/sys/fs/cgroup
probe_candidate c-seccomp yes private-cgroupns-seccomp-unconfined direct \
    --security-opt seccomp=unconfined
probe_candidate c-apparmor yes private-cgroupns-apparmor-unconfined direct \
    --security-opt apparmor=unconfined
probe_candidate c-systempaths yes private-cgroupns-systempaths-unconfined direct \
    --security-opt systempaths=unconfined
probe_candidate c-userns yes private-cgroupns-userns-host direct \
    --userns=host
probe_candidate d yes nested-user-pid-namespace-systemd inner \
    -- /usr/local/libexec/nested-systemd
probe_candidate d-seccomp yes nested-user-pid-namespace-seccomp-unconfined inner \
    --security-opt seccomp=unconfined \
    -- /usr/local/libexec/nested-systemd
probe_candidate d-apparmor yes nested-user-pid-namespace-apparmor-unconfined inner \
    --security-opt apparmor=unconfined \
    -- /usr/local/libexec/nested-systemd
probe_candidate d-unconfined yes nested-user-pid-namespace-security-unconfined inner \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    -- /usr/local/libexec/nested-systemd
probe_candidate e no forbidden-cap-sys-admin-measurement direct \
    --cap-add=SYS_ADMIN

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'least_allowed=%s\n' "${least_allowed}" >>"${GITHUB_OUTPUT}"
fi
[ "${least_allowed}" != none ] || exit 1
probe_status=0
