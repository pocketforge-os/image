#!/usr/bin/env bash
set -euo pipefail

# OWNER DECISION (2026-09-28): candidate e is permitted only after both the
# unchanged INTERACTIVE_WORKSTATION guard and the one-job ephemeral Actions
# admission succeed. These runners already have docker-group (root-equivalent)
# access and are disposable VMs with no display or VT. The workstation incident
# rules remain fail-closed everywhere else, with no override.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="${root}/tests/session-authority-systemd"
app_unit="${root}/rootfs-overlay/etc/systemd/system/pf-app@.service"
owner_dropin="${root}/rootfs-overlay/etc/systemd/system/pocketforge-foreground.target.d/10-owner-shell.conf"
broker_dropin="${root}/rootfs-overlay/etc/systemd/system/pf-input-broker.service.d/10-app-session.conf"
shell_dropin="${root}/rootfs-overlay/etc/systemd/system/pf-shell-selected.service.d/10-input-broker.conf"
containerfile="${fixtures}/Containerfile"
ephemeral_marker=/etc/pocketforge/ephemeral-runner.conf
run_label_key=org.pocketforge.session-authority-run

runtime_sha=d75beedfb1203b329801a777803dff1ae8d5da1c
runtime_repository=https://github.com/pocketforge-os/runtime.git
app_unit_sha256=d5bdd3fba3bcc2b9fdbc1eb8675574bb15492381c01987cf1bc9ab04f68daace
# B4 (tsp-f3fm.202.1.4): the app-session broker wiring under test. The runtime unit
# is taken verbatim from the pinned runtime clone; the two drop-ins from this tree.
broker_unit_sha256=6fd5a41bb742b86a91c2b28e0f240e8d2bc95615dabcf3e033bf3644f9909dd8
broker_dropin_sha256=8aa6b5c4472e012b952f0e9d85071456596902220168a895c6583f061bbccd02
shell_dropin_sha256=992b84d9e4578712d50e2f4bc02537610e297ca54d4d54150cd4c4af7fca047f
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
ephemeral_admitted=0
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
build_cache_leftover_ids=
build_cache_missing_ids=
docker_run_profile=owner-exception
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

# shellcheck source=tests/session-authority-systemd/docker-argv-audit.sh
source "${fixtures}/docker-argv-audit.sh"
# shellcheck source=tests/session-authority-systemd/build-cache-audit.sh
source "${fixtures}/build-cache-audit.sh"

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

# Fixture admission is only for pure guard/argv checks or for a Docker shim
# proven to live inside the fixture. It must never gate a real Docker command.
assert_fixture_ephemeral_slot() {
    local fixture_root="${1:-/}"
    local marker="${fixture_root%/}${ephemeral_marker}"

    [ "${GITHUB_ACTIONS:-}" = true ] \
        || fail 'UNAPPROVED_HOST: GITHUB_ACTIONS=true is required'
    [ -f "${marker}" ] \
        || fail "UNAPPROVED_HOST: ephemeral runner marker missing path=${marker}"
    ephemeral_admitted=1
}

assert_real_ephemeral_slot() {
    [ "${GITHUB_ACTIONS:-}" = true ] \
        || fail 'UNAPPROVED_HOST: GITHUB_ACTIONS=true is required'
    [ -f "${ephemeral_marker}" ] \
        || fail "UNAPPROVED_HOST: ephemeral runner marker missing path=${ephemeral_marker}"
    ephemeral_admitted=1
}

assert_fixture_docker_shim() {
    local fixture_root="$1" docker_command
    local resolved_root resolved_fake_bin resolved_docker

    command -v realpath >/dev/null 2>&1 \
        || fail 'HOST_GUARD_UNAVAILABLE: realpath'
    docker_command="$(command -v docker 2>/dev/null)" \
        || fail 'MISSING_PREREQUISITE: docker'
    resolved_root="$(realpath -e -- "${fixture_root}")" \
        || fail "UNAPPROVED_TEST_DOCKER: fixture root is not real path=${fixture_root}"
    resolved_fake_bin="$(realpath -e -- "${fixture_root%/}/.test-bin")" \
        || fail "UNAPPROVED_TEST_DOCKER: fixture fake-bin missing root=${resolved_root}"
    resolved_docker="$(realpath -e -- "${docker_command}")" \
        || fail "UNAPPROVED_TEST_DOCKER: Docker command is not real path=${docker_command}"
    [ "${resolved_fake_bin}" != "${resolved_root}" ] \
        || fail "UNAPPROVED_TEST_DOCKER: fixture fake-bin is not a child path=${resolved_fake_bin}"
    case "${resolved_fake_bin}/" in
        "${resolved_root}/"*) ;;
        *) fail "UNAPPROVED_TEST_DOCKER: fixture fake-bin escapes root path=${resolved_fake_bin}" ;;
    esac
    [ "${resolved_docker}" = "${resolved_fake_bin}/docker" ] \
        || fail "UNAPPROVED_TEST_DOCKER: Docker command is outside fixture fake-bin path=${resolved_docker}"
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
        --security-opt apparmor=unconfined
        --cap-add SYS_ADMIN
        "${image_name}"
        /usr/local/libexec/remount-cgroup-systemd
    )
}

print_argv() {
    printf 'docker'
    printf ' %s' "$@"
    printf '\n'
}

build_cache_docker() {
    docker_checked "$@"
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
    local attempt
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

        if [ -s "${run_scope}/build-cache-before" ] || [ -f "${run_scope}/build-cache-before" ]; then
            if ! cleanup_run_build_cache "${run_scope}/build-cache-before" \
                "${run_scope}/build-cache-cleanup"; then
                cleanup_failed=1
                failure_reason="$(build_cache_drift_reason)"
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
            failure_reason="$(build_cache_drift_reason)"
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
        case "${receipt_reason}" in
            BUILD_CACHE_USAGE_DRIFT:*) ;;
            *) receipt_reason="${receipt_reason%%:*}" ;;
        esac
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
        [ "$#" -ge 4 ] || fail 'USAGE: --audit-argv FIXTURE_ROOT RUN_ID ARGV...'
        assert_safe_host "$2"
        assert_fixture_ephemeral_slot "$2"
        configure_run_identity "$3"
        shift 3
        audit_docker_argv "$@"
        echo 'session-authority docker-argv-audit: PASS'
        exit 0
        ;;
    --audit-systemd-spec)
        [ "$#" -eq 3 ] || fail 'USAGE: --audit-systemd-spec FIXTURE_ROOT RUN_ID'
        assert_safe_host "$2"
        assert_fixture_ephemeral_slot "$2"
        configure_run_identity "$3"
        make_systemd_argv "${test_image}" "${systemd_container}"
        audit_docker_argv "${systemd_argv[@]}"
        print_argv "${systemd_argv[@]}"
        exit 0
        ;;
    --audit-lifecycle-argv)
        [ "$#" -eq 3 ] || fail 'USAGE: --audit-lifecycle-argv FIXTURE_ROOT RUN_ID'
        assert_safe_host "$2"
        assert_fixture_ephemeral_slot "$2"
        configure_run_identity "$3"
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
            'buildx du --format json'
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
        assert_fixture_ephemeral_slot "$2"
        echo "session-authority host-guard: PASS host=${guard_hostname} ephemeral_slot=true"
        exit 0
        ;;
    --check-docker-probe)
        [ "$#" -eq 2 ] || fail 'USAGE: --check-docker-probe FIXTURE_ROOT'
        assert_safe_host "$2"
        assert_fixture_ephemeral_slot "$2"
        assert_fixture_docker_shim "$2"
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
        fail "USAGE: $0 [--audit-argv FIXTURE_ROOT RUN_ID ARGV...|--audit-systemd-spec FIXTURE_ROOT RUN_ID|--audit-lifecycle-argv FIXTURE_ROOT RUN_ID|--check-host-guard FIXTURE_ROOT|--check-docker-probe FIXTURE_ROOT]"
        ;;
esac

# The interactive guard is deliberately first. Nothing may query Docker until
# the host is both non-graphical and a one-job ephemeral Actions runner.
assert_safe_host /
assert_real_ephemeral_slot

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

capture_build_cache_records "${run_scope}/build-cache-before" \
    || fail_recorded_or 'BUILD_CACHE_AUDIT_UNAVAILABLE: docker buildx du failed'
cleanup_docker_resources=1

actual_unit_sha256="$(sha256sum "${app_unit}" | awk '{print $1}')"
[ "${actual_unit_sha256}" = "${app_unit_sha256}" ] \
    || fail "APP_UNIT_DRIFT: expected ${app_unit_sha256}, got ${actual_unit_sha256}"
for pinned in "broker_dropin:${broker_dropin}:${broker_dropin_sha256}" \
    "shell_dropin:${shell_dropin}:${shell_dropin_sha256}"; do
    IFS=: read -r pinned_name pinned_path pinned_sha256 <<<"${pinned}"
    actual_pinned_sha256="$(sha256sum "${pinned_path}" | awk '{print $1}')"
    [ "${actual_pinned_sha256}" = "${pinned_sha256}" ] \
        || fail "UNIT_DRIFT: ${pinned_name} expected ${pinned_sha256}, got ${actual_pinned_sha256}"
done
# The shell under test is a fixture; refuse to run when the real unit has an
# edge toward a harness unit that the fixture does not model (bd tsp-3rd3.12).
shell_fixture_parity="$(python3 "${root}/tests/verify-session-authority-shell-fixture.py" 2>&1)" \
    || fail "SHELL_FIXTURE_DRIFT: ${shell_fixture_parity}"
echo "${shell_fixture_parity}"

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
actual_broker_unit_sha256="$(sha256sum \
    "${context}/runtime/crates/pf-input-broker/systemd/pf-input-broker.service" | awk '{print $1}')"
[ "${actual_broker_unit_sha256}" = "${broker_unit_sha256}" ] \
    || fail "UNIT_DRIFT: runtime pf-input-broker.service expected ${broker_unit_sha256}, got ${actual_broker_unit_sha256}"

install -m 0644 "${containerfile}" "${context}/Containerfile"
install -m 0644 "${app_unit}" "${context}/pf-app@.service"
install -m 0644 "${fixtures}/pocketforge-foreground.target" \
    "${context}/pocketforge-foreground.target"
install -m 0644 "${owner_dropin}" "${context}/10-owner-shell.conf"
install -m 0644 "${fixtures}/pf-shell-selected.service" \
    "${context}/pf-shell-selected.service"
install -m 0644 "${broker_dropin}" "${context}/10-app-session.conf"
install -m 0644 "${shell_dropin}" "${context}/10-input-broker.conf"
install -m 0755 "${fixtures}/fake-input-broker" "${context}/fake-input-broker"
install -m 0755 "${fixtures}/fake-shell" "${context}/fake-shell"
install -m 0644 "${fixtures}/capabilities.toml" "${context}/capabilities.toml"
install -m 0644 "${fixtures}/session-authority-test.target" \
    "${context}/session-authority-test.target"
install -m 0644 "${fixtures}/session-authority-test-tmpfiles.conf" \
    "${context}/session-authority-test-tmpfiles.conf"
install -m 0644 "${fixtures}/app.toml" "${context}/app.toml"
install -m 0755 "${fixtures}/fixture" "${context}/fixture"
install -m 0644 "${fixtures}/platform-capabilities.toml" \
    "${context}/platform-capabilities.toml"
install -m 0755 "${fixtures}/drive.py" "${context}/drive.py"
install -m 0755 "${fixtures}/remount-cgroup-systemd" \
    "${context}/remount-cgroup-systemd"
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
    || fail_recorded_or 'SYSTEMD_PID1_UNAVAILABLE: ephemeral owner-exception Docker run failed'

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
    fail 'SYSTEMD_PID1_UNAVAILABLE: ephemeral owner-exception Docker did not boot a usable systemd PID 1'
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
container_broker_hashes="$(
    docker_checked exec "${systemd_container}" sha256sum \
        /etc/systemd/system/pf-input-broker.service \
        /etc/systemd/system/pf-input-broker.service.d/10-app-session.conf \
        /etc/systemd/system/pf-shell-selected.service.d/10-input-broker.conf \
        | awk '{print $1}' | paste -sd' ' -
)" || fail_recorded_or 'CONTAINER_BROKER_UNIT_HASH_FAILED'
[ "${container_broker_hashes}" = "${broker_unit_sha256} ${broker_dropin_sha256} ${shell_dropin_sha256}" ] \
    || fail "CONTAINER_BROKER_UNIT_DRIFT: got ${container_broker_hashes}"

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

owner_exception_json="$(
    docker_checked container inspect \
        --format '{{json .HostConfig.CapAdd}}|{{json .HostConfig.SecurityOpt}}|{{json .Config.Cmd}}' \
        "${systemd_container}"
)" || fail_recorded_or 'OWNER_EXCEPTION_PROBE_FAILED'
python3 -c '
import json, sys
cap_add, security_opt, command = sys.stdin.read().strip().split("|", 2)
if json.loads(cap_add) not in (["SYS_ADMIN"], ["CAP_SYS_ADMIN"]):
    raise SystemExit("unexpected capability set")
if json.loads(security_opt) != ["apparmor=unconfined"]:
    raise SystemExit("unexpected security option set")
if json.loads(command) != ["/usr/local/libexec/remount-cgroup-systemd"]:
    raise SystemExit("unexpected container command")
' <<<"${owner_exception_json}" || fail 'OWNER_EXCEPTION_DRIFT'

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
        --unit pf-input-broker.service \
        --unit pocketforge-foreground.target \
        --unit pf-shell-selected.service >&2 || true
    docker_checked exec "${systemd_container}" /bin/sh -c \
        'for f in /run/pf-grab/timeline /run/pf-grab/violations /run/pf-grab/safe-return.log; do
            [ -f "$f" ] && { echo "== $f"; cat "$f"; }; done; echo "== authority.json";
            cat /var/lib/pocketforge/session-authority/authority.json' >&2 || true
    fail 'INTEGRATION_ASSERTION_FAILED'
fi
echo "${test_output}"
sample_disk integration_complete
pass_fields="runtime_sha=${runtime_sha} broker_units=${broker_unit_sha256:0:12},${broker_dropin_sha256:0:12},${shell_dropin_sha256:0:12} shell_fixture_parity=pass container_image_digest=${test_image_digest} fail_closed=SYSTEMD_PID1_UNAVAILABLE docker_version=${docker_version} cgroup=${docker_cgroup} cgroup_driver=${docker_cgroup_driver} cgroup_namespace=private cgroup_mount=rw tty=true network=none tmpfs_run=true host_vt_devices=none getty_units_masked=${getty_units_masked} ephemeral_slot=true adopted=e owner_exception=ephemeral-only cap_add=SYS_ADMIN apparmor=unconfined cgroup_remount=rw"
run_completed=1
