#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="${root}/tests/session-authority-systemd"
app_unit="${root}/rootfs-overlay/etc/systemd/system/pf-app@.service"
owner_dropin="${root}/rootfs-overlay/etc/systemd/system/pocketforge-foreground.target.d/10-owner-shell.conf"
containerfile="${fixtures}/Containerfile"
approved_host=mm-build-vm

runtime_sha=0589fcfa959dca9150563ef0ed18d7d44b420dc5
runtime_repository=https://github.com/pocketforge-os/runtime.git
app_unit_sha256=ecf620a219af3ca98760707e111fe301e420a9ba977a98ba149187a3bf6f622f

fail() {
    echo "session-authority real-systemd: FAIL: $*" >&2
    exit 1
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
    local privileged_option="${dashdash}privileged"
    local volume_option="${dashdash}volume"
    local mount_option="${dashdash}mount"
    local device_option="${dashdash}device"
    local capability_option="${dashdash}cap-add"
    local pid_option="${dashdash}pid"
    local network_option="${dashdash}network"
    local network_alias="${dashdash}net"
    local short_volume=-v
    local arg value index

    for ((index = 0; index < ${#argv[@]}; index++)); do
        arg="${argv[index]}"
        case "${arg}" in
            "${privileged_option}"|"${privileged_option}="*)
                fail "UNSAFE_CONTAINER_ARGV: ${arg}"
                ;;
            "${device_option}"|"${device_option}="*)
                fail "UNSAFE_CONTAINER_ARGV: host device option"
                ;;
            "${capability_option}"|"${capability_option}="*)
                fail "UNSAFE_CONTAINER_ARGV: added capability"
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

case "${1:-}" in
    --audit-argv)
        shift
        audit_container_argv "$@"
        echo 'session-authority container-argv-audit: PASS'
        exit 0
        ;;
    --audit-systemd-spec)
        [ "$#" -eq 1 ] || fail 'USAGE: --audit-systemd-spec'
        make_systemd_argv test-image:fixture test-systemd-fixture
        audit_container_argv "${systemd_argv[@]}"
        print_argv "${systemd_argv[@]}"
        exit 0
        ;;
    --check-host-guard)
        [ "$#" -eq 2 ] || fail 'USAGE: --check-host-guard FIXTURE_ROOT'
        assert_safe_host "$2"
        assert_approved_host
        echo "session-authority host-guard: PASS host=${guard_hostname}"
        exit 0
        ;;
    '')
        ;;
    *)
        fail "USAGE: $0 [--audit-argv ARGV...|--audit-systemd-spec|--check-host-guard FIXTURE_ROOT]"
        ;;
esac

# This is deliberately before every Podman probe and before installing the
# cleanup trap. A refusal cannot reach the container runtime, even indirectly.
assert_safe_host /
assert_approved_host

for command_name in cargo file git install podman python3 rustup sha256sum; do
    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "MISSING_PREREQUISITE: ${command_name}"
done
[ "$(id -u)" -ne 0 ] || fail 'ROOTLESS_PODMAN_REQUIRED: do not run as root'
[ "$(uname -m)" = x86_64 ] || fail "AMD64_REQUIRED: host architecture is $(uname -m)"

podman_info="$(command podman info --format json 2>/dev/null)" \
    || fail 'PODMAN_UNAVAILABLE: rootless Podman is not usable'
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
podman_version="$(command podman --version | awk '{print $3}')" \
    || fail 'PODMAN_UNAVAILABLE: version query failed'
rustup target list --installed | grep -Fxq x86_64-unknown-linux-musl \
    || fail 'MISSING_PREREQUISITE: rust target x86_64-unknown-linux-musl'

actual_unit_sha256="$(sha256sum "${app_unit}" | awk '{print $1}')"
[ "${actual_unit_sha256}" = "${app_unit_sha256}" ] \
    || fail "APP_UNIT_DRIFT: expected ${app_unit_sha256}, got ${actual_unit_sha256}"

tmp="$(mktemp -d /tmp/tsp-f3fm-211.XXXXXX)"
runtime="${tmp}/runtime"
context="${tmp}/context"
image_id_file="${tmp}/image-id"
systemd_container="tsp-f3fm-211-systemd-$$"
test_image="tsp-f3fm-211-systemd:${runtime_sha:0:12}-$$"
cleanup_failed=0

podman_checked() {
    audit_container_argv "$@"
    command podman "$@"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    podman_checked rm --force "${systemd_container}" >/dev/null 2>&1
    podman_checked image rm --force "${test_image}" >/dev/null 2>&1
    if podman_checked container exists "${systemd_container}" >/dev/null 2>&1 \
        || podman_checked image exists "${test_image}" >/dev/null 2>&1; then
        echo 'session-authority real-systemd: FAIL: RESOURCE_CLEANUP_FAILED' >&2
        cleanup_failed=1
    fi
    find "${tmp}" -mindepth 1 -delete >/dev/null 2>&1
    rmdir "${tmp}" >/dev/null 2>&1
    [ "${cleanup_failed}" -eq 0 ] || status=1
    exit "${status}"
}
trap cleanup EXIT INT TERM

git clone --quiet "${runtime_repository}" "${runtime}"
git -C "${runtime}" checkout --quiet --detach "${runtime_sha}"
[ "$(git -C "${runtime}" rev-parse HEAD)" = "${runtime_sha}" ] \
    || fail 'RUNTIME_SHA_MISMATCH'

CARGO_TARGET_DIR="${tmp}/target" cargo build \
    --manifest-path "${runtime}/Cargo.toml" \
    --release --locked --target x86_64-unknown-linux-musl \
    -p pf-session-authority -p pf-app-launch

authority_binary="${tmp}/target/x86_64-unknown-linux-musl/release/pf-session-authorityd"
app_launch_binary="${tmp}/target/x86_64-unknown-linux-musl/release/pf-app-launch"
for binary in "${authority_binary}" "${app_launch_binary}"; do
    file "${binary}" | grep -Fq 'x86-64' || fail "NON_AMD64_RUNTIME_BINARY: ${binary}"
    file "${binary}" | grep -Fq 'static-pie linked' || fail "NON_STATIC_RUNTIME_BINARY: ${binary}"
done

mkdir "${context}"
install -m 0644 "${containerfile}" "${context}/Containerfile"
install -m 0755 "${authority_binary}" "${context}/pf-session-authorityd"
install -m 0755 "${app_launch_binary}" "${context}/pf-app-launch"
install -m 0644 "${runtime}/systemd/pf-session-authorityd.service" \
    "${context}/pf-session-authorityd.service"
install -m 0644 "${runtime}/systemd/pocketforge.conf" "${context}/pocketforge.conf"
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

podman_checked build \
    --iidfile "${image_id_file}" \
    --tag "${test_image}" \
    --file "${context}/Containerfile" \
    "${context}"
test_image_digest="$(<"${image_id_file}")"

make_systemd_argv "${test_image}" "${systemd_container}"
audit_container_argv "${systemd_argv[@]}"
podman_checked "${systemd_argv[@]}" >/dev/null

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
    sleep 0.1
done
if [ "${systemd_ready}" -ne 1 ]; then
    podman_checked logs "${systemd_container}" >&2 || true
    fail 'SYSTEMD_PID1_UNAVAILABLE: rootless Podman did not boot a usable systemd PID 1'
fi

container_unit_sha256="$(
    podman_checked exec "${systemd_container}" \
        sha256sum /etc/systemd/system/pf-app@.service | awk '{print $1}'
)"
[ "${container_unit_sha256}" = "${app_unit_sha256}" ] \
    || fail "CONTAINER_APP_UNIT_DRIFT: got ${container_unit_sha256}"

host_vt_devices="$(
    podman_checked exec "${systemd_container}" /bin/sh -ceu '
        for path in /dev/tty[0-9]*; do
            [ -e "${path}" ] || continue
            printf "%s\n" "${path}"
        done
    '
)"
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
)"
[ "${getty_units_masked}" = 5 ] \
    || fail "GETTY_MASK_INCOMPLETE: count=${getty_units_masked}"

container_isolation="$(
    podman_checked container inspect \
        --format '{{.Config.Tty}} {{.HostConfig.NetworkMode}}' \
        "${systemd_container}"
)"
[ "${container_isolation}" = 'true none' ] \
    || fail "CONTAINER_ISOLATION_DRIFT: ${container_isolation}"

if ! test_output="$(
    podman_checked exec "${systemd_container}" /usr/local/libexec/drive.py 2>&1
)"; then
    echo "${test_output}" >&2
    podman_checked exec "${systemd_container}" \
        journalctl --no-pager --output short-monotonic --lines 200 \
        --unit pf-session-authorityd.service \
        --unit pf-app@org.pocketforge.fixture.service \
        --unit pf-shell-selected.service >&2 || true
    fail 'INTEGRATION_ASSERTION_FAILED'
fi
echo "${test_output}"
echo "session-authority real-systemd: PASS runtime_sha=${runtime_sha} container_image_digest=${test_image_digest} fail_closed=SYSTEMD_PID1_UNAVAILABLE podman_version=${podman_version} rootless=${podman_rootless} cgroup=${podman_cgroup} cgroup_manager=${podman_cgroup_manager} tty=true network=none host_vt_devices=none getty_units_masked=${getty_units_masked}"
