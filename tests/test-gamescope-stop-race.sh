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
#
# Process-leak prevention: fixture scripts use bash's built-in `read -t`
# for blocking waits instead of `sleep N & wait $!`, which avoids forking
# any subprocess that could be orphaned when a parent exits. Each fixture
# opens fd 9 read-write on <(:) so that `read -t -u 9` never sees EOF and
# truly blocks instead of busy-spinning. The cleanup trap tracks every
# supervisor PID and SIGKILLs its process group on EXIT/INT/TERM, ensuring
# zero leaked processes on any exit path (including mid-run `timeout -k`).
set -euo pipefail

# Re-exec under setsid if we are not our own process group leader.
# This lets the EXIT trap clean up orphaned descendants without killing
# the parent CI runner's process group.
_self_pgid="$(ps -o pgid= $$ 2>/dev/null | tr -d ' ')"
if [ -n "$_self_pgid" ] && [ "$_self_pgid" != "$$" ]; then
    exec setsid -- "$0" "$@"
fi
unset _self_pgid

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-stop-race.XXXXXX")"

# File tracking all supervisor PIDs we spawn (one PID per line).
# The cleanup trap reads this to SIGKILL each supervisor's process group.
_supervisor_pids_file="${scratch}/supervisor_pids"
: > "$_supervisor_pids_file"

# Register a supervisor PID so the cleanup trap can kill it.
register_supervisor() {
    printf '%s\n' "$1" >> "$_supervisor_pids_file"
}

# Cleanup: SIGKILL every registered supervisor process group, then
# kill any remaining direct children of ours, then remove scratch.
# We are our own process group leader (setsid re-exec above), so we
# cannot `kill -- -$$` (that would kill us too). Instead we enumerate
# known supervisor PIDs and kill their process groups, then fall back
# to enumerating our direct children.
#
# This trap is installed on EXIT, INT, and TERM so it runs on:
#   - Normal exit (EXIT)
#   - Ctrl-C (INT)
#   - External SIGTERM (TERM), e.g. from `timeout`
cleanup_all() {
    local rc=$?
    # Kill every registered supervisor's process group.
    if [ -f "$_supervisor_pids_file" ]; then
        while IFS= read -r sup; do
            [ -n "$sup" ] || continue
            # Kill the whole process group first, then the PID itself.
            kill -KILL -- -"$sup" 2>/dev/null || true
            kill -KILL "$sup" 2>/dev/null || true
        done < "$_supervisor_pids_file"
    fi
    # Kill any remaining direct children of ours.
    local orphans
    orphans="$(ps -o pid= --ppid "$$" 2>/dev/null | tr -s '[:space:]' '\n' | grep -v "^$$\$" || true)"
    if [ -n "$orphans" ]; then
        # shellcheck disable=SC2086
        kill -KILL $orphans 2>/dev/null || true
    fi
    rm -rf "${scratch}" 2>/dev/null || true
    exit "${rc}"
}
trap cleanup_all EXIT
trap cleanup_all INT
trap cleanup_all TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Fixture scripts written to scratch
# ---------------------------------------------------------------------------

# Child: increments restart_file on SIGTERM, exits on SIGUSR1.
# Arguments: restart_file pidfile readyfile
#
# Uses `read -t -u 9` instead of `sleep 3600 & wait $!` to avoid forking
# a subprocess. fd 9 is opened read-write on <(:) so read never sees EOF
# and truly blocks instead of busy-spinning. Crucially, no child process
# is created, so nothing can be orphaned when this shell exits.
write_child_script() {
    cat <<'CHILD_EOF'
#!/usr/bin/env bash
set -uo pipefail
restart_file=$1; pidfile=$2; readyfile=$3
exec 9<> <(:)
count=0
[ -f "$restart_file" ] && count=$(cat "$restart_file")
trap 'count=$((count+1)); printf "%s\n" "$count" > "$restart_file"' TERM
trap 'exit 0' USR1
printf '%s\n' "$$" > "$pidfile"
: > "$readyfile"
while true; do read -t 3600 -u 9 _ 2>/dev/null || true; done
CHILD_EOF
}

# Stubborn child: ignores SIGTERM and SIGUSR1 (for timeout test).
# Arguments: restart_file pidfile readyfile
write_stubborn_child_script() {
    cat <<'STUBBORN_EOF'
#!/usr/bin/env bash
set -uo pipefail
restart_file=$1; pidfile=$2; readyfile=$3
exec 9<> <(:)
trap '' TERM USR1
printf '%s\n' "$$" > "$pidfile"
: > "$readyfile"
while true; do read -t 3600 -u 9 _ 2>/dev/null || true; done
STUBBORN_EOF
}

# Supervisor: spawns child, on SIGTERM sends SIGUSR1 and polls with timeout.
# Arguments: child_script restart_file pidfile readyfile
#   supervisor_pidfile timeout_sec [stubborn]
#
# All blocking waits use `read -t -u 9` (bash builtin) instead of `sleep`
# to avoid forking subprocesses that could leak on exit. fd 9 is opened
# read-write on <(:) so read never sees EOF and truly blocks.
write_supervisor_script() {
    cat <<'SUPERVISOR_EOF'
#!/usr/bin/env bash
set -uo pipefail
child_script=$1; restart_file=$2; child_pidfile=$3; child_readyfile=$4
supervisor_pidfile=$5; timeout_sec=${6:-3}; stubborn=${7:-no}
exec 9<> <(:)

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
            read -t 0.05 -u 9 _ 2>/dev/null || true
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
    read -t 0.05 -u 9 _ 2>/dev/null || true
done

while true; do read -t 3600 -u 9 _ 2>/dev/null || true; done
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
    register_supervisor "$supervisor_pid"
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
    register_supervisor "$supervisor_pid"
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
    register_supervisor "$supervisor_pid"
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
