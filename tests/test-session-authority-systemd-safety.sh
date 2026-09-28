#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="${root}/tests/test-session-authority-systemd.sh"
recipe="${root}/tests/session-authority-systemd/Containerfile"
driver="${root}/tests/session-authority-systemd/drive.py"
precondition_verifier="${root}/tests/verify-session-authority-systemd-preconditions.py"
tmp="$(mktemp -d /tmp/tsp-f3fm-211-safety.XXXXXX)"
fake_bin="${tmp}/bin"
fake_root="${tmp}/host"
fake_home="${tmp}/home"
call_log="${tmp}/podman-calls"
df_counter="${tmp}/df-counter"
stdout_log="${tmp}/stdout"
stderr_log="${tmp}/stderr"
lock_holder_pid=

cleanup() {
    if [ -n "${lock_holder_pid}" ] && kill -0 "${lock_holder_pid}" 2>/dev/null; then
        kill "${lock_holder_pid}" 2>/dev/null || true
        wait "${lock_holder_pid}" 2>/dev/null || true
    fi
    find "${tmp}" -mindepth 1 -delete
    rmdir "${tmp}"
}
trap cleanup EXIT

mkdir -p \
    "${fake_bin}" \
    "${fake_root}/tmp/.X11-unix" \
    "${fake_root}/run/user" \
    "${fake_home}/image/work/out"
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
            case "${arg}" in
                --property=*) property="${arg#*=}" ;;
            esac
        done
        case "${property}" in
            Active) echo yes ;;
            Seat) [ "${FAKE_GRAPHICAL:-0}" -eq 0 ] || echo seat0 ;;
            Type)
                if [ "${FAKE_GRAPHICAL:-0}" -eq 1 ]; then
                    echo wayland
                else
                    echo tty
                fi
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
    list-units)
        if [ "${FAKE_RUNNER_UNIT_JOB:-0}" -eq 1 ]; then
            echo 'actions.runner.pocketforge.build-vm.service loaded active running runner'
        fi
        ;;
    show)
        if [ "${FAKE_RUNNER_UNIT_JOB:-0}" -eq 1 ]; then
            echo '123 /org/freedesktop/systemd1/job/123'
        else
            echo '0 /'
        fi
        ;;
    *) exit 2 ;;
esac
EOF

cat >"${fake_bin}/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    *Runner.Worker*) [ "${FAKE_RUNNER_BUSY:-0}" -eq 1 ] && exit 0 ;;
    *build-owned-image*|*pf-build*) [ "${FAKE_BUILD_BUSY:-0}" -eq 1 ] && exit 0 ;;
    *gdm*|*gdm3*|*sddm*|*lightdm*|*xdm*) [ "${FAKE_DISPLAY_PROCESS:-0}" -eq 1 ] && exit 0 ;;
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
        if [ "${count}" -eq 1 ]; then
            value=$((9 * 1024 * 1024 * 1024))
        else
            value=$((3 * 1024 * 1024 * 1024))
        fi
        ;;
    *) exit 2 ;;
esac
printf 'Avail\n%s\n' "${value}"
EOF

cat >"${fake_bin}/du" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="${*: -1}"
printf '65536\t%s\n' "${path}"
EOF

cat >"${fake_bin}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
runtime_sha=0589fcfa959dca9150563ef0ed18d7d44b420dc5
if [ "${1:-}" = clone ]; then
    destination="${*: -1}"
    mkdir -p \
        "${destination}/.git" \
        "${destination}/.cargo" \
        "${destination}/scripts" \
        "${destination}/systemd"
    printf '[workspace]\nmembers=[]\n' >"${destination}/Cargo.toml"
    printf '# fake lock\n' >"${destination}/Cargo.lock"
    printf '[net]\noffline=true\n' >"${destination}/.cargo/config.toml"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${destination}/scripts/check-vendor.sh"
    chmod +x "${destination}/scripts/check-vendor.sh"
    printf '[Service]\nExecStart=/usr/bin/pf-session-authorityd\n' \
        >"${destination}/systemd/pf-session-authorityd.service"
    printf 'd /run/pocketforge 0755 gamer gamer -\n' \
        >"${destination}/systemd/pocketforge.conf"
    exit 0
fi
if [ "${1:-}" = -C ]; then
    case "${3:-}" in
        fetch|checkout) exit 0 ;;
        rev-parse) printf '%s\n' "${runtime_sha}"; exit 0 ;;
    esac
fi
exit 2
EOF

cat >"${fake_bin}/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = --root ] || { echo 'fake podman: missing leading root' >&2; exit 95; }
storage_root="${2:-}"
[ "${3:-}" = --runroot ] || { echo 'fake podman: missing leading runroot' >&2; exit 95; }
runroot="${4:-}"
scope="${storage_root%/storage}"
[ "${storage_root}" = "${scope}/storage" ] || exit 95
[ "${runroot}" = "${scope}/runroot" ] || exit 95
case "${scope}" in /tmp/tsp-f3fm-211.*) ;; *) exit 95 ;; esac
case "${storage_root}:${runroot}" in *"${HOME}/.local/share/containers"*) exit 95 ;; esac
if flock -n "${HOME}/image/work/out" true >/dev/null 2>&1; then
    echo 'fake podman: owned build lock was not held' >&2
    exit 96
fi
mkdir -p "${storage_root}/fixture"
: >"${storage_root}/fixture/fake-layer"
shift 4
printf 'scope=%s root=%s runroot=%s lock=held cmd=%s\n' \
    "${scope}" "${storage_root}" "${runroot}" "$*" >>"${PODMAN_CALL_LOG:?}"

case "${1:-}" in
    info)
        printf '%s\n' '{"host":{"security":{"rootless":true},"cgroupVersion":"v2","cgroupManager":"systemd","arch":"amd64"}}'
        ;;
    --version)
        echo 'podman version 5.4.2'
        ;;
    build)
        iidfile=
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --iidfile ]; then
                iidfile="$2"
                shift 2
            else
                shift
            fi
        done
        [ -n "${iidfile}" ] || exit 2
        printf 'sha256:fake-systemd-image\n' >"${iidfile}"
        ;;
    run)
        echo fake-container-id
        ;;
    exec)
        case "$*" in
            *'sha256sum /etc/systemd/system/pf-app@.service'*)
                echo 'ecf620a219af3ca98760707e111fe301e420a9ba977a98ba149187a3bf6f622f  /etc/systemd/system/pf-app@.service'
                ;;
            *'getty@.service'*) echo 5 ;;
            *'/usr/local/libexec/drive.py'*)
                echo 'evidence: clean_session=session-1 returned=1 restart_mid_ladder=ok crash_session=session-2 crash=1 returned=0 clean_invocations=1 crash_invocations=1 fb0=empty-regular-file session_scoping_negative_control=ok refused_systemctl_starts=0 owner_restore=ok'
                ;;
            *) ;;
        esac
        ;;
    rm|logs) ;;
    image)
        case "${2:-}" in rm) ;; exists) exit 1 ;; *) exit 2 ;; esac
        ;;
    container)
        case "${2:-}" in
            inspect) echo 'true none' ;;
            exists) exit 1 ;;
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
        HOME="${fake_home}" \
        PODMAN_CALL_LOG="${call_log}" \
        FAKE_DF_COUNTER="${df_counter}" \
        FAKE_HOSTNAME="${FAKE_HOSTNAME:-mm-build-vm}" \
        FAKE_GRAPHICAL="${FAKE_GRAPHICAL:-0}" \
        FAKE_DISPLAY_MANAGER="${FAKE_DISPLAY_MANAGER:-0}" \
        FAKE_DISPLAY_PROCESS="${FAKE_DISPLAY_PROCESS:-0}" \
        FAKE_RUNNER_BUSY="${FAKE_RUNNER_BUSY:-0}" \
        FAKE_RUNNER_UNIT_JOB="${FAKE_RUNNER_UNIT_JOB:-0}" \
        FAKE_BUILD_BUSY="${FAKE_BUILD_BUSY:-0}" \
        FAKE_DISK_MODE="${FAKE_DISK_MODE:-ample}" \
        bash "${harness}" "$@"
}

reset_logs
FAKE_GRAPHICAL=1
if run_fake >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: graphical host passed guard' >&2
    exit 1
fi
FAKE_GRAPHICAL=0
grep -Fq 'INTERACTIVE_WORKSTATION: active session=7 seat=seat0 type=wayland' "${stderr_log}" || {
    echo 'session-authority systemd-safety: FAIL: graphical refusal reason missing' >&2
    cat "${stderr_log}" >&2
    exit 1
}
[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-safety: FAIL: graphical refusal reached Podman' >&2
    exit 1
}

reset_logs
run_fake --check-host-guard "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"
grep -Fqx 'session-authority host-guard: PASS host=mm-build-vm' "${stdout_log}" || {
    echo 'session-authority systemd-safety: FAIL: simulated headless host did not pass' >&2
    exit 1
}

reset_logs
FAKE_DISPLAY_MANAGER=1
if run_fake --check-host-guard "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: display manager passed guard' >&2
    exit 1
fi
FAKE_DISPLAY_MANAGER=0
grep -Fq 'INTERACTIVE_WORKSTATION: active display-manager.service' "${stderr_log}" || exit 1

reset_logs
FAKE_HOSTNAME=matt-laptop
if run_fake --check-host-guard "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: owner workstation passed allowlist' >&2
    exit 1
fi
FAKE_HOSTNAME=mm-build-vm
grep -Fq 'UNAPPROVED_HOST: expected=mm-build-vm actual=matt-laptop' "${stderr_log}" || exit 1

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
FAKE_RUNNER_BUSY=1
if run_fake --check-admission "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: active Runner.Worker passed admission' >&2
    exit 1
fi
FAKE_RUNNER_BUSY=0
grep -Fq 'HOST_BUSY: GitHub Actions Runner.Worker is active' "${stderr_log}" || exit 1

reset_logs
FAKE_RUNNER_UNIT_JOB=1
if run_fake --check-admission "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: runner systemd job passed admission' >&2
    exit 1
fi
FAKE_RUNNER_UNIT_JOB=0
grep -Fq 'HOST_BUSY: actions runner systemd job' "${stderr_log}" || exit 1

lock_ready="${tmp}/lock-ready"
lock_release="${tmp}/lock-release"
mkfifo "${lock_release}"
(
    exec 8<"${fake_home}/image/work/out"
    flock -x 8
    printf 'ready\n' >"${lock_ready}"
    read -r _ <"${lock_release}"
) &
lock_holder_pid=$!
for _ in $(seq 1 40); do
    [ -s "${lock_ready}" ] && break
    sleep 0.05
done
[ -s "${lock_ready}" ] || { echo 'lock fixture did not start' >&2; exit 1; }
reset_logs
if run_fake --check-admission "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: held owned-build lock passed admission' >&2
    exit 1
fi
grep -Fq 'HOST_BUSY: owned build lock held' "${stderr_log}" || exit 1
printf 'release\n' >"${lock_release}"
wait "${lock_holder_pid}"
lock_holder_pid=

reset_logs
if ! run_fake --check-admission "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: headless admission failed after lock release' >&2
    cat "${stdout_log}" "${stderr_log}" >&2
    exit 1
fi
grep -Fq 'lock_held=true' "${stdout_log}" || {
    echo 'session-authority systemd-safety: FAIL: admission did not prove held lock' >&2
    exit 1
}
flock -n "${fake_home}/image/work/out" true || {
    echo 'session-authority systemd-safety: FAIL: admission did not release lock on exit' >&2
    exit 1
}

reset_logs
FAKE_DISK_MODE=preflight-low
if run_fake --check-admission "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: low preflight disk passed admission' >&2
    exit 1
fi
FAKE_DISK_MODE=ample
grep -Fq 'INSUFFICIENT_DISK:' "${stderr_log}" || exit 1

audit_scope="${tmp}/audit-scope"
reset_logs
run_fake --audit-systemd-spec "${audit_scope}" >"${stdout_log}" 2>"${stderr_log}"
safe_spec="$(cat "${stdout_log}")"
for required in \
    "--root ${audit_scope}/storage" \
    "--runroot ${audit_scope}/runroot" \
    '--tty' \
    '--systemd=always' \
    '--network=none' \
    '--cgroupns=private'; do
    grep -Fq -- "${required}" "${stdout_log}" || {
        echo "session-authority systemd-safety: FAIL: safe spec missing ${required}" >&2
        exit 1
    }
done
if grep -Eq -- '--privileged|--network([ =])host|--pid([ =])host|--cap-add|--device|(-v|--volume)(=| )[[:space:]]*/dev' \
    <<<"${safe_spec}"; then
    echo 'session-authority systemd-safety: FAIL: safe spec contains a forbidden option' >&2
    exit 1
fi

expect_rejected() {
    local label="$1"
    shift
    if run_fake --audit-argv "${audit_scope}" "$@" >"${stdout_log}" 2>"${stderr_log}"; then
        echo "session-authority systemd-safety: FAIL: unsafe argv passed label=${label}" >&2
        exit 1
    fi
    grep -Eq 'UNSAFE_CONTAINER_ARGV:|UNSCOPED_CONTAINER_ARGV:' "${stderr_log}" || {
        echo "session-authority systemd-safety: FAIL: unsafe argv reason missing label=${label}" >&2
        cat "${stderr_log}" >&2
        exit 1
    }
}

scoped=(--root "${audit_scope}/storage" --runroot "${audit_scope}/runroot")
expect_rejected unscoped run image
expect_rejected wrong-root --root /tmp/wrong --runroot "${audit_scope}/runroot" run image
expect_rejected privilege "${scoped[@]}" run --privileged image
expect_rejected device-tree "${scoped[@]}" run -v /dev:/dev image
expect_rejected console-bind "${scoped[@]}" run --volume=/dev/console:/dev/console image
expect_rejected tty-device "${scoped[@]}" run --device /dev/tty2 image
expect_rejected host-pids "${scoped[@]}" run --pid=host image
expect_rejected tty-capability "${scoped[@]}" run --cap-add CAP_SYS_TTY_CONFIG image
expect_rejected admin-capability "${scoped[@]}" run --cap-add=CAP_SYS_ADMIN image
expect_rejected host-network "${scoped[@]}" run --network host image
expect_rejected device-mount "${scoped[@]}" run --mount type=bind,source=/dev/console,target=/console image

grep -Eq '^FROM docker[.]io/library/rust:1[.]85-bookworm@sha256:[0-9a-f]{64} AS runtime-builder$' \
    "${recipe}" || {
    echo 'session-authority systemd-safety: FAIL: Rust builder is not digest pinned' >&2
    exit 1
}
grep -Fq 'cargo fetch --locked --offline' "${recipe}" || exit 1
grep -Fq 'cargo build --release --locked --offline' "${recipe}" || exit 1
[ "$(grep -Fc 'COPY --from=runtime-builder' "${recipe}")" -eq 2 ] || {
    echo 'session-authority systemd-safety: FAIL: builder exports more than two binaries' >&2
    exit 1
}
for binary in pf-session-authorityd pf-app-launch; do
    grep -Fq "COPY --from=runtime-builder /out/${binary}" "${recipe}" || exit 1
done
for unit in \
    getty@.service \
    getty.target \
    console-getty.service \
    serial-getty@.service \
    autovt@.service; do
    grep -Fq "/etc/systemd/system/${unit}" "${recipe}" || exit 1
done
grep -Fq 'ln -sf /dev/null' "${recipe}" || exit 1
grep -Fq 'session-authority-test.target /etc/systemd/system/session-authority-test.target' \
    "${recipe}" || exit 1
if grep -Eq '\bmknod\b|^[[:space:]]*[cb][+!]?[[:space:]]+/dev/fb0([[:space:]]|$)' \
    "${recipe}" "${root}/tests/session-authority-systemd/session-authority-test-tmpfiles.conf"; then
    echo 'session-authority systemd-safety: FAIL: framebuffer placeholder is a device node' >&2
    exit 1
fi
precondition_output="$(python3 "${precondition_verifier}")"
grep -Fqx \
    'session-authority path-preconditions: PASS conditions=1 providers=1 fb0=regular units=5' \
    <<<"${precondition_output}" || {
    echo 'session-authority systemd-safety: FAIL: path precondition audit did not pass' >&2
    echo "${precondition_output}" >&2
    exit 1
}
unprovided_unit="${tmp}/unprovided.service"
printf '[Unit]\nConditionPathExists=/unprovided-test-path\n' >"${unprovided_unit}"
if python3 "${precondition_verifier}" --unit "${unprovided_unit}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: unprovided path condition passed audit' >&2
    exit 1
fi
grep -Fq 'unprovided ConditionPathExists=/unprovided-test-path' "${stderr_log}" || {
    echo 'session-authority systemd-safety: FAIL: unprovided path refusal reason missing' >&2
    cat "${stderr_log}" >&2
    exit 1
}
if grep -Fq 'Path("/dev/fb0").touch()' "${driver}"; then
    echo 'session-authority systemd-safety: FAIL: driver creates its own framebuffer prerequisite' >&2
    exit 1
fi
grep -Fq 'framebuffer.is_file() and framebuffer.stat().st_size == 0' "${driver}" || {
    echo 'session-authority systemd-safety: FAIL: driver does not require an empty regular framebuffer file' >&2
    exit 1
}
for invocation_field in clean_invocations crash_invocations; do
    grep -Fq "${invocation_field}=" "${driver}" || {
        echo "session-authority systemd-safety: FAIL: live evidence lacks ${invocation_field}" >&2
        exit 1
    }
done
if grep -Eq 'for command_name in .*\b(cargo|rustup|file)\b' "${harness}"; then
    echo 'session-authority systemd-safety: FAIL: host Rust/file prerequisite returned' >&2
    exit 1
fi

reset_logs
run_fake --audit-lifecycle-argv "${audit_scope}" >"${stdout_log}" 2>"${stderr_log}"
for command_pattern in \
    ' run ' \
    ' info ' \
    ' --version' \
    ' build ' \
    ' exec ' \
    ' logs ' \
    ' container inspect ' \
    ' rm ' \
    ' image rm ' \
    ' container exists ' \
    ' image exists '; do
    grep -Fq "${command_pattern}" "${stdout_log}" || {
        echo "session-authority systemd-safety: FAIL: lifecycle audit missed ${command_pattern}" >&2
        exit 1
    }
done
while IFS= read -r audited_argv; do
    grep -Fq -- "--root ${audit_scope}/storage --runroot ${audit_scope}/runroot" \
        <<<"${audited_argv}" || {
        echo 'session-authority systemd-safety: FAIL: lifecycle command lacks scoped storage' >&2
        exit 1
    }
done <"${stdout_log}"
[ "$(grep -Ec 'command podman ' "${harness}")" -eq 1 ] || {
    echo 'session-authority systemd-safety: FAIL: Podman bypasses the scoped wrapper' >&2
    exit 1
}

reset_logs
if ! run_fake --check-scoped-probe "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: scoped fake Podman probe failed' >&2
    cat "${stdout_log}" "${stderr_log}" >&2
    exit 1
fi
grep -Fq 'session-authority real-systemd: PASS ' "${stdout_log}" || exit 1
grep -Fq 'run_scope_peak_bytes=65536' "${stdout_log}" || exit 1
grep -Fq 'root_min_free_bytes=9663676416' "${stdout_log}" || exit 1
grep -Fq 'run_scope_removed=true' "${stdout_log}" || exit 1
grep -Fq 'lock=held' "${call_log}" || exit 1
grep -Fq 'cmd=--version' "${call_log}" || exit 1
scoped_run_count="$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^scope=/) {sub(/^scope=/,"",$i); print $i}}' "${call_log}" | sort -u | wc -l)"
[ "${scoped_run_count}" -eq 1 ] || {
    echo 'session-authority systemd-safety: FAIL: Podman calls did not share one run scope' >&2
    exit 1
}
full_run_scope="$(sed -n 's/^scope=\([^ ]*\).*/\1/p' "${call_log}" | head -n1)"
[ -n "${full_run_scope}" ] && [ ! -e "${full_run_scope}" ] || {
    echo 'session-authority systemd-safety: FAIL: run-scoped storage survived cleanup' >&2
    exit 1
}
[ ! -e "${fake_home}/.local/share/containers" ] || {
    echo 'session-authority systemd-safety: FAIL: default rootless storage was created' >&2
    exit 1
}

reset_logs
FAKE_DISK_MODE=floor
if run_fake --check-scoped-probe "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: disk floor did not abort scoped probe' >&2
    exit 1
fi
FAKE_DISK_MODE=ample
grep -Fq 'receipt_reason=DISK_FLOOR_ABORT' "${stderr_log}" || {
    echo 'session-authority systemd-safety: FAIL: disk-floor receipt missing' >&2
    cat "${stderr_log}" >&2
    exit 1
}
grep -Fq 'root_min_free_bytes=3221225472' "${stderr_log}" || exit 1
grep -Fq 'run_scope_removed=true' "${stderr_log}" || exit 1
[ ! -e "${fake_home}/.local/share/containers" ] || exit 1

echo 'session-authority systemd-safety: PASS graphical_refusal=ok headless_guard=ok display_manager_refusal=ok runner_busy_refusal=ok runner_unit_job_refusal=ok held_build_lock_refusal=ok build_lock_lifetime=ok disk_preflight=ok disk_floor_abort=ok scoped_storage=ok default_storage_untouched=ok argv_audit=ok builder_stage=ok path_preconditions=1 fb0=regular getty_masks=5 podman=fake'
