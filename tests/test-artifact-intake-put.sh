#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/artifact-intake-put-test.XXXXXX")"
server_pid=
cleanup() {
    if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid"
        set +e
        wait "$server_pid"
        wait_rc=$?
        set -e
        if [ "$wait_rc" -ne 0 ] && [ "$wait_rc" -ne 143 ]; then
            printf 'FAIL stalled server cleanup rc=%s\n' "$wait_rc" >&2
            return "$wait_rc"
        fi
    fi
    find "$work" -mindepth 1 -delete
    rmdir "$work"
}
trap cleanup EXIT

mkdir -p "$work/helper/lib" "$work/fake-bin"
cp "$repo_root/scripts/pf-artifact-intake-put" "$work/helper/"
cp "$repo_root/scripts/lib/artifact-store-config.sh" "$work/helper/lib/"
payload="$work/payload.bin"
printf 'bounded artifact intake\n' >"$payload"
curl_log="$work/curl.args"

cat >"$work/fake-bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >>"$FAKE_CURL_LOG"
args=("$@")
if [ "${FAKE_CURL_MODE:?}" = success ]; then
    output=
    upload=
    url=
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[$i]}" in
            --output) output="${args[$((i + 1))]}" ;;
            --upload-file) upload="${args[$((i + 1))]}" ;;
            http://*) url="${args[$i]}" ;;
        esac
    done
    sha="${url##*/}"
    bytes="$(stat -c %s -- "$upload")"
    printf '{"bytes":%s,"schema":"pocketforge.artifact-intake-receipt/v1","sha256":"%s","trust_class":"trusted-builder"}\n' \
        "$bytes" "$sha" >"$output"
    printf '201'
    exit 0
fi

for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[$i]}" in
        http://192.168.151.1:8791/*)
            args[$i]="http://127.0.0.1:${STALL_PORT}${args[$i]#http://192.168.151.1:8791}"
            ;;
    esac
done
exec /usr/bin/curl "${args[@]}"
SH
chmod +x "$work/fake-bin/curl"

run_helper() {
    env \
        PATH="$work/fake-bin:$PATH" \
        FAKE_CURL_LOG="$curl_log" \
        PF_ARTIFACT_INTAKE_REQUEST_TIMEOUT_SECONDS="$1" \
        FAKE_CURL_MODE="$2" \
        STALL_PORT="${3:-0}" \
        "$work/helper/pf-artifact-intake-put" "$payload"
}

require_curl_arg() {
    if ! grep -qx -- "$1" "$curl_log"; then
        printf 'FAIL missing curl argument: %s\n' "$1" >&2
        exit 1
    fi
}

# Positive control: a valid receipt succeeds and both deadlines reach curl.
: >"$curl_log"
positive="$(run_helper 7 success)"
grep -q '^intake_status=PASS ' <<<"$positive"
require_curl_arg --max-time
require_curl_arg --connect-timeout
require_curl_arg 7

# Invalid timeout values fail closed before curl is attempted.
: >"$curl_log"
set +e
invalid="$(run_helper 0 success 2>&1)"
invalid_rc=$?
set -e
test "$invalid_rc" -ne 0
grep -q '^reason=artifact_intake_config_invalid$' <<<"$invalid"
test ! -s "$curl_log"

# Stalled-server negative control: a listener accepts the upload and never
# responds. The helper must let curl time out, exhaust its bounded retries,
# and report the transport failure before this test's outer guard fires.
port_file="$work/stall.port"
python3 - "$port_file" <<'PY' &
import socket
import sys
import time

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(8)
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(str(listener.getsockname()[1]))
held = []
while True:
    connection, _ = listener.accept()
    held.append(connection)
    time.sleep(0.05)
PY
server_pid=$!
for _ in $(seq 1 50); do
    test -s "$port_file" && break
    sleep 0.02
done
test -s "$port_file"
stall_port="$(cat "$port_file")"
: >"$curl_log"
set +e
stalled="$(timeout 10 env \
    PATH="$work/fake-bin:$PATH" \
    FAKE_CURL_LOG="$curl_log" \
    PF_ARTIFACT_INTAKE_REQUEST_TIMEOUT_SECONDS=1 \
    FAKE_CURL_MODE=stall \
    STALL_PORT="$stall_port" \
    "$work/helper/pf-artifact-intake-put" "$payload" 2>&1)"
stalled_rc=$?
set -e
test "$stalled_rc" -ne 0
test "$stalled_rc" -ne 124
grep -q '^reason=intake_transport_failed curl_status=28 attempts=3$' <<<"$stalled"
test "$(grep -cx -- '--max-time' "$curl_log")" -eq 3
test "$(grep -cx -- '--connect-timeout' "$curl_log")" -eq 3

printf 'artifact-intake-put timeout test: PASS positive=receipt invalid=refused stalled=bounded\n'
