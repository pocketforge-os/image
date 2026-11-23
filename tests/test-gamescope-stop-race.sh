#!/usr/bin/env bash
# Hermetic process-level stop-race regression for pocketforge-gamescope.service
# KillMode=mixed (image#391, reviewed head 22697d4a).
#
# Threat model:
#   Gamescope owns Xwayland. During unit stop, a cgroup-wide initial SIGTERM
#   (KillMode=control-group) delivers SIGTERM to both Gamescope and Xwayland
#   simultaneously. Xwayland dies before Gamescope reaches wlserver cleanup,
#   activating wlroots' restart path. KillMode=mixed signals only the main
#   process first; Gamescope then destroys Xwayland as part of its own
#   cleanup, avoiding the restart race.
#
# This harness creates a supervisor and managed child process. The child
# increments a restart counter on SIGTERM (modelling wlroots' restart-on-
# unexpected-child-death) and exits on SIGUSR1 (modelling Gamescope's
# orderly teardown). The supervisor, on receiving SIGTERM, sends SIGUSR1
# to its child and polls for exit.
#
# Three cases are exercised:
#   1. control-group-equivalent: SIGTERM to the entire process group. Both
#      supervisor and child receive SIGTERM. The child increments its restart
#      counter before the supervisor's cleanup reaches it. RED control.
#   2. mixed-equivalent: SIGTERM only to the supervisor. Supervisor sends
#      SIGUSR1 to child; child exits without touching the restart counter.
#      GREEN.
#   3. timeout: child ignores SIGTERM and SIGUSR1. Supervisor's bounded poll
#      expires; supervisor sends SIGKILL. Child is reaped. Proves the final
#      cgroup-wide SIGKILL boundary is preserved.
#
# No systemd, no cgroup writes, no root required. Uses setsid for process
# group isolation and standard POSIX signals.
set -euo pipefail

# Re-exec under setsid if we are not our own process group leader.
# This lets the EXIT trap `kill -- -$$` clean up orphaned descendants
# (e.g. the supervisor/child sleep loops) without killing the parent
# CI runner's process group.
_self_pgid="$(ps -o pgid= $$ 2>/dev/null | tr -d ' ')"
if [ -n "$_self_pgid" ] && [ "$_self_pgid" != "$$" ]; then
    exec setsid -- "$0" "$@"
fi
unset _self_pgid

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-stop-race.XXXXXX")"

# Cleanup: kill any surviving descendants, remove scratch.
# We are our own process group leader (setsid re-exec above), so
# `kill -- -$$` would kill us too. Instead, enumerate and kill any
# remaining descendants (direct children) to ensure no orphaned
# sleep/child processes leak after the test exits.
cleanup_all() {
    local rc=$?
    # Kill any known supervisor process group first.
    if [ -f "${scratch}/supervisor.pid" ]; then
        local sup
        sup="$(cat "${scratch}/supervisor.pid" 2>/dev/null || true)"
        if [ -n "$sup" ] && kill -0 "$sup" 2>/dev/null; then
            kill -KILL -- -"$sup" 2>/dev/null || kill -KILL "$sup" 2>/dev/null || true
        fi
    fi
    # Kill any remaining direct children of ours (catches any orphaned
    # sleep/child processes from fixtures that were not in a supervisor
    # process group). We enumerate PIDs to avoid killing ourselves.
    local orphans
    orphans="$(ps -o pid= --ppid "$$" 2>/dev/null | tr -s ' ' | tr -d ' ' || true)"
    if [ -n "$orphans" ]; then
        # shellcheck disable=SC2086
        kill -KILL $orphans 2>/dev/null || true
    fi
    rm -rf "${scratch}" 2>/dev/null || true
    exit "${rc}"
}
trap cleanup_all EXIT
trap cleanup_all ERR

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Fixture scripts written to scratch
# ---------------------------------------------------------------------------

# Child: increments restart_file on SIGTERM, exits on SIGUSR1.
# Arguments: restart_file pidfile readyfile
write_child_script() {
    cat <<'CHILD_EOF'
#!/usr/bin/env bash
set -uo pipefail
restart_file=$1; pidfile=$2; readyfile=$3
count=0
[ -f "$restart_file" ] && count=$(cat "$restart_file")
trap 'count=$((count+1)); printf "%s\n" "$count" > "$restart_file"' TERM
trap 'exit 0' USR1
printf '%s\n' "$$" > "$pidfile"
: > "$readyfile"
while true; do sleep 3600 & wait $! 2>/dev/null || true; done
CHILD_EOF
}

# Stubborn child: ignores SIGTERM and SIGUSR1 (for timeout test).
# Arguments: restart_file pidfile readyfile
write_stubborn_child_script() {
    cat <<'STUBBORN_EOF'
#!/usr/bin/env bash
set -uo pipefail
restart_file=$1; pidfile=$2; readyfile=$3
trap '' TERM USR1
printf '%s\n' "$$" > "$pidfile"
: > "$readyfile"
while true; do sleep 3600 & wait $! 2>/dev/null || true; done
STUBBORN_EOF
}

# Supervisor: spawns child, on SIGTERM sends SIGUSR1 and polls with timeout.
# Arguments: child_script restart_file pidfile readyfile
#   supervisor_pidfile timeout_sec [stubborn]
write_supervisor_script() {
    cat <<'SUPERVISOR_EOF'
#!/usr/bin/env bash
set -uo pipefail
child_script=$1; restart_file=$2; child_pidfile=$3; child_readyfile=$4
supervisor_pidfile=$5; timeout_sec=${6:-3}; stubborn=${7:-no}

child_pid=0
done_file="${supervisor_pidfile}.done"
timeout_marker="${supervisor_pidfile}.timeout"

handle_term() {
    if [ "$child_pid" -gt 0 ] 2>/dev/null; then
        kill -USR1 "$child_pid" 2>/dev/null || true
        deadline=$((SECONDS + timeout_sec))
        while kill -0 "$child_pid" 2>/dev/null; do
            if [ "$SECONDS" -ge "$deadline" ]; then
                : > "$timeout_marker"
                kill -KILL "$child_pid" 2>/dev/null || true
                break
            fi
            sleep 0.05
        done
        wait "$child_pid" 2>/dev/null || true
    fi
    : > "$done_file"
    exit 0
}

trap handle_term TERM
printf '%s\n' "$$" > "$supervisor_pidfile"

bash "$child_script" "$restart_file" "$child_pidfile" "$child_readyfile" &
child_pid=$!

deadline=$((SECONDS + 5))
while [ ! -f "$child_readyfile" ]; do
    if [ "$SECONDS" -ge "$deadline" ]; then exit 1; fi
    sleep 0.02
done

while true; do sleep 3600 & wait $! 2>/dev/null || true; done
SUPERVISOR_EOF
}

# ---------------------------------------------------------------------------
# Write fixtures
# ---------------------------------------------------------------------------

child_script="${scratch}/child.sh"
stubborn_script="${scratch}/stubborn_child.sh"
supervisor_script="${scratch}/supervisor.sh"
write_child_script > "${child_script}"; chmod 0755 "${child_script}"
write_stubborn_child_script > "${stubborn_script}"; chmod 0755 "${stubborn_script}"
write_supervisor_script > "${supervisor_script}"; chmod 0755 "${supervisor_script}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

wait_for_pidfile() {
    local pidfile="$1" timeout="${2:-5}" start=$SECONDS
    while [ ! -s "$pidfile" ]; do
        if [ $((SECONDS - start)) -ge "$timeout" ]; then return 1; fi
        sleep 0.02
    done
    cat "$pidfile"
}

wait_for_exit() {
    local pid="$1" timeout="${2:-5}" start=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        if [ $((SECONDS - start)) -ge "$timeout" ]; then return 1; fi
        sleep 0.02
    done
    return 0
}

read_counter() {
    local file="$1"
    [ -f "$file" ] && cat "$file" || printf '0'
}

# ---------------------------------------------------------------------------
# Case 1: control-group-equivalent (RED)
# ---------------------------------------------------------------------------

run_control_group_case() {
    local dir="${scratch}/cg"; mkdir -p "$dir"
    local restart_file="${dir}/restarts"
    local child_pidfile="${dir}/child.pid"
    local child_readyfile="${dir}/child.ready"
    local supervisor_pidfile="${dir}/supervisor.pid"
    printf '0\n' > "$restart_file"

    setsid bash "${supervisor_script}" \
        "${child_script}" "$restart_file" "$child_pidfile" \
        "$child_readyfile" "$supervisor_pidfile" 3 no &
    local bg_pid=$!

    local supervisor_pid child_pid
    supervisor_pid="$(wait_for_pidfile "$supervisor_pidfile" 5)" \
        || fail "control-group: supervisor did not start"
    child_pid="$(wait_for_pidfile "$child_pidfile" 5)" \
        || fail "control-group: child did not start"

    kill -0 "$supervisor_pid" 2>/dev/null \
        || fail "control-group: supervisor not running"
    kill -0 "$child_pid" 2>/dev/null \
        || fail "control-group: child not running"

    # SIGTERM to the entire process group.
    kill -TERM -- -"$supervisor_pid" 2>/dev/null || true

    wait_for_exit "$supervisor_pid" 5 \
        || fail "control-group: supervisor did not exit"
    wait "$bg_pid" 2>/dev/null || true

    local restarts
    restarts="$(read_counter "$restart_file")"
    if [ "$restarts" -lt 1 ]; then
        fail "control-group: expected restart>=1 under cgroup-wide SIGTERM, got ${restarts}"
    fi

    printf 'control-group: PASS (restarts=%d)\n' "$restarts"
}

# ---------------------------------------------------------------------------
# Case 2: mixed-equivalent (GREEN)
# ---------------------------------------------------------------------------

run_mixed_case() {
    local dir="${scratch}/mixed"; mkdir -p "$dir"
    local restart_file="${dir}/restarts"
    local child_pidfile="${dir}/child.pid"
    local child_readyfile="${dir}/child.ready"
    local supervisor_pidfile="${dir}/supervisor.pid"
    printf '0\n' > "$restart_file"

    setsid bash "${supervisor_script}" \
        "${child_script}" "$restart_file" "$child_pidfile" \
        "$child_readyfile" "$supervisor_pidfile" 3 no &
    local bg_pid=$!

    local supervisor_pid child_pid
    supervisor_pid="$(wait_for_pidfile "$supervisor_pidfile" 5)" \
        || fail "mixed: supervisor did not start"
    child_pid="$(wait_for_pidfile "$child_pidfile" 5)" \
        || fail "mixed: child did not start"

    # SIGTERM only to the supervisor PID (not the group).
    kill -TERM "$supervisor_pid" 2>/dev/null || true

    wait_for_exit "$supervisor_pid" 5 \
        || fail "mixed: supervisor did not exit"
    wait "$bg_pid" 2>/dev/null || true

    # Child should also be gone (cleaned up by supervisor).
    wait_for_exit "$child_pid" 3 \
        || fail "mixed: child did not exit after supervisor cleanup"

    local restarts
    restarts="$(read_counter "$restart_file")"
    if [ "$restarts" -ne 0 ]; then
        fail "mixed: child restarted under supervisor-only SIGTERM (restarts=${restarts})"
    fi

    printf 'mixed: PASS (restarts=%d, clean exit)\n' "$restarts"
}

# ---------------------------------------------------------------------------
# Case 3: timeout (stubborn child receives final SIGKILL)
# ---------------------------------------------------------------------------

run_timeout_case() {
    local dir="${scratch}/timeout"; mkdir -p "$dir"
    local restart_file="${dir}/restarts"
    local child_pidfile="${dir}/child.pid"
    local child_readyfile="${dir}/child.ready"
    local supervisor_pidfile="${dir}/supervisor.pid"
    printf '0\n' > "$restart_file"

    setsid bash "${supervisor_script}" \
        "${stubborn_script}" "$restart_file" "$child_pidfile" \
        "$child_readyfile" "$supervisor_pidfile" 1 yes &
    local bg_pid=$!

    local supervisor_pid child_pid
    supervisor_pid="$(wait_for_pidfile "$supervisor_pidfile" 5)" \
        || fail "timeout: supervisor did not start"
    child_pid="$(wait_for_pidfile "$child_pidfile" 5)" \
        || fail "timeout: child did not start"

    # SIGTERM only to supervisor. Child ignores it; supervisor times out.
    kill -TERM "$supervisor_pid" 2>/dev/null || true

    # Supervisor exits after its 1s timeout + SIGKILL. Allow up to 8s.
    wait_for_exit "$supervisor_pid" 8 \
        || fail "timeout: supervisor did not exit within bounded timeout"
    wait "$bg_pid" 2>/dev/null || true

    # Stubborn child must be dead (SIGKILL'd by supervisor).
    if kill -0 "$child_pid" 2>/dev/null; then
        fail "timeout: stubborn child still alive after supervisor exit"
    fi

    # Supervisor must have recorded the timeout.
    if [ ! -f "${supervisor_pidfile}.timeout" ]; then
        fail "timeout: supervisor did not record timeout marker"
    fi

    local restarts
    restarts="$(read_counter "$restart_file")"
    if [ "$restarts" -ne 0 ]; then
        fail "timeout: stubborn child should not restart (restarts=${restarts})"
    fi

    printf 'timeout: PASS (timeout marker set, child SIGKILL reaped)\n'
}

# ---------------------------------------------------------------------------
# Case 4: production contract verification
# ---------------------------------------------------------------------------

run_production_contract() {
    local service="${root}/rootfs-overlay/etc/systemd/system/pocketforge-gamescope.service"
    test -f "$service" || fail "production contract: service unit missing"
    grep -Fx 'KillMode=mixed' "$service" >/dev/null \
        || fail "production contract: KillMode is not mixed"
    grep -E '^TimeoutStopSec=' "$service" >/dev/null \
        || fail "production contract: TimeoutStopSec is not set"
    grep -Fx 'Restart=no' "$service" >/dev/null \
        || fail "production contract: Restart is not no"
    printf 'production-contract: PASS (KillMode=mixed, bounded timeout, Restart=no)\n'
}

# ---------------------------------------------------------------------------
# Run all cases
# ---------------------------------------------------------------------------

run_control_group_case
run_mixed_case
run_timeout_case
run_production_contract

echo 'PASS: gamescope stop-race process-level regression'
