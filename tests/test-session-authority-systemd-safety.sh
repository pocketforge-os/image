#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="${root}/tests/test-session-authority-systemd.sh"
recipe="${root}/tests/session-authority-systemd/Containerfile"
tmp="$(mktemp -d /tmp/tsp-f3fm-211-safety.XXXXXX)"
fake_bin="${tmp}/bin"
fake_root="${tmp}/host"
call_log="${tmp}/podman-calls"
stdout_log="${tmp}/stdout"
stderr_log="${tmp}/stderr"

cleanup() {
    find "${tmp}" -mindepth 1 -delete
    rmdir "${tmp}"
}
trap cleanup EXIT

mkdir -p "${fake_bin}" "${fake_root}/tmp/.X11-unix" "${fake_root}/run/user"
: >"${call_log}"

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
[ "${FAKE_DISPLAY_MANAGER:-0}" -eq 1 ] && exit 0
exit 3
EOF

cat >"${fake_bin}/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF

cat >"${fake_bin}/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${PODMAN_CALL_LOG:?}"
exit 97
EOF
chmod +x "${fake_bin}/hostname" "${fake_bin}/loginctl" \
    "${fake_bin}/systemctl" "${fake_bin}/pgrep" "${fake_bin}/podman"

if PATH="${fake_bin}:${PATH}" PODMAN_CALL_LOG="${call_log}" \
    FAKE_HOSTNAME=mm-build-vm FAKE_GRAPHICAL=1 \
    bash "${harness}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: graphical host passed guard' >&2
    exit 1
fi
grep -Fq 'INTERACTIVE_WORKSTATION: active session=7 seat=seat0 type=wayland' "${stderr_log}" || {
    echo 'session-authority systemd-safety: FAIL: graphical refusal reason missing' >&2
    cat "${stderr_log}" >&2
    exit 1
}
[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-safety: FAIL: graphical refusal reached Podman' >&2
    cat "${call_log}" >&2
    exit 1
}

PATH="${fake_bin}:${PATH}" PODMAN_CALL_LOG="${call_log}" \
    FAKE_HOSTNAME=mm-build-vm FAKE_GRAPHICAL=0 \
    bash "${harness}" --check-host-guard "${fake_root}" \
    >"${stdout_log}" 2>"${stderr_log}"
grep -Fqx 'session-authority host-guard: PASS host=mm-build-vm' "${stdout_log}" || {
    echo 'session-authority systemd-safety: FAIL: simulated headless host did not pass' >&2
    cat "${stdout_log}" "${stderr_log}" >&2
    exit 1
}

if PATH="${fake_bin}:${PATH}" PODMAN_CALL_LOG="${call_log}" \
    FAKE_HOSTNAME=matt-laptop FAKE_GRAPHICAL=0 \
    bash "${harness}" --check-host-guard "${fake_root}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: owner workstation passed allowlist' >&2
    exit 1
fi
grep -Fq 'UNAPPROVED_HOST: expected=mm-build-vm actual=matt-laptop' "${stderr_log}" || {
    echo 'session-authority systemd-safety: FAIL: owner workstation refusal reason missing' >&2
    cat "${stderr_log}" >&2
    exit 1
}

python3 - "${fake_root}/tmp/.X11-unix/X77" <<'PY'
import socket
import sys

with socket.socket(socket.AF_UNIX) as display:
    display.bind(sys.argv[1])
PY
if PATH="${fake_bin}:${PATH}" PODMAN_CALL_LOG="${call_log}" \
    FAKE_HOSTNAME=mm-build-vm FAKE_GRAPHICAL=0 \
    bash "${harness}" --check-host-guard "${fake_root}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: X socket passed guard' >&2
    exit 1
fi
grep -Fq 'INTERACTIVE_WORKSTATION: graphical socket=' "${stderr_log}" || {
    echo 'session-authority systemd-safety: FAIL: X socket refusal reason missing' >&2
    cat "${stderr_log}" >&2
    exit 1
}
find "${fake_root}/tmp/.X11-unix" -mindepth 1 -delete

PATH="${fake_bin}:${PATH}" PODMAN_CALL_LOG="${call_log}" \
    FAKE_HOSTNAME=mm-build-vm FAKE_GRAPHICAL=0 FAKE_DISPLAY_MANAGER=0 \
    bash "${harness}" --audit-systemd-spec >"${stdout_log}" 2>"${stderr_log}"
safe_spec="$(cat "${stdout_log}")"
for required in '--tty' '--systemd=always' '--network=none' '--cgroupns=private'; do
    grep -Fq -- "${required}" "${stdout_log}" || {
        echo "session-authority systemd-safety: FAIL: safe spec missing ${required}" >&2
        exit 1
    }
done
if grep -Eq -- '--privileged|--network([ =])host|--pid([ =])host|--cap-add|--device|(-v|--volume)(=| )[[:space:]]*/dev' \
    <<<"${safe_spec}"; then
    echo 'session-authority systemd-safety: FAIL: safe spec contains a forbidden option' >&2
    echo "${safe_spec}" >&2
    exit 1
fi

expect_rejected() {
    local label="$1"
    shift
    if bash "${harness}" --audit-argv "$@" >"${stdout_log}" 2>"${stderr_log}"; then
        echo "session-authority systemd-safety: FAIL: unsafe argv passed label=${label}" >&2
        exit 1
    fi
    grep -Fq 'UNSAFE_CONTAINER_ARGV:' "${stderr_log}" || {
        echo "session-authority systemd-safety: FAIL: unsafe argv reason missing label=${label}" >&2
        cat "${stderr_log}" >&2
        exit 1
    }
}

expect_rejected privilege run --privileged image
expect_rejected device-tree run -v /dev:/dev image
expect_rejected console-bind run --volume=/dev/console:/dev/console image
expect_rejected tty-device run --device /dev/tty2 image
expect_rejected host-pids run --pid=host image
expect_rejected tty-capability run --cap-add CAP_SYS_TTY_CONFIG image
expect_rejected admin-capability run --cap-add=CAP_SYS_ADMIN image
expect_rejected host-network run --network host image
expect_rejected device-mount run --mount type=bind,source=/dev/console,target=/console image

for unit in \
    getty@.service \
    getty.target \
    console-getty.service \
    serial-getty@.service \
    autovt@.service; do
    grep -Fq "/etc/systemd/system/${unit}" "${recipe}" || {
        echo "session-authority systemd-safety: FAIL: image recipe does not mask ${unit}" >&2
        exit 1
    }
done
grep -Fq 'ln -sf /dev/null' "${recipe}" || {
    echo 'session-authority systemd-safety: FAIL: getty units are not masked to /dev/null' >&2
    exit 1
}
grep -Fq 'session-authority-test.target /etc/systemd/system/session-authority-test.target' \
    "${recipe}" || {
    echo 'session-authority systemd-safety: FAIL: custom non-getty target is absent' >&2
    exit 1
}

[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-safety: FAIL: hermetic safety test invoked Podman' >&2
    cat "${call_log}" >&2
    exit 1
}

echo 'session-authority systemd-safety: PASS graphical_refusal=ok headless_guard=ok owner_host_refusal=ok argv_audit=ok getty_masks=5 podman_calls=0'
