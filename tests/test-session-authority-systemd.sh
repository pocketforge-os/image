#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="${root}/tests/session-authority-systemd"
app_unit="${root}/rootfs-overlay/etc/systemd/system/pf-app@.service"
owner_dropin="${root}/rootfs-overlay/etc/systemd/system/pocketforge-foreground.target.d/10-owner-shell.conf"
containerfile="${fixtures}/Containerfile"
ephemeral_marker=/etc/pocketforge/ephemeral-runner.conf
run_label_key=org.pocketforge.session-authority-run

runtime_sha=0589fcfa959dca9150563ef0ed18d7d44b420dc5
runtime_repository=https://github.com/pocketforge-os/runtime.git
app_unit_sha256=ecf620a219af3ca98760707e111fe301e420a9ba977a98ba149187a3bf6f622f
gib=$((1024 * 1024 * 1024))
disk_preflight_bytes=$((8 * gib))
disk_floor_bytes=$((4 * gib))

scope_initialized=0
cleanup_active=0
cleanup_docker_resources=0
docker_disk_configured=0
run_started=0
run_completed=0
cleanup_failed=0
failure_reason=
docker_root_min_free_bytes=
docker_root_free_before_bytes=
docker_root_free_after_bytes=
docker_root_df_before=
docker_root_df_after=
docker_system_df_before=
docker_system_df_after=
build_cache_df_before=
build_cache_df_after=
run_scope_peak_bytes=0
build_cache_records_removed=0
allow_full_cache_prune=0
run_scope=
docker_root=
docker_root_probe=
run_id=
run_label=
systemd_container=
test_image=
pass_fields=

record_failure_reason() {
    local reason="$1"
    failure_reason="${reason}"
    if [ "${scope_initialized}" -eq 1 ] && [ -d "${run_scope}" ]; then
        printf '%s\n' "${reason}" >"${run_scope}/failure-reason" 2>/dev/null || true
    fi
}

fail() {
    record_failure_reason "$*"
    echo "session-authority real-systemd: FAIL: $*" >&2
    exit 1
}

fail_recorded_or() {
    local fallback="$1"
    if [ "${scope_initialized}" -eq 1 ] && [ -s "${run_scope}/failure-reason" ]; then
        fail "$(<"${run_scope}/failure-reason")"
    fi
    fail "${fallback}"
}

assert_safe_host() {
    local fixture_root="${1:-/}"
    local session_list session_id active seat session_type display_manager socket_path status

    for guard_command in hostname loginctl pgrep systemctl; do
        command -v "${guard_command}" >/dev/null 2>&1 \
            || fail "HOST_GUARD_UNAVAILABLE: ${guard_command}"
    done

    guard_hostname="$(hostname -s 2>/dev/null)" \
        || fail 'HOST_GUARD_UNAVAILABLE: hostname'
    if ! session_list="$(loginctl list-sessions --no-legend --no-pager 2>/dev/null)"; then
        fail 'HOST_GUARD_UNAVAILABLE: loginctl list-sessions'
    fi

    while read -r session_id _; do
        [ -n "${session_id}" ] || continue
        active="$(loginctl show-session "${session_id}" --property=Active --value 2>/dev/null)" \
            || fail "HOST_GUARD_UNAVAILABLE: loginctl session=${session_id} property=Active"
        seat="$(loginctl show-session "${session_id}" --property=Seat --value 2>/dev/null)" \
            || fail "HOST_GUARD_UNAVAILABLE: loginctl session=${session_id} property=Seat"
        session_type="$(loginctl show-session "${session_id}" --property=Type --value 2>/dev/null)" \
            || fail "HOST_GUARD_UNAVAILABLE: loginctl session=${session_id} property=Type"
        if [ "${active}" = yes ] \
            && { [ -n "${seat}" ] || [ "${session_type}" = x11 ] || [ "${session_type}" = wayland ]; }; then
            fail "INTERACTIVE_WORKSTATION: active session=${session_id} seat=${seat:-none} type=${session_type:-unknown}"
        fi
    done <<<"${session_list}"

    if systemctl is-active --quiet display-manager.service 2>/dev/null; then
        fail 'INTERACTIVE_WORKSTATION: active display-manager.service'
    else
        status=$?
        case "${status}" in
            3|4) ;;
            *) fail "HOST_GUARD_UNAVAILABLE: display-manager query status=${status}" ;;
        esac
    fi
    for display_manager in gdm gdm3 sddm lightdm xdm; do
        if pgrep -x "${display_manager}" >/dev/null 2>&1; then
            fail "INTERACTIVE_WORKSTATION: running display manager=${display_manager}"
        else
            status=$?
            [ "${status}" -eq 1 ] \
                || fail "HOST_GUARD_UNAVAILABLE: pgrep display manager=${display_manager}"
        fi
    done

    for socket_path in \
        "${fixture_root%/}/tmp/.X11-unix/"X* \
        "${fixture_root%/}/run/user/"*/wayland-*; do
        [ -S "${socket_path}" ] || continue
        fail "INTERACTIVE_WORKSTATION: graphical socket=${socket_path}"
    done
}

assert_ephemeral_slot() {
    local fixture_root="${1:-/}"
    local marker="${fixture_root%/}${ephemeral_marker}"

    [ "${GITHUB_ACTIONS:-}" = true ] \
        || fail 'UNAPPROVED_HOST: GITHUB_ACTIONS=true is required'
    [ -f "${marker}" ] \
        || fail "UNAPPROVED_HOST: ephemeral runner marker missing path=${marker}"
}

configure_run_identity() {
    local requested="$1"

    run_id="$(printf '%s' "${requested}" | tr -c 'A-Za-z0-9_.-' '-')"
    [ -n "${run_id}" ] || fail 'INVALID_RUN_ID: empty'
    run_label="${run_label_key}=${run_id}"
    systemd_container="tsp-f3fm-211-systemd-${run_id}"
    test_image="tsp-f3fm-211-systemd:${runtime_sha:0:12}-${run_id}"
}

configure_docker_root() {
    local candidate="$1" parent

    case "${candidate}" in
        /*) ;;
        *) fail "DOCKER_INFO_UNREADABLE: non-absolute DockerRootDir=${candidate}" ;;
    esac
    docker_root="${candidate%/}"
    docker_root_probe="${docker_root}"
    while [ ! -e "${docker_root_probe}" ]; do
        parent="$(dirname -- "${docker_root_probe}")"
        [ "${parent}" != "${docker_root_probe}" ] \
            || fail "DOCKER_DATA_ROOT_UNAVAILABLE: path=${docker_root}"
        docker_root_probe="${parent}"
    done
    docker_disk_configured=1
}

measure_docker_root_free_bytes() {
    local value
    value="$(LC_ALL=C df -B1 --output=avail "${docker_root_probe}" 2>/dev/null \
        | awk 'NR == 2 { print $1; exit }')" || return 1
    [[ "${value}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${value}"
}

capture_docker_root_df() {
    LC_ALL=C df -B1 --output=source,size,used,avail,pcent,target "${docker_root_probe}" \
        | awk 'NR == 2 {
            printf "filesystem:%s,size_bytes:%s,used_bytes:%s,available_bytes:%s,use_percent:%s,mount:%s\n", \
                $1, $2, $3, $4, $5, $6
        }'
}

measure_run_scope_bytes() {
    local value=0
    if [ -d "${run_scope}" ]; then
        value="$(du -sb -- "${run_scope}" 2>/dev/null | awk 'NR == 1 { print $1; exit }')" \
            || return 1
    fi
    [[ "${value}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${value}"
}

sample_disk() {
    local phase="$1" free_bytes scope_bytes

    [ "${docker_disk_configured}" -eq 1 ] || return 0
    if ! free_bytes="$(measure_docker_root_free_bytes)" \
        || ! scope_bytes="$(measure_run_scope_bytes)"; then
        if [ "${cleanup_active}" -eq 1 ]; then
            cleanup_failed=1
            return 1
        fi
        fail "DISK_PROBE_FAILED: phase=${phase} docker_root=${docker_root}"
    fi
    if [ -z "${docker_root_min_free_bytes}" ] \
        || [ "${free_bytes}" -lt "${docker_root_min_free_bytes}" ]; then
        docker_root_min_free_bytes="${free_bytes}"
    fi
    if [ "${scope_bytes}" -gt "${run_scope_peak_bytes}" ]; then
        run_scope_peak_bytes="${scope_bytes}"
    fi

    [ "${cleanup_active}" -eq 0 ] || return 0
    if [ "${run_started}" -eq 0 ]; then
        [ "${free_bytes}" -ge "${disk_preflight_bytes}" ] \
            || fail "INSUFFICIENT_DISK: docker_root=${docker_root} available_bytes=${free_bytes} required_bytes=${disk_preflight_bytes}"
    else
        [ "${free_bytes}" -ge "${disk_floor_bytes}" ] \
            || fail "DISK_FLOOR_ABORT: phase=${phase} docker_root=${docker_root} available_bytes=${free_bytes} floor_bytes=${disk_floor_bytes}"
    fi
}

reject_device_volume() {
    local value="$1"
    local source_path="${value%%:*}"
    case "${source_path}" in
        /dev|/dev/*) fail "UNSAFE_CONTAINER_ARGV: host device bind=${value}" ;;
    esac
}

argv_has() {
    local expected="$1"
    shift
    local item
    for item in "$@"; do
        [ "${item}" != "${expected}" ] || return 0
    done
    return 1
}

argv_has_option_value() {
    local option="$1" expected="$2"
    shift 2
    local -a argv=("$@")
    local index
    for ((index = 0; index < ${#argv[@]}; index++)); do
        case "${argv[index]}" in
            "${option}") [ "${argv[index + 1]-}" = "${expected}" ] && return 0 ;;
            "${option}=${expected}") return 0 ;;
        esac
    done
    return 1
}

audit_docker_argv() {
    local -a argv=("$@")
    local dashdash=--
    local privileged_option="${dashdash}privileged"
    local volume_option="${dashdash}volume"
    local mount_option="${dashdash}mount"
    local device_option="${dashdash}device"
    local capability_option="${dashdash}cap-add"
    local pid_option="${dashdash}pid"
    local network_option="${dashdash}network"
    local network_alias="${dashdash}net"
    local cgroupns_option="${dashdash}cgroupns"
    local short_volume=-v
    local arg value index command_name="${argv[0]-}"

    [ -n "${command_name}" ] || fail 'UNSCOPED_CONTAINER_ARGV: empty Docker argv'
    for ((index = 0; index < ${#argv[@]}; index++)); do
        arg="${argv[index]}"
        case "${arg}" in
            "${privileged_option}"|"${privileged_option}="*)
                fail "UNSAFE_CONTAINER_ARGV: ${arg}"
                ;;
            "${device_option}"|"${device_option}="*)
                fail 'UNSAFE_CONTAINER_ARGV: host device option'
                ;;
            "${capability_option}"|"${capability_option}="*)
                fail 'UNSAFE_CONTAINER_ARGV: added capability'
                ;;
            "${pid_option}")
                value="${argv[index + 1]-}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host pid namespace'
                ;;
            "${pid_option}="*)
                value="${arg#*=}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host pid namespace'
                ;;
            "${network_option}"|"${network_alias}")
                value="${argv[index + 1]-}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host network namespace'
                ;;
            "${network_option}="*|"${network_alias}="*)
                value="${arg#*=}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host network namespace'
                ;;
            "${cgroupns_option}")
                value="${argv[index + 1]-}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host cgroup namespace'
                ;;
            "${cgroupns_option}="*)
                value="${arg#*=}"
                [ "${value}" != host ] || fail 'UNSAFE_CONTAINER_ARGV: host cgroup namespace'
                ;;
            "${volume_option}"|"${short_volume}")
                reject_device_volume "${argv[index + 1]-}"
                ;;
            "${volume_option}="*)
                reject_device_volume "${arg#*=}"
                ;;
            "${short_volume}"?*)
                reject_device_volume "${arg#"${short_volume}"}"
                ;;
            "${mount_option}")
                value="${argv[index + 1]-}"
                case ",${value}," in
                    *,source=/dev,*|*,source=/dev/*,*|*,src=/dev,*|*,src=/dev/*,*)
                        fail 'UNSAFE_CONTAINER_ARGV: host device mount'
                        ;;
                esac
                ;;
            "${mount_option}="*)
                value="${arg#*=}"
                case ",${value}," in
                    *,source=/dev,*|*,source=/dev/*,*|*,src=/dev,*|*,src=/dev/*,*)
                        fail 'UNSAFE_CONTAINER_ARGV: host device mount'
                        ;;
                esac
                ;;
        esac
    done

    case "${command_name}" in
        build)
            argv_has_option_value --label "${run_label}" "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker build lacks run label'
            argv_has_option_value --tag "${test_image}" "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker build lacks run image tag'
            ;;
        run)
            argv_has_option_value --label "${run_label}" "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks run label'
            argv_has_option_value --name "${systemd_container}" "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks run container name'
            argv_has_option_value --cgroupns private "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks private cgroup namespace'
            argv_has_option_value --network none "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks isolated network'
            argv_has_option_value --tmpfs '/run:rw,nosuid,nodev,mode=755' "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks /run tmpfs'
            argv_has_option_value --tmpfs '/run/lock:rw,nosuid,nodev,mode=755' "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks /run/lock tmpfs'
            argv_has --tty "${argv[@]}" || argv_has -t "${argv[@]}" \
                || fail 'UNSCOPED_CONTAINER_ARGV: Docker run lacks PTY'
            ;;
        exec|logs|rm)
            argv_has "${systemd_container}" "${argv[@]}" \
                || fail "UNSCOPED_CONTAINER_ARGV: ${command_name} target is not run container"
            ;;
        container)
            case "${argv[1]-}" in
                inspect)
                    argv_has "${systemd_container}" "${argv[@]}" \
                        || fail 'UNSCOPED_CONTAINER_ARGV: container inspect target mismatch'
                    ;;
                ls)
                    argv_has_option_value --filter "label=${run_label}" "${argv[@]}" \
                        || fail 'UNSCOPED_CONTAINER_ARGV: container list lacks run label filter'
                    ;;
            esac
            ;;
        image)
            case "${argv[1]-}" in
                rm|inspect)
                    argv_has "${test_image}" "${argv[@]}" \
                        || fail "UNSCOPED_CONTAINER_ARGV: image ${argv[1]} target mismatch"
                    ;;
                ls)
                    argv_has_option_value --filter "label=${run_label}" "${argv[@]}" \
                        || fail 'UNSCOPED_CONTAINER_ARGV: image list lacks run label filter'
                    ;;
            esac
            ;;
        buildx)
            if [ "${argv[1]-}" = prune ]; then
                value=
                for ((index = 0; index < ${#argv[@]}; index++)); do
                    if [ "${argv[index]}" = --filter ]; then
                        value="${argv[index + 1]-}"
                    fi
                done
                case "${value}" in
                    id=*) ;;
                    *)
                        if [ "${allow_full_cache_prune}" -eq 1 ] \
                            && argv_has --all "${argv[@]}"; then
                            :
                        else
                            fail 'UNSCOPED_CONTAINER_ARGV: build-cache prune lacks record id'
                        fi
                        ;;
                esac
                argv_has --force "${argv[@]}" \
                    || fail 'UNSCOPED_CONTAINER_ARGV: build-cache prune is interactive'
            fi
            ;;
    esac
}

docker_checked() {
    local status
    audit_docker_argv "$@"
    sample_disk "before-docker-${1:-unknown}"
    if command docker "$@"; then
        status=0
    else
        status=$?
    fi
    sample_disk "after-docker-${1:-unknown}"
    return "${status}"
}

make_systemd_argv() {
    local image_name="$1"
    local container_name="$2"
    systemd_argv=(
        run
        --detach
        --tty
        --name "${container_name}"
        --label "${run_label}"
        --hostname tsp-f3fm-211-systemd
        --cgroupns=private
        --network=none
        --tmpfs '/run:rw,nosuid,nodev,mode=755'
        --tmpfs '/run/lock:rw,nosuid,nodev,mode=755'
        --pids-limit=512
        --env=container=docker
        "${image_name}"
        /sbin/init
    )
}

print_argv() {
    printf 'docker'
    printf ' %s' "$@"
    printf '\n'
}

capture_build_cache_ids() {
    local destination="$1"
    docker_checked buildx du --format '{{.ID}}' 2>/dev/null \
        | awk 'NF { sub(/[*]$/, "", $1); print $1 }' \
        | sort -u >"${destination}"
}

capture_docker_system_df() {
    docker_checked system df \
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

load_docker_info() {
    local info fields
    info="$(docker_checked info --format '{{json .}}' 2>/dev/null)" \
        || fail_recorded_or 'DOCKER_UNAVAILABLE: Docker info failed'
    fields="$(python3 -c '
import json, sys
info = json.load(sys.stdin)
print("\t".join(str(info[key]) for key in (
    "DockerRootDir", "CgroupVersion", "CgroupDriver", "Architecture", "ServerVersion"
)))
' <<<"${info}")" \
        || fail 'DOCKER_INFO_UNREADABLE: missing data-root/cgroup/architecture/version fields'
    IFS=$'\t' read -r docker_root_value docker_cgroup docker_cgroup_driver \
        docker_arch docker_version <<<"${fields}"
    configure_docker_root "${docker_root_value}"
}

cleanup() {
    local status=$? receipt_result receipt_reason scope_removed=false
    local container_status image_status labeled_containers labeled_images
    local cache_current cache_created cache_remaining cache_id attempt
    trap - EXIT INT TERM
    cleanup_active=1
    set +e

    if [ "${scope_initialized}" -eq 1 ] && [ -s "${run_scope}/failure-reason" ]; then
        failure_reason="$(<"${run_scope}/failure-reason")"
    fi
    sample_disk cleanup_begin >/dev/null 2>&1 || true
    if [ "${cleanup_docker_resources}" -eq 1 ] \
        && command -v docker >/dev/null 2>&1; then
        docker_checked rm --force "${systemd_container}" >/dev/null 2>&1
        docker_checked image rm --force "${test_image}" >/dev/null 2>&1

        docker_checked container inspect "${systemd_container}" >/dev/null 2>&1
        container_status=$?
        docker_checked image inspect "${test_image}" >/dev/null 2>&1
        image_status=$?
        labeled_containers="$(docker_checked container ls --all --quiet \
            --filter "label=${run_label}" 2>/dev/null)"
        labeled_images="$(docker_checked image ls --quiet \
            --filter "label=${run_label}" 2>/dev/null)"
        if [ "${container_status}" -eq 0 ] || [ "${image_status}" -eq 0 ] \
            || [ -n "${labeled_containers}" ] || [ -n "${labeled_images}" ]; then
            cleanup_failed=1
            failure_reason='RESOURCE_CLEANUP_FAILED'
        elif [ "${container_status}" -ne 1 ] || [ "${image_status}" -ne 1 ]; then
            cleanup_failed=1
            failure_reason='RESOURCE_CLEANUP_AUDIT_FAILED'
        fi

        cache_current="${run_scope}/build-cache-current"
        cache_created="${run_scope}/build-cache-created"
        cache_remaining="${run_scope}/build-cache-remaining"
        if [ -s "${run_scope}/build-cache-before" ] || [ -f "${run_scope}/build-cache-before" ]; then
            if capture_build_cache_ids "${cache_current}"; then
                comm -13 "${run_scope}/build-cache-before" "${cache_current}" >"${cache_created}"
                build_cache_records_removed="$(awk 'NF { count++ } END { print count + 0 }' "${cache_created}")"
                while IFS= read -r cache_id; do
                    [ -n "${cache_id}" ] || continue
                    docker_checked buildx prune --force --filter "id=${cache_id}" \
                        >/dev/null 2>&1 || cleanup_failed=1
                done <"${cache_created}"
                if [ ! -s "${run_scope}/build-cache-before" ] \
                    && [ "${build_cache_df_before}" = \
                        'Build_Cache=total:0,active:0,size:0B,reclaimable:0B' ]; then
                    allow_full_cache_prune=1
                    docker_checked buildx prune --force --all \
                        >/dev/null 2>&1 || cleanup_failed=1
                    allow_full_cache_prune=0
                fi
                if capture_build_cache_ids "${cache_current}.after"; then
                    comm -13 "${run_scope}/build-cache-before" \
                        "${cache_current}.after" >"${cache_remaining}"
                    if [ -s "${cache_remaining}" ]; then
                        cleanup_failed=1
                        failure_reason='BUILD_CACHE_CLEANUP_FAILED'
                    fi
                else
                    cleanup_failed=1
                    failure_reason='BUILD_CACHE_AUDIT_FAILED'
                fi
            else
                cleanup_failed=1
                failure_reason='BUILD_CACHE_AUDIT_FAILED'
            fi
        fi
    fi
    sample_disk cleanup_end >/dev/null 2>&1 || true
    if [ "${docker_disk_configured}" -eq 1 ]; then
        docker_root_free_after_bytes="$(measure_docker_root_free_bytes)" \
            || cleanup_failed=1
        docker_root_df_after="$(capture_docker_root_df)" \
            || cleanup_failed=1
        for ((attempt = 1; attempt <= 10; attempt++)); do
            docker_system_df_after="$(capture_docker_system_df)" \
                || cleanup_failed=1
            build_cache_df_after="$(extract_build_cache_df \
                "${docker_system_df_after}")" || cleanup_failed=1
            [ "${build_cache_df_after}" != "${build_cache_df_before}" ] || break
            sleep 0.2
        done
        if [ "${build_cache_df_after}" != "${build_cache_df_before}" ]; then
            cleanup_failed=1
            failure_reason='BUILD_CACHE_USAGE_DRIFT'
        fi
    fi

    if [ "${scope_initialized}" -eq 1 ] && [ -d "${run_scope}" ]; then
        find "${run_scope}" -mindepth 1 -delete >/dev/null 2>&1
        rmdir "${run_scope}" >/dev/null 2>&1
    fi
    if [ "${scope_initialized}" -eq 1 ] && [ ! -e "${run_scope}" ]; then
        scope_removed=true
    else
        cleanup_failed=1
        failure_reason='RUN_SCOPE_CLEANUP_FAILED'
    fi

    if [ "${status}" -eq 0 ] && [ "${run_completed}" -eq 1 ] \
        && [ "${cleanup_failed}" -eq 0 ]; then
        receipt_result=PASS
        receipt_reason=completed
    else
        receipt_result=FAIL
        receipt_reason="${failure_reason:-UNEXPECTED_EXIT_${status}}"
        receipt_reason="${receipt_reason%%:*}"
        status=1
    fi

    if [ "${receipt_result}" = PASS ]; then
        echo "session-authority real-systemd: PASS ${pass_fields} run_id=${run_id} docker_root=${docker_root:-unknown} docker_root_free_before_bytes=${docker_root_free_before_bytes:-unknown} docker_root_free_after_bytes=${docker_root_free_after_bytes:-unknown} docker_root_df_before=${docker_root_df_before:-unknown} docker_root_df_after=${docker_root_df_after:-unknown} docker_system_df_before=${docker_system_df_before:-unknown} docker_system_df_after=${docker_system_df_after:-unknown} build_cache_df_before=${build_cache_df_before:-unknown} build_cache_df_after=${build_cache_df_after:-unknown} build_cache_records_removed=${build_cache_records_removed} run_scope_peak_bytes=${run_scope_peak_bytes} docker_root_min_free_bytes=${docker_root_min_free_bytes:-unknown} run_scope_removed=${scope_removed}"
    else
        echo "session-authority real-systemd: FAIL receipt_reason=${receipt_reason} run_id=${run_id:-unknown} docker_root=${docker_root:-unknown} docker_root_free_before_bytes=${docker_root_free_before_bytes:-unknown} docker_root_free_after_bytes=${docker_root_free_after_bytes:-unknown} docker_root_df_before=${docker_root_df_before:-unknown} docker_root_df_after=${docker_root_df_after:-unknown} docker_system_df_before=${docker_system_df_before:-unknown} docker_system_df_after=${docker_system_df_after:-unknown} build_cache_df_before=${build_cache_df_before:-unknown} build_cache_df_after=${build_cache_df_after:-unknown} build_cache_records_removed=${build_cache_records_removed} run_scope_peak_bytes=${run_scope_peak_bytes} docker_root_min_free_bytes=${docker_root_min_free_bytes:-unknown} run_scope_removed=${scope_removed}" >&2
    fi
    exit "${status}"
}

case "${1:-}" in
    --audit-argv)
        [ "$#" -ge 3 ] || fail 'USAGE: --audit-argv RUN_ID ARGV...'
        configure_run_identity "$2"
        shift 2
        audit_docker_argv "$@"
        echo 'session-authority docker-argv-audit: PASS'
        exit 0
        ;;
    --audit-systemd-spec)
        [ "$#" -eq 2 ] || fail 'USAGE: --audit-systemd-spec RUN_ID'
        configure_run_identity "$2"
        make_systemd_argv "${test_image}" "${systemd_container}"
        audit_docker_argv "${systemd_argv[@]}"
        print_argv "${systemd_argv[@]}"
        exit 0
        ;;
    --audit-lifecycle-argv)
        [ "$#" -eq 2 ] || fail 'USAGE: --audit-lifecycle-argv RUN_ID'
        configure_run_identity "$2"
        lifecycle_commands=(
            'info --format {{json .}}'
            'version --format {{.Server.Version}}'
            "build --label ${run_label} --iidfile /scope/image-id --tag ${test_image} --file /scope/Containerfile /scope"
            "exec ${systemd_container} /bin/true"
            "logs ${systemd_container}"
            "container inspect ${systemd_container}"
            "container ls --all --quiet --filter label=${run_label}"
            "rm --force ${systemd_container}"
            "image inspect ${test_image}"
            "image ls --quiet --filter label=${run_label}"
            "image rm --force ${test_image}"
            'buildx du --format {{.ID}}'
            'buildx prune --force --filter id=fixture-cache-id'
        )
        make_systemd_argv "${test_image}" "${systemd_container}"
        audit_docker_argv "${systemd_argv[@]}"
        print_argv "${systemd_argv[@]}"
        for command_line in "${lifecycle_commands[@]}"; do
            read -r -a command_argv <<<"${command_line}"
            audit_docker_argv "${command_argv[@]}"
            print_argv "${command_argv[@]}"
        done
        exit 0
        ;;
    --check-host-guard)
        [ "$#" -eq 2 ] || fail 'USAGE: --check-host-guard FIXTURE_ROOT'
        assert_safe_host "$2"
        assert_ephemeral_slot "$2"
        echo "session-authority host-guard: PASS host=${guard_hostname} ephemeral_slot=true"
        exit 0
        ;;
    --check-docker-probe)
        [ "$#" -eq 2 ] || fail 'USAGE: --check-docker-probe FIXTURE_ROOT'
        assert_safe_host "$2"
        assert_ephemeral_slot "$2"
        for command_name in docker python3; do
            command -v "${command_name}" >/dev/null 2>&1 \
                || fail "MISSING_PREREQUISITE: ${command_name}"
        done
        configure_run_identity fixture-probe
        run_scope="$(mktemp -d /tmp/tsp-f3fm-211.XXXXXX)"
        scope_initialized=1
        trap cleanup EXIT INT TERM
        load_docker_info
        sample_disk preflight
        docker_root_free_before_bytes="$(measure_docker_root_free_bytes)" \
            || fail 'DISK_PROBE_FAILED: before-probe Docker data-root free bytes'
        docker_root_df_before="$(capture_docker_root_df)" \
            || fail 'DISK_PROBE_FAILED: before-probe Docker data-root df'
        docker_system_df_before="$(capture_docker_system_df)" \
            || fail_recorded_or 'DOCKER_DISK_USAGE_UNAVAILABLE: docker system df failed'
        build_cache_df_before="$(extract_build_cache_df \
            "${docker_system_df_before}")" \
            || fail 'DOCKER_DISK_USAGE_UNREADABLE: build-cache total missing'
        run_started=1
        probe_version="$(docker_checked version --format '{{.Server.Version}}')" \
            || fail_recorded_or 'DOCKER_UNAVAILABLE: version query failed'
        pass_fields="probe=docker-version docker_version=${probe_version} ephemeral_slot=true"
        run_completed=1
        exit 0
        ;;
    '')
        ;;
    *)
        fail "USAGE: $0 [--audit-argv RUN_ID ARGV...|--audit-systemd-spec RUN_ID|--audit-lifecycle-argv RUN_ID|--check-host-guard FIXTURE_ROOT|--check-docker-probe FIXTURE_ROOT]"
        ;;
esac

# The interactive guard is deliberately first. Nothing may query Docker until
# the host is both non-graphical and a one-job ephemeral Actions runner.
assert_safe_host /
assert_ephemeral_slot /

for command_name in docker git python3 sha256sum; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "MISSING_PREREQUISITE: ${command_name}"
done
[ "$(uname -m)" = x86_64 ] || fail "AMD64_REQUIRED: host architecture is $(uname -m)"

default_run_id="gha-${GITHUB_RUN_ID:-missing}-${GITHUB_RUN_ATTEMPT:-missing}-${GITHUB_JOB:-job}-$$"
configure_run_identity "${PF_SYSTEMD_TEST_RUN_ID:-${default_run_id}}"
run_scope="$(mktemp -d /tmp/tsp-f3fm-211.XXXXXX)"
runtime="${run_scope}/runtime"
context="${run_scope}/context"
image_id_file="${run_scope}/image-id"
scope_initialized=1
trap cleanup EXIT INT TERM

load_docker_info
case "${docker_cgroup}" in
    2|v2) ;;
    *) fail "CGROUP_V2_REQUIRED: got ${docker_cgroup}" ;;
esac
case "${docker_arch}" in
    amd64|x86_64) ;;
    *) fail "AMD64_REQUIRED: Docker architecture is ${docker_arch}" ;;
esac
sample_disk preflight
docker_root_free_before_bytes="$(measure_docker_root_free_bytes)" \
    || fail 'DISK_PROBE_FAILED: before-run Docker data-root free bytes'
docker_root_df_before="$(capture_docker_root_df)" \
    || fail 'DISK_PROBE_FAILED: before-run Docker data-root df'
docker_system_df_before="$(capture_docker_system_df)" \
    || fail_recorded_or 'DOCKER_DISK_USAGE_UNAVAILABLE: docker system df failed'
build_cache_df_before="$(extract_build_cache_df "${docker_system_df_before}")" \
    || fail 'DOCKER_DISK_USAGE_UNREADABLE: build-cache total missing'
run_started=1

capture_build_cache_ids "${run_scope}/build-cache-before" \
    || fail_recorded_or 'BUILD_CACHE_AUDIT_UNAVAILABLE: docker buildx du failed'
cleanup_docker_resources=1

actual_unit_sha256="$(sha256sum "${app_unit}" | awk '{print $1}')"
[ "${actual_unit_sha256}" = "${app_unit_sha256}" ] \
    || fail "APP_UNIT_DRIFT: expected ${app_unit_sha256}, got ${actual_unit_sha256}"

git clone --quiet --filter=blob:none --no-checkout "${runtime_repository}" "${runtime}"
git -C "${runtime}" fetch --quiet origin "${runtime_sha}"
git -C "${runtime}" checkout --quiet --detach "${runtime_sha}"
[ "$(git -C "${runtime}" rev-parse HEAD)" = "${runtime_sha}" ] \
    || fail 'RUNTIME_SHA_MISMATCH'
sample_disk runtime_clone

mkdir -p "${context}/runtime"
python3 - "${runtime}" "${context}/runtime" <<'PY'
from pathlib import Path
import shutil
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
for item in source.iterdir():
    if item.name == ".git":
        continue
    target = destination / item.name
    if item.is_dir():
        shutil.copytree(item, target, symlinks=True)
    else:
        shutil.copy2(item, target, follow_symlinks=False)
PY
find "${runtime}" -mindepth 1 -delete
rmdir "${runtime}"

install -m 0644 "${containerfile}" "${context}/Containerfile"
install -m 0644 "${app_unit}" "${context}/pf-app@.service"
install -m 0644 "${fixtures}/pocketforge-foreground.target" \
    "${context}/pocketforge-foreground.target"
install -m 0644 "${owner_dropin}" "${context}/10-owner-shell.conf"
install -m 0644 "${fixtures}/pf-shell-selected.service" \
    "${context}/pf-shell-selected.service"
install -m 0644 "${fixtures}/session-authority-test.target" \
    "${context}/session-authority-test.target"
install -m 0644 "${fixtures}/session-authority-test-tmpfiles.conf" \
    "${context}/session-authority-test-tmpfiles.conf"
install -m 0644 "${fixtures}/app.toml" "${context}/app.toml"
install -m 0755 "${fixtures}/fixture" "${context}/fixture"
install -m 0644 "${fixtures}/platform-capabilities.toml" \
    "${context}/platform-capabilities.toml"
install -m 0755 "${fixtures}/drive.py" "${context}/drive.py"
sample_disk build_context

docker_checked build \
    --build-arg "PF_RUNTIME_SHA=${runtime_sha}" \
    --label "${run_label}" \
    --iidfile "${image_id_file}" \
    --tag "${test_image}" \
    --file "${context}/Containerfile" \
    "${context}" \
    || fail_recorded_or 'IMAGE_BUILD_FAILED: Docker build failed'
test_image_digest="$(<"${image_id_file}")"

make_systemd_argv "${test_image}" "${systemd_container}"
audit_docker_argv "${systemd_argv[@]}"
docker_checked "${systemd_argv[@]}" >/dev/null \
    || fail_recorded_or 'SYSTEMD_PID1_UNAVAILABLE: unprivileged Docker run failed'

systemd_ready=0
for _ in $(seq 1 120); do
    if docker_checked exec "${systemd_container}" /bin/sh -c '
        [ "$(cat /proc/1/comm)" = systemd ] \
            && [ "$(systemctl get-default)" = session-authority-test.target ] \
            && systemctl is-active --quiet pf-session-authorityd.service \
            && systemctl is-active --quiet pf-shell-selected.service
    ' >/dev/null 2>&1; then
        systemd_ready=1
        break
    fi
    [ ! -s "${run_scope}/failure-reason" ] || fail_recorded_or 'DISK_FLOOR_ABORT'
    sleep 0.1
done
if [ "${systemd_ready}" -ne 1 ]; then
    docker_checked container inspect --format '{{json .State}}' \
        "${systemd_container}" >&2 || true
    docker_checked exec "${systemd_container}" cat /proc/mounts >&2 || true
    docker_checked logs "${systemd_container}" >&2 || true
    fail 'SYSTEMD_PID1_UNAVAILABLE: unprivileged Docker did not boot a usable systemd PID 1'
fi

cgroup_mount_options="$(
    docker_checked exec "${systemd_container}" /bin/sh -ceu \
        'awk '\''$2 == "/sys/fs/cgroup" { print $4; exit }'\'' /proc/mounts'
)" || fail_recorded_or 'CGROUP_MOUNT_PROBE_FAILED'
case ",${cgroup_mount_options}," in
    *,rw,*) ;;
    *) fail "SYSTEMD_CGROUP_READ_ONLY: mount_options=${cgroup_mount_options:-missing}" ;;
esac

container_unit_sha256="$(
    docker_checked exec "${systemd_container}" \
        sha256sum /etc/systemd/system/pf-app@.service | awk '{print $1}'
)" || fail_recorded_or 'CONTAINER_APP_UNIT_HASH_FAILED'
[ "${container_unit_sha256}" = "${app_unit_sha256}" ] \
    || fail "CONTAINER_APP_UNIT_DRIFT: got ${container_unit_sha256}"

host_vt_devices="$(
    docker_checked exec "${systemd_container}" /bin/sh -ceu '
        for path in /dev/tty[0-9]*; do
            [ -e "${path}" ] || continue
            printf "%s\n" "${path}"
        done
    '
)" || fail_recorded_or 'HOST_VT_PROBE_FAILED'
[ -z "${host_vt_devices}" ] \
    || fail "HOST_VT_EXPOSED: ${host_vt_devices//$'\n'/,}"

getty_units_masked="$(
    docker_checked exec "${systemd_container}" /bin/sh -ceu '
        count=0
        for unit in \
            getty@.service \
            getty.target \
            console-getty.service \
            serial-getty@.service \
            autovt@.service; do
            [ "$(readlink "/etc/systemd/system/${unit}")" = /dev/null ]
            count=$((count + 1))
        done
        printf "%s\n" "${count}"
    '
)" || fail_recorded_or 'GETTY_MASK_PROBE_FAILED'
[ "${getty_units_masked}" = 5 ] \
    || fail "GETTY_MASK_INCOMPLETE: count=${getty_units_masked}"

container_isolation="$(
    docker_checked container inspect \
        --format '{{.Config.Tty}} {{.HostConfig.NetworkMode}} {{.HostConfig.CgroupnsMode}}' \
        "${systemd_container}"
)" || fail_recorded_or 'CONTAINER_ISOLATION_PROBE_FAILED'
[ "${container_isolation}" = 'true none private' ] \
    || fail "CONTAINER_ISOLATION_DRIFT: ${container_isolation}"

tmpfs_json="$(
    docker_checked container inspect --format '{{json .HostConfig.Tmpfs}}' \
        "${systemd_container}"
)" || fail_recorded_or 'CONTAINER_TMPFS_PROBE_FAILED'
python3 -c '
import json, sys
mounts = json.load(sys.stdin)
required = {"/run", "/run/lock"}
missing = required.difference(mounts)
if missing:
    raise SystemExit(f"missing tmpfs mounts: {sorted(missing)}")
' <<<"${tmpfs_json}" || fail 'CONTAINER_TMPFS_DRIFT'

if ! test_output="$(
    docker_checked exec "${systemd_container}" /usr/local/libexec/drive.py 2>&1
)"; then
    [ ! -s "${run_scope}/failure-reason" ] || fail_recorded_or 'DISK_FLOOR_ABORT'
    echo "${test_output}" >&2
    docker_checked exec "${systemd_container}" \
        journalctl --no-pager --output short-monotonic --lines 200 \
        --unit pf-session-authorityd.service \
        --unit pf-app@org.pocketforge.fixture.service \
        --unit pf-shell-selected.service >&2 || true
    fail 'INTEGRATION_ASSERTION_FAILED'
fi
echo "${test_output}"
sample_disk integration_complete
pass_fields="runtime_sha=${runtime_sha} container_image_digest=${test_image_digest} fail_closed=SYSTEMD_PID1_UNAVAILABLE docker_version=${docker_version} cgroup=${docker_cgroup} cgroup_driver=${docker_cgroup_driver} cgroup_namespace=private cgroup_mount=rw tty=true network=none tmpfs_run=true host_vt_devices=none getty_units_masked=${getty_units_masked} ephemeral_slot=true"
run_completed=1
