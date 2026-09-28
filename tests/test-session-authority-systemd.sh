#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="${root}/tests/session-authority-systemd"
app_unit="${root}/rootfs-overlay/etc/systemd/system/pf-app@.service"
owner_dropin="${root}/rootfs-overlay/etc/systemd/system/pocketforge-foreground.target.d/10-owner-shell.conf"
containerfile="${fixtures}/Containerfile"
approved_host=mm-build-vm
owned_build_lock="${HOME}/image/work/out"

runtime_sha=0589fcfa959dca9150563ef0ed18d7d44b420dc5
runtime_repository=https://github.com/pocketforge-os/runtime.git
app_unit_sha256=ecf620a219af3ca98760707e111fe301e420a9ba977a98ba149187a3bf6f622f
gib=$((1024 * 1024 * 1024))
disk_preflight_bytes=$((8 * gib))
disk_floor_bytes=$((4 * gib))

scope_initialized=0
cleanup_active=0
cleanup_podman_resources=0
run_started=0
run_completed=0
cleanup_failed=0
failure_reason=
root_min_free_bytes=
run_scope_peak_bytes=0
build_lock_fd=
run_scope=
podman_storage_root=
podman_runroot=
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

assert_approved_host() {
    [ "${guard_hostname}" = "${approved_host}" ] \
        || fail "UNAPPROVED_HOST: expected=${approved_host} actual=${guard_hostname}"
}

assert_host_idle() {
    local runner_units unit job_state status

    if pgrep -x Runner.Worker >/dev/null 2>&1; then
        fail 'HOST_BUSY: GitHub Actions Runner.Worker is active'
    else
        status=$?
        [ "${status}" -eq 1 ] \
            || fail "HOST_GUARD_UNAVAILABLE: pgrep Runner.Worker status=${status}"
    fi

    if ! runner_units="$(
        systemctl list-units 'actions.runner.*' --all --no-legend --no-pager --plain 2>/dev/null
    )"; then
        fail 'HOST_GUARD_UNAVAILABLE: actions runner unit query'
    fi
    while read -r unit _; do
        [ -n "${unit}" ] || continue
        job_state="$(systemctl show "${unit}" --property=Job --value 2>/dev/null)" \
            || fail "HOST_GUARD_UNAVAILABLE: actions runner job query unit=${unit}"
        case "${job_state}" in
            ''|0|'0 /'|'[0, /]') ;;
            *) fail "HOST_BUSY: actions runner systemd job unit=${unit} job=${job_state}" ;;
        esac
    done <<<"${runner_units}"

    if pgrep -f '(^|/)(build-owned-image[.]sh|pf-build[.]sh)( |$)|(^| )pf build( |$)' \
        >/dev/null 2>&1; then
        fail 'HOST_BUSY: PocketForge owned build process is active'
    else
        status=$?
        [ "${status}" -eq 1 ] \
            || fail "HOST_GUARD_UNAVAILABLE: pgrep owned build status=${status}"
    fi
}

acquire_owned_build_lock() {
    local resolved

    [ -d "${owned_build_lock}" ] && [ ! -L "${owned_build_lock}" ] \
        || fail "BUILD_LOCK_UNAVAILABLE: expected directory=${owned_build_lock}"
    resolved="$(readlink -f -- "${owned_build_lock}")" \
        || fail "BUILD_LOCK_UNAVAILABLE: cannot resolve ${owned_build_lock}"
    [ "${resolved}" = "${owned_build_lock}" ] \
        || fail "BUILD_LOCK_UNAVAILABLE: non-canonical path=${owned_build_lock} resolved=${resolved}"
    exec {build_lock_fd}<"${owned_build_lock}" \
        || fail "BUILD_LOCK_UNAVAILABLE: cannot open ${owned_build_lock}"
    flock -n "${build_lock_fd}" \
        || fail "HOST_BUSY: owned build lock held path=${owned_build_lock}"
}

measure_root_free_bytes() {
    local value
    value="$(LC_ALL=C df -B1 --output=avail / 2>/dev/null | awk 'NR == 2 { print $1; exit }')" \
        || return 1
    [[ "${value}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "${value}"
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

    if ! free_bytes="$(measure_root_free_bytes)" \
        || ! scope_bytes="$(measure_run_scope_bytes)"; then
        if [ "${cleanup_active}" -eq 1 ]; then
            cleanup_failed=1
            return 1
        fi
        fail "DISK_PROBE_FAILED: phase=${phase}"
    fi
    if [ -z "${root_min_free_bytes}" ] || [ "${free_bytes}" -lt "${root_min_free_bytes}" ]; then
        root_min_free_bytes="${free_bytes}"
    fi
    if [ "${scope_bytes}" -gt "${run_scope_peak_bytes}" ]; then
        run_scope_peak_bytes="${scope_bytes}"
    fi

    [ "${cleanup_active}" -eq 0 ] || return 0
    if [ "${run_started}" -eq 0 ]; then
        [ "${free_bytes}" -ge "${disk_preflight_bytes}" ] \
            || fail "INSUFFICIENT_DISK: available_bytes=${free_bytes} required_bytes=${disk_preflight_bytes}"
    else
        [ "${free_bytes}" -ge "${disk_floor_bytes}" ] \
            || fail "DISK_FLOOR_ABORT: phase=${phase} available_bytes=${free_bytes} floor_bytes=${disk_floor_bytes}"
    fi
}

configure_podman_scope() {
    run_scope="$1"
    podman_storage_root="${run_scope}/storage"
    podman_runroot="${run_scope}/runroot"
}

reject_device_volume() {
    local value="$1"
    local source_path="${value%%:*}"
    case "${source_path}" in
        /dev|/dev/*) fail "UNSAFE_CONTAINER_ARGV: host device bind=${value}" ;;
    esac
}

audit_container_argv() {
    local -a argv=("$@")
    local dashdash=--
    local root_option="${dashdash}root"
    local runroot_option="${dashdash}runroot"
    local privileged_option="${dashdash}privileged"
    local volume_option="${dashdash}volume"
    local mount_option="${dashdash}mount"
    local device_option="${dashdash}device"
    local capability_option="${dashdash}cap-add"
    local pid_option="${dashdash}pid"
    local network_option="${dashdash}network"
    local network_alias="${dashdash}net"
    local short_volume=-v
    local arg value index root_count=0 runroot_count=0

    [ -n "${podman_storage_root}" ] && [ -n "${podman_runroot}" ] \
        || fail 'UNSCOPED_CONTAINER_ARGV: storage paths are not configured'

    for ((index = 0; index < ${#argv[@]}; index++)); do
        arg="${argv[index]}"
        case "${arg}" in
            "${root_option}")
                value="${argv[index + 1]-}"
                root_count=$((root_count + 1))
                [ "${value}" = "${podman_storage_root}" ] \
                    || fail "UNSCOPED_CONTAINER_ARGV: root=${value:-missing}"
                ;;
            "${root_option}="*)
                value="${arg#*=}"
                root_count=$((root_count + 1))
                [ "${value}" = "${podman_storage_root}" ] \
                    || fail "UNSCOPED_CONTAINER_ARGV: root=${value:-missing}"
                ;;
            "${runroot_option}")
                value="${argv[index + 1]-}"
                runroot_count=$((runroot_count + 1))
                [ "${value}" = "${podman_runroot}" ] \
                    || fail "UNSCOPED_CONTAINER_ARGV: runroot=${value:-missing}"
                ;;
            "${runroot_option}="*)
                value="${arg#*=}"
                runroot_count=$((runroot_count + 1))
                [ "${value}" = "${podman_runroot}" ] \
                    || fail "UNSCOPED_CONTAINER_ARGV: runroot=${value:-missing}"
                ;;
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

    [ "${root_count}" -eq 1 ] \
        || fail "UNSCOPED_CONTAINER_ARGV: root_count=${root_count}"
    [ "${runroot_count}" -eq 1 ] \
        || fail "UNSCOPED_CONTAINER_ARGV: runroot_count=${runroot_count}"
}

scoped_podman_argv() {
    scoped_argv=(
        --root "${podman_storage_root}"
        --runroot "${podman_runroot}"
        "$@"
    )
}

podman_checked() {
    local status
    scoped_podman_argv "$@"
    audit_container_argv "${scoped_argv[@]}"
    sample_disk "before-podman-${1:-unknown}"
    if (exec {build_lock_fd}>&-; command podman "${scoped_argv[@]}"); then
        status=0
    else
        status=$?
    fi
    sample_disk "after-podman-${1:-unknown}"
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
        --hostname tsp-f3fm-211-systemd
        --systemd=always
        --cgroupns=private
        --network=none
        --security-opt=no-new-privileges
        --pids-limit=512
        --env=container=podman
        "${image_name}"
        /sbin/init
    )
}

print_argv() {
    printf 'podman'
    printf ' %q' "$@"
    printf '\n'
}

cleanup() {
    local status=$? receipt_result receipt_reason scope_removed=false
    local container_exists_status image_exists_status
    trap - EXIT INT TERM
    cleanup_active=1
    set +e

    if [ "${scope_initialized}" -eq 1 ] && [ -s "${run_scope}/failure-reason" ]; then
        failure_reason="$(<"${run_scope}/failure-reason")"
    fi
    sample_disk cleanup_begin >/dev/null 2>&1 || true
    if [ "${cleanup_podman_resources}" -eq 1 ] \
        && command -v podman >/dev/null 2>&1; then
        podman_checked rm --force "${systemd_container}" >/dev/null 2>&1
        podman_checked image rm --force "${test_image}" >/dev/null 2>&1
        podman_checked container exists "${systemd_container}" >/dev/null 2>&1
        container_exists_status=$?
        podman_checked image exists "${test_image}" >/dev/null 2>&1
        image_exists_status=$?
        if [ "${container_exists_status}" -eq 0 ] || [ "${image_exists_status}" -eq 0 ]; then
            cleanup_failed=1
            failure_reason='RESOURCE_CLEANUP_FAILED'
        elif [ "${container_exists_status}" -ne 1 ] || [ "${image_exists_status}" -ne 1 ]; then
            cleanup_failed=1
            failure_reason='RESOURCE_CLEANUP_AUDIT_FAILED'
        fi
    fi
    sample_disk cleanup_end >/dev/null 2>&1 || true

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

    if [ -n "${build_lock_fd}" ]; then
        flock -u "${build_lock_fd}" >/dev/null 2>&1 || cleanup_failed=1
        exec {build_lock_fd}>&-
    fi

    if [ "${status}" -eq 0 ] && [ "${run_completed}" -eq 1 ] && [ "${cleanup_failed}" -eq 0 ]; then
        receipt_result=PASS
        receipt_reason=completed
    else
        receipt_result=FAIL
        receipt_reason="${failure_reason:-UNEXPECTED_EXIT_${status}}"
        receipt_reason="${receipt_reason%%:*}"
        status=1
    fi

    if [ "${receipt_result}" = PASS ]; then
        echo "session-authority real-systemd: PASS ${pass_fields} run_scope_peak_bytes=${run_scope_peak_bytes} root_min_free_bytes=${root_min_free_bytes:-unknown} run_scope_removed=${scope_removed}"
    else
        echo "session-authority real-systemd: FAIL receipt_reason=${receipt_reason} run_scope_peak_bytes=${run_scope_peak_bytes} root_min_free_bytes=${root_min_free_bytes:-unknown} run_scope_removed=${scope_removed}" >&2
    fi
    exit "${status}"
}

case "${1:-}" in
    --audit-argv)
        [ "$#" -ge 3 ] || fail 'USAGE: --audit-argv RUN_SCOPE ARGV...'
        configure_podman_scope "$2"
        shift 2
        audit_container_argv "$@"
        echo 'session-authority container-argv-audit: PASS'
        exit 0
        ;;
    --audit-systemd-spec)
        [ "$#" -eq 2 ] || fail 'USAGE: --audit-systemd-spec RUN_SCOPE'
        configure_podman_scope "$2"
        make_systemd_argv test-image:fixture test-systemd-fixture
        scoped_podman_argv "${systemd_argv[@]}"
        audit_container_argv "${scoped_argv[@]}"
        print_argv "${scoped_argv[@]}"
        exit 0
        ;;
    --audit-lifecycle-argv)
        [ "$#" -eq 2 ] || fail 'USAGE: --audit-lifecycle-argv RUN_SCOPE'
        configure_podman_scope "$2"
        systemd_container=test-systemd-fixture
        test_image=test-image:fixture
        lifecycle_commands=(
            'info --format json'
            '--version'
            'build --iidfile /scope/image-id --tag test-image:fixture --file /scope/Containerfile /scope'
            'exec test-systemd-fixture /bin/true'
            'logs test-systemd-fixture'
            'container inspect test-systemd-fixture'
            'rm --force test-systemd-fixture'
            'image rm --force test-image:fixture'
            'container exists test-systemd-fixture'
            'image exists test-image:fixture'
        )
        make_systemd_argv "${test_image}" "${systemd_container}"
        scoped_podman_argv "${systemd_argv[@]}"
        audit_container_argv "${scoped_argv[@]}"
        print_argv "${scoped_argv[@]}"
        for command_line in "${lifecycle_commands[@]}"; do
            read -r -a command_argv <<<"${command_line}"
            scoped_podman_argv "${command_argv[@]}"
            audit_container_argv "${scoped_argv[@]}"
            print_argv "${scoped_argv[@]}"
        done
        exit 0
        ;;
    --check-host-guard)
        [ "$#" -eq 2 ] || fail 'USAGE: --check-host-guard FIXTURE_ROOT'
        assert_safe_host "$2"
        assert_approved_host
        echo "session-authority host-guard: PASS host=${guard_hostname}"
        exit 0
        ;;
    --check-admission)
        [ "$#" -eq 2 ] || fail 'USAGE: --check-admission FIXTURE_ROOT'
        assert_safe_host "$2"
        assert_approved_host
        assert_host_idle
        command -v flock >/dev/null 2>&1 || fail 'HOST_GUARD_UNAVAILABLE: flock'
        acquire_owned_build_lock
        assert_host_idle
        admission_free_bytes="$(measure_root_free_bytes)" \
            || fail 'DISK_PROBE_FAILED: admission'
        [ "${admission_free_bytes}" -ge "${disk_preflight_bytes}" ] \
            || fail "INSUFFICIENT_DISK: available_bytes=${admission_free_bytes} required_bytes=${disk_preflight_bytes}"
        if flock -n "${owned_build_lock}" true >/dev/null 2>&1; then
            fail 'BUILD_LOCK_NOT_HELD: second claimant acquired the owned build lock'
        fi
        echo "session-authority admission: PASS host=${guard_hostname} build_lock=${owned_build_lock} lock_held=true available_bytes=${admission_free_bytes}"
        flock -u "${build_lock_fd}"
        exec {build_lock_fd}>&-
        exit 0
        ;;
    --check-scoped-probe)
        [ "$#" -eq 2 ] || fail 'USAGE: --check-scoped-probe FIXTURE_ROOT'
        assert_safe_host "$2"
        assert_approved_host
        assert_host_idle
        for command_name in flock podman; do
            command -v "${command_name}" >/dev/null 2>&1 \
                || fail "MISSING_PREREQUISITE: ${command_name}"
        done
        acquire_owned_build_lock
        assert_host_idle
        run_scope="$(mktemp -d /tmp/tsp-f3fm-211.XXXXXX)"
        configure_podman_scope "${run_scope}"
        mkdir -p "${podman_storage_root}" "${podman_runroot}"
        scope_initialized=1
        trap cleanup EXIT INT TERM
        sample_disk preflight
        run_started=1
        probe_version="$(podman_checked --version)" \
            || fail_recorded_or 'PODMAN_UNAVAILABLE: version query failed'
        pass_fields="probe=podman-version podman_version=${probe_version##* } build_lock=${owned_build_lock}"
        run_completed=1
        exit 0
        ;;
    '')
        ;;
    *)
        fail "USAGE: $0 [--audit-argv RUN_SCOPE ARGV...|--audit-systemd-spec RUN_SCOPE|--audit-lifecycle-argv RUN_SCOPE|--check-host-guard FIXTURE_ROOT|--check-admission FIXTURE_ROOT|--check-scoped-probe FIXTURE_ROOT]"
        ;;
esac

# These guards stay ahead of every Podman probe. A refused workstation, active
# runner, active owned build, held build lock, or short disk never reaches Podman.
assert_safe_host /
assert_approved_host
assert_host_idle

for command_name in flock git podman python3 sha256sum; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "MISSING_PREREQUISITE: ${command_name}"
done
[ "$(id -u)" -ne 0 ] || fail 'ROOTLESS_PODMAN_REQUIRED: do not run as root'
[ "$(uname -m)" = x86_64 ] || fail "AMD64_REQUIRED: host architecture is $(uname -m)"

acquire_owned_build_lock
assert_host_idle

run_scope="$(mktemp -d /tmp/tsp-f3fm-211.XXXXXX)"
configure_podman_scope "${run_scope}"
runtime="${run_scope}/runtime"
context="${run_scope}/context"
image_id_file="${run_scope}/image-id"
systemd_container="tsp-f3fm-211-systemd-$$"
test_image="tsp-f3fm-211-systemd:${runtime_sha:0:12}-$$"
mkdir -p "${podman_storage_root}" "${podman_runroot}"
scope_initialized=1
trap cleanup EXIT INT TERM

sample_disk preflight
run_started=1

podman_info="$(podman_checked info --format json 2>/dev/null)" \
    || fail_recorded_or 'PODMAN_UNAVAILABLE: rootless Podman is not usable'
podman_fields="$(
    python3 -c '
import json, sys
host = json.load(sys.stdin)["host"]
print(
    str(host["security"]["rootless"]).lower(),
    host["cgroupVersion"],
    host["cgroupManager"],
    host["arch"],
)
' <<<"${podman_info}"
)" || fail 'PODMAN_INFO_UNREADABLE: missing rootless/cgroup/architecture fields'
read -r podman_rootless podman_cgroup podman_cgroup_manager podman_arch <<<"${podman_fields}"
[ "${podman_rootless}" = true ] || fail 'ROOTLESS_PODMAN_REQUIRED: Podman reports rootless=false'
[ "${podman_cgroup}" = v2 ] || fail "CGROUP_V2_REQUIRED: got ${podman_cgroup}"
[ "${podman_cgroup_manager}" = systemd ] \
    || fail "SYSTEMD_CGROUP_MANAGER_REQUIRED: got ${podman_cgroup_manager}"
case "${podman_arch}" in
    amd64|x86_64) ;;
    *) fail "AMD64_REQUIRED: Podman architecture is ${podman_arch}" ;;
esac
podman_version="$(podman_checked --version | awk '{print $3}')" \
    || fail_recorded_or 'PODMAN_UNAVAILABLE: version query failed'

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
install -m 0644 "${fixtures}/app.toml" "${context}/app.toml"
install -m 0755 "${fixtures}/fixture" "${context}/fixture"
install -m 0644 "${fixtures}/platform-capabilities.toml" \
    "${context}/platform-capabilities.toml"
install -m 0755 "${fixtures}/drive.py" "${context}/drive.py"
sample_disk build_context

cleanup_podman_resources=1
podman_checked build \
    --build-arg "PF_RUNTIME_SHA=${runtime_sha}" \
    --iidfile "${image_id_file}" \
    --tag "${test_image}" \
    --file "${context}/Containerfile" \
    "${context}" \
    || fail_recorded_or 'IMAGE_BUILD_FAILED: rootless Podman build failed'
test_image_digest="$(<"${image_id_file}")"

make_systemd_argv "${test_image}" "${systemd_container}"
scoped_podman_argv "${systemd_argv[@]}"
audit_container_argv "${scoped_argv[@]}"
podman_checked "${systemd_argv[@]}" >/dev/null \
    || fail_recorded_or 'SYSTEMD_PID1_UNAVAILABLE: rootless Podman run failed'

systemd_ready=0
for _ in $(seq 1 120); do
    if podman_checked exec "${systemd_container}" /bin/sh -c '
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
    podman_checked logs "${systemd_container}" >&2 || true
    fail 'SYSTEMD_PID1_UNAVAILABLE: rootless Podman did not boot a usable systemd PID 1'
fi

container_unit_sha256="$(
    podman_checked exec "${systemd_container}" \
        sha256sum /etc/systemd/system/pf-app@.service | awk '{print $1}'
)" || fail_recorded_or 'CONTAINER_APP_UNIT_HASH_FAILED'
[ "${container_unit_sha256}" = "${app_unit_sha256}" ] \
    || fail "CONTAINER_APP_UNIT_DRIFT: got ${container_unit_sha256}"

host_vt_devices="$(
    podman_checked exec "${systemd_container}" /bin/sh -ceu '
        for path in /dev/tty[0-9]*; do
            [ -e "${path}" ] || continue
            printf "%s\n" "${path}"
        done
    '
)" || fail_recorded_or 'HOST_VT_PROBE_FAILED'
[ -z "${host_vt_devices}" ] \
    || fail "HOST_VT_EXPOSED: ${host_vt_devices//$'\n'/,}"

getty_units_masked="$(
    podman_checked exec "${systemd_container}" /bin/sh -ceu '
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
    podman_checked container inspect \
        --format '{{.Config.Tty}} {{.HostConfig.NetworkMode}}' \
        "${systemd_container}"
)" || fail_recorded_or 'CONTAINER_ISOLATION_PROBE_FAILED'
[ "${container_isolation}" = 'true none' ] \
    || fail "CONTAINER_ISOLATION_DRIFT: ${container_isolation}"

if ! test_output="$(
    podman_checked exec "${systemd_container}" /usr/local/libexec/drive.py 2>&1
)"; then
    [ ! -s "${run_scope}/failure-reason" ] || fail_recorded_or 'DISK_FLOOR_ABORT'
    echo "${test_output}" >&2
    podman_checked exec "${systemd_container}" \
        journalctl --no-pager --output short-monotonic --lines 200 \
        --unit pf-session-authorityd.service \
        --unit pf-app@org.pocketforge.fixture.service \
        --unit pf-shell-selected.service >&2 || true
    fail 'INTEGRATION_ASSERTION_FAILED'
fi
echo "${test_output}"
sample_disk integration_complete
pass_fields="runtime_sha=${runtime_sha} container_image_digest=${test_image_digest} fail_closed=SYSTEMD_PID1_UNAVAILABLE podman_version=${podman_version} rootless=${podman_rootless} cgroup=${podman_cgroup} cgroup_manager=${podman_cgroup_manager} tty=true network=none host_vt_devices=none getty_units_masked=${getty_units_masked} build_lock=${owned_build_lock}"
run_completed=1
