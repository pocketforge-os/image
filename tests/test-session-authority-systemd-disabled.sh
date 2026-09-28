#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d /tmp/tsp-f3fm-210.XXXXXX)"
fake_bin="${tmp}/bin"
call_log="${tmp}/docker-calls"
stdout_log="${tmp}/stdout"
stderr_log="${tmp}/stderr"
expected_log="${tmp}/expected"

cleanup() {
    find "${tmp}" -mindepth 1 -delete
    rmdir "${tmp}"
}
trap cleanup EXIT

mkdir "${fake_bin}"
: >"${call_log}"
cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${DOCKER_CALL_LOG}"
EOF
chmod +x "${fake_bin}/docker"

if PATH="${fake_bin}:${PATH}" DOCKER_CALL_LOG="${call_log}" \
    bash "${root}/tests/test-session-authority-systemd.sh" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-disabled: FAIL: disabled harness exited zero' >&2
    exit 1
fi

expected='session-authority real-systemd: DISABLED reason=HOST_VT_INCIDENT bead=tsp-f3fm.210'
printf '%s\n' "${expected}" >"${expected_log}"
cmp -s "${expected_log}" "${stderr_log}" || {
    echo 'session-authority systemd-disabled: FAIL: unexpected disabled message' >&2
    cat "${stderr_log}" >&2
    exit 1
}
[ ! -s "${stdout_log}" ] || {
    echo 'session-authority systemd-disabled: FAIL: disabled harness wrote stdout' >&2
    cat "${stdout_log}" >&2
    exit 1
}
[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-disabled: FAIL: disabled harness invoked docker' >&2
    cat "${call_log}" >&2
    exit 1
}

PATH="${fake_bin}:${PATH}" DOCKER_CALL_LOG="${call_log}" docker positive-control
[ "$(cat "${call_log}")" = 'positive-control' ] || {
    echo 'session-authority systemd-disabled: FAIL: fake docker did not record positive control' >&2
    exit 1
}

echo 'session-authority systemd-disabled: PASS'
