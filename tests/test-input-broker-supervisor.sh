#!/bin/sh
# Hermetic contract for the session broker's bounded two-attempt supervisor.
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
supervisor="${root}/rootfs-overlay/usr/lib/pocketforge/pf-input-broker-supervisor"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-broker-supervisor.XXXXXX")"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

if [ ! -x "${supervisor}" ]; then
    echo "input-broker-supervisor: FAIL missing executable ${supervisor}" >&2
    exit 1
fi

cat >"${scratch}/broker" <<'EOF'
#!/bin/sh
set -eu
count=0
if [ -f "${PF_TEST_COUNT}" ]; then
    count="$(cat "${PF_TEST_COUNT}")"
fi
count=$((count + 1))
printf '%s\n' "${count}" >"${PF_TEST_COUNT}"
case "${PF_TEST_MODE}" in
    clean) exit 0 ;;
    retry) [ "${count}" -eq 2 ] && exit 0; exit 23 ;;
    fail) exit 23 ;;
    stop)
        trap 'sleep 1; printf "%s\n" released >"${PF_TEST_RELEASE}"; exit 0' TERM INT
        printf '%s\n' "$$" >"${PF_TEST_CHILD_PID}"
        while :; do sleep 1; done
        ;;
    *) exit 99 ;;
esac
EOF
chmod 0755 "${scratch}/broker"

run_case() {
    mode="$1"
    expected_rc="$2"
    expected_count="$3"
    count_file="${scratch}/${mode}.count"
    rc=0
    PF_TEST_MODE="${mode}" PF_TEST_COUNT="${count_file}" \
        "${supervisor}" "${scratch}/broker" || rc=$?
    [ "${rc}" -eq "${expected_rc}" ]
    [ "$(cat "${count_file}")" -eq "${expected_count}" ]
}

run_case clean 0 1
run_case retry 0 2
run_case fail 23 2

stop_count="${scratch}/stop.count"
stop_release="${scratch}/stop.release"
stop_child_pid="${scratch}/stop.pid"
PF_TEST_MODE=stop PF_TEST_COUNT="${stop_count}" PF_TEST_RELEASE="${stop_release}" \
    PF_TEST_CHILD_PID="${stop_child_pid}" "${supervisor}" "${scratch}/broker" &
supervisor_pid=$!
attempt=0
while [ ! -s "${stop_child_pid}" ] && [ "${attempt}" -lt 50 ]; do
    sleep 0.02
    attempt=$((attempt + 1))
done
[ -s "${stop_child_pid}" ]
kill -TERM "${supervisor_pid}"
wait "${supervisor_pid}"
released_before_supervisor_exit=no
if [ -s "${stop_release}" ]; then
    released_before_supervisor_exit=yes
fi
# Let the deliberately delayed child finish even when exercising the broken supervisor,
# so the negative control never leaves an orphan behind.
attempt=0
while [ ! -s "${stop_release}" ] && [ "${attempt}" -lt 150 ]; do
    sleep 0.02
    attempt=$((attempt + 1))
done
[ -s "${stop_release}" ]
if [ "${released_before_supervisor_exit}" != yes ]; then
    echo 'input-broker-supervisor: FAIL supervisor exited before broker release completed' >&2
    exit 1
fi

echo 'input-broker-supervisor: PASS clean=1 retry=2 terminal_failures=2 stop_waited_for_child=yes'
