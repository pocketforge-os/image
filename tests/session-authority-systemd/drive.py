#!/usr/bin/env python3
"""Drive the production session-authority binary against real systemd."""

from __future__ import annotations

import fcntl
import grp
import json
import os
import socket
import stat
import struct
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


APP_ID = "org.pocketforge.fixture"
APP_UNIT = f"pf-app@{APP_ID}.service"
AUTHORITY_UNIT = "pf-session-authorityd.service"
OWNER_UNIT = "pf-shell-selected.service"
TARGET_UNIT = "pocketforge-foreground.target"
BROKER_UNIT = "pf-input-broker.service"
SOCKET = Path("/run/pocketforge/session-authority.sock")
BROKER_SOCKET = Path("/run/pocketforge/input-broker.sock")
MODE = Path("/run/pocketforge/fixture-exit-code")
APP_STATE = Path(f"/var/lib/pocketforge/apps/{APP_ID}/state")
INVOCATIONS = APP_STATE / "invocations"
PROBE = APP_STATE / "probe.json"
CLIENT_ID = "image-real-systemd"
GRAB = Path("/run/pf-grab")
GRAB_LOCK = GRAB / "pf-gamepad.lock"
BROKER_CONTROL = GRAB / "broker-control.sock"
BROKER_MODE = GRAB / "broker-mode"
BROKER_ATTEMPTS = GRAB / "broker-attempts"
# Negative control only (run last): restores the runtime unit's Restart=on-failure.
CONTROL_DROPIN = Path("/run/systemd/system/pf-input-broker.service.d/99-control-restart-on-failure.conf")
UINPUT = Path("/dev/uinput")
DESCRIPTOR = "/usr/share/pocketforge/devices/a133/capabilities.toml"
# tsp-f3fm.219 (runtime#103): the authority ticks itself once per second and gives the
# restored shell this long to acknowledge presentation before RecoveryRequired.
PRESENTATION_DEADLINE_S = 10.0
DEADLINE_SLACK_S = 4.0
PRESENTATION_TIMEOUT_PREFIX = "presentation_not_acknowledged:"


class TestFailure(RuntimeError):
    pass


@dataclass(frozen=True)
class SessionEventScope:
    session_id: str
    after_sequence: int


def require(condition: bool, message: str) -> None:
    if not condition:
        raise TestFailure(message)


def command(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def wait_for(predicate: Callable[[], bool], description: str, timeout: float = 12.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise TestFailure(f"timed out waiting for {description}")


def receive_exact(stream: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = stream.recv(remaining)
        if not chunk:
            raise TestFailure("authority closed an incomplete RPC response")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def rpc(request: dict[str, Any]) -> dict[str, Any]:
    body = json.dumps(request, separators=(",", ":")).encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(5)
        stream.connect(str(SOCKET))
        stream.sendall(struct.pack(">I", len(body)) + body)
        response_length = struct.unpack(">I", receive_exact(stream, 4))[0]
        response = json.loads(receive_exact(stream, response_length))
    require(response.get("result") != "error", f"RPC failed: {response}")
    return response


def property_value(unit: str, property_name: str) -> str:
    return command(
        "systemctl", "show", "--property", property_name, "--value", unit
    ).stdout.strip()


def unit_is_active(unit: str) -> bool:
    return command("systemctl", "is-active", "--quiet", unit, check=False).returncode == 0


def owner_pid() -> int:
    return int(property_value(OWNER_UNIT, "MainPID"))


def invocation_count() -> int:
    if not INVOCATIONS.exists():
        return 0
    return len(INVOCATIONS.read_text().splitlines())


def events() -> list[tuple[int, dict[str, Any]]]:
    response = rpc({"method": "events", "client_id": CLIENT_ID})
    require(response.get("result") == "events", f"unexpected events response: {response}")
    return [(int(sequence), event) for sequence, event in response["events"]]


def last_sequence(all_events: list[tuple[int, dict[str, Any]]]) -> int:
    return max((sequence for sequence, _ in all_events), default=0)


def session_events(
    all_events: list[tuple[int, dict[str, Any]]],
    scope: SessionEventScope,
    event_name: str,
) -> list[tuple[int, dict[str, Any]]]:
    """Return events belonging to one launch's durable sequence window.

    Starting and running wire events do not carry a session id, so the sequence
    floor captured immediately before launch scopes them. Terminal events also
    carry a session id and must match it explicitly.
    """
    return [
        (sequence, event)
        for sequence, event in all_events
        if sequence > scope.after_sequence
        and event.get("event") == event_name
        and event.get("session_id", scope.session_id) == scope.session_id
    ]


def history_entry(session_id: str) -> dict[str, Any]:
    response = rpc({"method": "history"})
    require(response.get("result") == "history", f"unexpected history response: {response}")
    matches = [entry for entry in response["entries"] if entry["session_id"] == session_id]
    require(len(matches) == 1, f"history does not contain exactly one {session_id}: {matches}")
    return matches[0]


def authority_state() -> dict[str, Any]:
    return json.loads(
        Path("/var/lib/pocketforge/session-authority/authority.json").read_text()
    )


def require_session_phase(
    scope: SessionEventScope, phase_name: str, rung: str | None = None
) -> dict[str, Any]:
    phase = authority_state()["phase"]
    payload = phase.get(phase_name, {})
    require(
        payload.get("session_id") == scope.session_id,
        f"authority phase is not {phase_name} for {scope.session_id}: {phase}",
    )
    if rung is not None:
        require(
            payload.get("rung") == rung,
            f"authority phase is not {rung} for {scope.session_id}: {phase}",
        )
    return payload


def authority_is_responding() -> bool:
    try:
        return rpc({"method": "history"}).get("result") == "history"
    except (OSError, TestFailure, ValueError):
        return False


def launch() -> SessionEventScope:
    before_launch = events()
    response = rpc({"method": "launch", "item_id": APP_ID})
    require(response.get("result") == "accepted", f"launch was not accepted: {response}")
    return SessionEventScope(
        session_id=str(response["session_id"]),
        after_sequence=last_sequence(before_launch),
    )


def assert_no_terminal_before_presentation(scope: SessionEventScope) -> None:
    require_session_phase(scope, "Restoring", "PresentationAcknowledged")
    current = events()
    require(
        not session_events(current, scope, "returned")
        and not session_events(current, scope, "crash"),
        f"terminal receipt published before presentation acknowledgement for {scope.session_id}",
    )
    require(
        history_entry(scope.session_id)["receipt"] is None,
        f"history became terminal before presentation acknowledgement for {scope.session_id}",
    )


def wait_for_app_exit(scope: SessionEventScope, expected_state: str) -> None:
    wait_for(
        lambda: property_value(APP_UNIT, "ActiveState") == expected_state,
        f"{APP_UNIT} for {scope.session_id} to become {expected_state}",
    )
    wait_for(
        lambda: not unit_is_active(TARGET_UNIT),
        f"{TARGET_UNIT} to release for {scope.session_id}",
    )
    wait_for(
        lambda: unit_is_active(OWNER_UNIT),
        f"{OWNER_UNIT} to become active again for {scope.session_id}",
    )
    wait_for_owner_grab(scope.session_id)
    events()
    require_session_phase(scope, "Restoring", "PresentationAcknowledged")


def assert_start_and_exit(
    exit_code: int, expected_state: str
) -> tuple[SessionEventScope, int]:
    MODE.write_text(f"{exit_code}\n")
    before_invocations = invocation_count()
    previous_owner_pid = owner_pid()
    require(previous_owner_pid > 0, "selected owner did not start before launch")

    scope = launch()
    wait_for(
        lambda: invocation_count() == before_invocations + 1,
        f"fixture invocation for {scope.session_id}",
    )
    require(unit_is_active(APP_UNIT), f"{APP_UNIT} never reached active")

    running_events = events()
    require(
        len(session_events(running_events, scope, "starting")) == 1,
        f"authority did not publish one Starting for {scope.session_id}",
    )
    require(
        len(session_events(running_events, scope, "running")) == 1,
        f"authority did not publish one Running for {scope.session_id}",
    )
    require_session_phase(scope, "Running")
    require(
        not unit_is_active(OWNER_UNIT),
        f"selected owner stayed active while {scope.session_id} owned the slot",
    )
    require(unit_is_active(BROKER_UNIT), f"{BROKER_UNIT} not active during {scope.session_id}")

    wait_for_app_exit(scope, expected_state)
    wait_for(lambda: not unit_is_active(BROKER_UNIT), f"{BROKER_UNIT} to stop after {scope.session_id}")
    restored_owner_pid = owner_pid()
    require(
        restored_owner_pid > 0,
        f"selected owner has no process after restoring {scope.session_id}",
    )
    require(
        restored_owner_pid != previous_owner_pid,
        f"selected owner was not newly activated after {scope.session_id}",
    )
    return scope, restored_owner_pid


def assert_crash_scope_empty_before_launch() -> SessionEventScope:
    durable = events()
    # The ended sessions' Running is still durable in the authority's pending log (this
    # client never acknowledges), but runtime#103 R1 never delivers Starting/Running for a
    # session that has ended: a restarted shell must not replay a dead app as Running.
    require(
        any(entry.get("event") == "ObservedRunning" for entry in authority_state()["pending"]),
        "negative control requires a durable Running event from an ended session",
    )
    require(
        not any(event.get("event") in ("starting", "running") for _, event in durable),
        f"R1: Starting/Running delivered for an ended session while Idle: {durable}",
    )
    expected_crash_scope = SessionEventScope(
        session_id=f"session-{authority_state()['next_session']}",
        after_sequence=last_sequence(durable),
    )
    for event_name in ("starting", "running", "returned", "crash"):
        require(
            not session_events(durable, expected_crash_scope, event_name),
            f"{expected_crash_scope.session_id} leaked stale {event_name} before launch",
        )
    return expected_crash_scope


def assert_refusals_never_reach_systemd() -> None:
    before = command(
        "systemctl", "list-units", "--all", "--full", "--plain", "pf-app@*.service", "--no-legend"
    ).stdout.strip()
    require(not before, f"app instances existed before refusal checks: {before}")

    invalid = rpc({"method": "launch", "item_id": "../outside"})
    unknown = rpc({"method": "launch", "item_id": "org.pocketforge.unknown"})
    require(invalid.get("result") == "item_unavailable", f"invalid id response: {invalid}")
    require(unknown.get("result") == "item_unavailable", f"unknown id response: {unknown}")

    after = command(
        "systemctl", "list-units", "--all", "--full", "--plain", "pf-app@*.service", "--no-legend"
    ).stdout.strip()
    require(not after, f"refused ids caused an app-unit start: {after}")

    authority_journal = command(
        "journalctl", "--unit", AUTHORITY_UNIT, "--no-pager", "--output", "cat"
    ).stdout
    require("reason=invalid_id" in authority_journal, "invalid-id refusal missing from journal")
    require("reason=app_not_found" in authority_journal, "unknown-id refusal missing from journal")


def assert_clean_exit_with_restart() -> str:
    scope, _ = assert_start_and_exit(0, "inactive")
    require(property_value(APP_UNIT, "Result") == "success", "clean fixture did not exit successfully")

    assert_no_terminal_before_presentation(scope)

    command("systemctl", "restart", AUTHORITY_UNIT)
    wait_for(
        lambda: unit_is_active(AUTHORITY_UNIT) and authority_is_responding(),
        "authority restart",
    )
    require_session_phase(scope, "Restoring", "PresentationAcknowledged")
    assert_no_terminal_before_presentation(scope)

    require_session_phase(scope, "Restoring", "PresentationAcknowledged")
    observed = rpc(
        {"method": "observe", "observation": {"kind": "presentation_acknowledged"}}
    )
    require(observed.get("result") == "ok", f"presentation acknowledgement failed: {observed}")

    final_events = events()
    returned = session_events(final_events, scope, "returned")
    require(len(returned) == 1, f"Returned publication count for {scope.session_id}: {returned}")
    require(not session_events(final_events, scope, "crash"), "clean exit reported Crash")
    require(
        history_entry(scope.session_id)["receipt"] == "Returned",
        f"clean receipt was not durable for {scope.session_id}",
    )

    replayed_events = events()
    require(
        session_events(replayed_events, scope, "returned") == returned,
        f"restart or replay changed the Returned publication for {scope.session_id}",
    )
    require(
        unit_is_active(OWNER_UNIT),
        f"selected owner inactive after clean receipt for {scope.session_id}",
    )
    return scope.session_id


def assert_crash_exit() -> str:
    expected_scope = assert_crash_scope_empty_before_launch()
    scope, _ = assert_start_and_exit(23, "failed")
    require(
        scope == expected_scope,
        f"crash launch scope changed from {expected_scope} to {scope}",
    )
    require(property_value(APP_UNIT, "Result") == "exit-code", "crash fixture result was not exit-code")
    assert_no_terminal_before_presentation(scope)

    require_session_phase(scope, "Restoring", "PresentationAcknowledged")
    observed = rpc(
        {"method": "observe", "observation": {"kind": "presentation_acknowledged"}}
    )
    require(observed.get("result") == "ok", f"presentation acknowledgement failed: {observed}")

    final_events = events()
    crashes = session_events(final_events, scope, "crash")
    require(len(crashes) == 1, f"Crash publication count for {scope.session_id}: {crashes}")
    require(
        "systemd result: exit-code" in crashes[0][1].get("summary", ""),
        f"Crash summary did not preserve systemd result: {crashes}",
    )
    require(
        not session_events(final_events, scope, "returned"),
        f"crashed session {scope.session_id} published Returned",
    )
    receipt = history_entry(scope.session_id)["receipt"]
    require(
        isinstance(receipt, dict)
        and receipt.get("Crash", {}).get("summary") == "systemd result: exit-code",
        f"crash receipt was not durable: {receipt}",
    )
    require(
        unit_is_active(OWNER_UNIT),
        f"selected owner inactive after crash receipt for {scope.session_id}",
    )
    return scope.session_id


# --- B4 (tsp-f3fm.202.1.4): app-session input broker, grab order, SafeReturn, R4 ----


def evidence(line: str) -> None:
    print(f"evidence: {line}", flush=True)


def monotonic_usec(unit: str, property_name: str) -> int:
    value = property_value(unit, property_name)
    return int(value) if value.isdigit() else 0


def grab_lock_is_held() -> bool:
    """Negative control for the grab model: can a third party take the pad lock now?"""
    with open(GRAB_LOCK, "rb") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(handle, fcntl.LOCK_UN)
    return False


def grab_violations() -> list[str]:
    path = GRAB / "violations"
    return path.read_text().splitlines() if path.exists() else []


def grab_timeline() -> list[tuple[str, str, int]]:
    path = GRAB / "timeline"
    entries = []
    for line in path.read_text().splitlines() if path.exists() else []:
        kind, who, monotonic_ns, _pid = line.split()
        entries.append((kind, who, int(monotonic_ns)))
    return entries


def wait_for_owner_grab(label: str) -> None:
    """The restored shell process itself (by MainPID) holds the grab before we go on."""

    def grabbed() -> bool:
        path = GRAB / "timeline"
        if not path.exists():
            return False
        pid = property_value(OWNER_UNIT, "MainPID")
        grabs = [line.split() for line in path.read_text().splitlines() if line.startswith("grab ")]
        return bool(grabs) and grabs[-1][1] == "shell" and grabs[-1][3] == pid

    wait_for(grabbed, f"restored shell grab after {label}")


def broker_grab_count() -> int:
    return sum(1 for kind, who, _ in grab_timeline() if (kind, who) == ("grab", "broker"))


class GrabOrder:
    """systemd's own unit timestamps, read after every restore, as a second instrument.

    Shell stop must complete before the broker's main process starts, and the broker's
    stop must complete before the restored shell's main process starts.
    """

    def __init__(self) -> None:
        self.last_shell_start = 0
        self.sessions = 0

    def checkpoint(self, label: str) -> None:
        shell_stopped = monotonic_usec(OWNER_UNIT, "InactiveEnterTimestampMonotonic")
        broker_started = monotonic_usec(BROKER_UNIT, "ExecMainStartTimestampMonotonic")
        broker_stopped = monotonic_usec(BROKER_UNIT, "InactiveEnterTimestampMonotonic")
        shell_started = monotonic_usec(OWNER_UNIT, "ExecMainStartTimestampMonotonic")
        order = (
            f"{label}: shell_stopped={shell_stopped} broker_started={broker_started} "
            f"broker_stopped={broker_stopped} shell_started={shell_started}"
        )
        require(
            self.last_shell_start < shell_stopped <= broker_started < broker_stopped <= shell_started,
            f"grab order violated (usec, CLOCK_MONOTONIC): {order} previous_shell_start={self.last_shell_start}",
        )
        require(not grab_violations(), f"grab model conflict after {label}: {grab_violations()}")
        self.last_shell_start = shell_started
        self.sessions += 1


def assert_broker_dormant_at_boot() -> str:
    require(not unit_is_active(BROKER_UNIT), f"{BROKER_UNIT} is active at boot")
    enabled = command("systemctl", "is-enabled", BROKER_UNIT, check=False).stdout.strip()
    require(enabled == "disabled", f"{BROKER_UNIT} is-enabled={enabled!r}, want disabled")
    require(broker_grab_count() == 0, "broker grabbed before any app session")
    require(grab_lock_is_held(), "negative control: the shell does not hold the pad grab model")
    return enabled


def broker_control(request: bytes) -> bytes:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
        stream.settimeout(2)
        stream.connect(str(BROKER_CONTROL))
        stream.sendall(request + b"\n")
        return stream.recv(16)


def press_guide() -> float:
    reply = broker_control(b"guide")
    require(reply.strip() == b"sent", f"fake broker did not accept the guide press: {reply!r}")
    return time.monotonic()


def launch_held(mode: str) -> SessionEventScope:
    MODE.write_text(f"{mode}\n")
    PROBE.unlink(missing_ok=True)
    before_invocations = invocation_count()
    require(owner_pid() > 0, "selected owner did not start before launch")
    scope = launch()
    wait_for(
        lambda: invocation_count() == before_invocations + 1 and PROBE.exists(),
        f"fixture invocation and sandbox probe for {scope.session_id}",
    )
    require(unit_is_active(APP_UNIT), f"{APP_UNIT} never reached active")
    require(unit_is_active(BROKER_UNIT), f"{BROKER_UNIT} not active during {scope.session_id}")
    require(not unit_is_active(OWNER_UNIT), f"selected owner active during {scope.session_id}")
    events()
    require_session_phase(scope, "Running")
    return scope


def assert_app_session_wiring(scope: SessionEventScope) -> dict[str, Any]:
    """What the real pf-app@ sandbox and the real broker drop-in give each side."""
    probe = json.loads(PROBE.read_text())
    require(probe["PF_DESCRIPTOR"] == DESCRIPTOR, f"PF_DESCRIPTOR: {probe}")
    require(probe["descriptor_readable"] is True, f"descriptor unreadable in app sandbox: {probe}")
    require(probe["PF_BROKER_SOCK"] == str(BROKER_SOCKET), f"PF_BROKER_SOCK: {probe}")
    require(probe["broker_connect"] == "ok", f"app cannot reach the broker acquire socket: {probe}")
    require(
        probe["authority_connect"] != "ok" and probe["authority_mode"] == "0o0",
        f"app can reach the session authority (InaccessiblePaths ineffective): {probe}",
    )
    # Positive control, same run: the same uid OUTSIDE the unit sandbox can connect,
    # so the refusal above is the unit's InaccessiblePaths=, not socket permissions.
    outside = command(
        "setpriv", "--reuid=gamer", "--regid=gamer", "--init-groups", "python3", "-c",
        "import socket; s = socket.socket(socket.AF_UNIX); "
        f"s.connect({str(SOCKET)!r}); print('ok')",
        check=False,
    )
    require(outside.stdout.strip() == "ok", f"positive control failed: gamer outside pf-app@ "
            f"cannot reach the authority: rc={outside.returncode} {outside.stderr.strip()}")
    broker_socket = os.stat(BROKER_SOCKET)
    gamer_gid = grp.getgrnam("gamer").gr_gid
    require(
        stat.S_ISSOCK(broker_socket.st_mode)
        and stat.S_IMODE(broker_socket.st_mode) == 0o770
        and broker_socket.st_uid == 0
        and broker_socket.st_gid == gamer_gid,
        f"broker acquire socket is not root:gamer 0770: mode={oct(broker_socket.st_mode)} "
        f"uid={broker_socket.st_uid} gid={broker_socket.st_gid}",
    )
    start = json.loads((GRAB / "broker-starts.jsonl").read_text().splitlines()[-1])
    require(start["uid"] == 0 and start["gid"] == gamer_gid, f"broker credentials: {start}")
    require(start["umask"] == "0o7", f"broker UMask: {start}")
    require(start["PF_PREFSD_SOCK"] == "/run/pocketforge/prefsd.sock", f"broker env: {start}")
    require(
        start["shell"] == "inactive" and start["target"] == "active",
        f"broker started before the shell stopped or the target started: {start}",
    )
    require(grab_lock_is_held(), "negative control: the broker does not hold the pad grab model")
    return probe


def assert_safe_return_graceful(order: GrabOrder) -> str:
    scope = launch_held("hold")
    probe = assert_app_session_wiring(scope)
    pressed = press_guide()
    wait_for(
        lambda: property_value(APP_UNIT, "ActiveState") == "inactive",
        f"SafeReturn to stop {APP_UNIT} for {scope.session_id}",
        timeout=5,
    )
    stop_seconds = time.monotonic() - pressed
    require(property_value(APP_UNIT, "Result") == "success", "graceful SafeReturn stop was not clean")
    require(stop_seconds < 2.0, f"graceful SafeReturn took {stop_seconds:.2f}s (TimeoutStopSec=2s)")
    wait_for_app_exit(scope, "inactive")
    wait_for(lambda: not unit_is_active(BROKER_UNIT), f"{BROKER_UNIT} to stop after {scope.session_id}")
    assert_no_terminal_before_presentation(scope)
    observed = rpc({"method": "observe", "observation": {"kind": "presentation_acknowledged"}})
    require(observed.get("result") == "ok", f"presentation acknowledgement failed: {observed}")
    final_events = events()
    returned = session_events(final_events, scope, "returned")
    require(len(returned) == 1, f"SafeReturn Returned count for {scope.session_id}: {returned}")
    for other in ("crash", "forced_close", "recovery_required"):
        require(not session_events(final_events, scope, other), f"graceful SafeReturn published {other}")
    require(history_entry(scope.session_id)["receipt"] == "Returned", "graceful receipt not durable")
    order.checkpoint(scope.session_id)
    evidence(
        f"safe_return_graceful session={scope.session_id} receipt=Returned app_result=success "
        f"guide_to_inactive_s={stop_seconds:.2f} broker_sock=root:gamer:0770 "
        f"app_broker_connect={probe['broker_connect']} app_authority_connect={probe['authority_connect']} "
        "authority_outside_sandbox=ok grab_lock_negative_control=held-by-broker"
    )
    return scope.session_id


def app_timeout_log_count() -> int:
    journal = command("journalctl", "--unit", APP_UNIT, "--no-pager", "--output", "cat").stdout
    return journal.count("Failed with result 'timeout'")


def probe_systemctl_stop_after_sigkill(order: GrabOrder) -> dict[str, Any]:
    """R4, measured directly: the exit status of the authority's exact stop command
    when the app ignores SIGTERM and systemd SIGKILLs it at TimeoutStopSec=2s."""
    require(authority_state()["phase"] == "Idle", f"authority busy before R4 probe: {authority_state()['phase']}")
    MODE.write_text("ignore-term\n")
    PROBE.unlink(missing_ok=True)
    before_invocations = invocation_count()
    before_timeouts = app_timeout_log_count()
    started = command("systemctl", "start", APP_UNIT, check=False)
    require(started.returncode == 0, f"R4 probe start failed: {started.stderr.strip()}")
    wait_for(lambda: invocation_count() == before_invocations + 1 and PROBE.exists(), "R4 probe app")
    stop_started = time.monotonic()
    stopped = command("systemctl", "stop", APP_UNIT, check=False)
    stop_seconds = time.monotonic() - stop_started
    active_state = property_value(APP_UNIT, "ActiveState")
    result = property_value(APP_UNIT, "Result")
    killed = command("systemctl", "kill", "--kill-who=all", APP_UNIT, check=False)
    wait_for(lambda: not unit_is_active(TARGET_UNIT), "target release after R4 probe")
    wait_for(lambda: unit_is_active(OWNER_UNIT), "owner restore after R4 probe")
    wait_for(lambda: not unit_is_active(BROKER_UNIT), "broker stop after R4 probe")
    wait_for_owner_grab("r4-probe")
    require(
        active_state == "failed" and result == "timeout" and stop_seconds >= 1.9,
        f"R4 probe did not exercise the SIGKILL path: state={active_state} result={result} "
        f"stop_s={stop_seconds:.2f}",
    )
    require(app_timeout_log_count() == before_timeouts + 1, "R4 probe: no 'Failed with result timeout' journal line")
    order.checkpoint("r4-probe")
    command("systemctl", "reset-failed", APP_UNIT, check=False)
    return {
        "stop_exit": stopped.returncode,
        "kill_exit": killed.returncode,
        "kill_stderr": killed.stderr.strip().replace(" ", "_") or "none",
        "stop_seconds": stop_seconds,
        "result": result,
    }


def assert_safe_return_after_sigkill(order: GrabOrder, r4: dict[str, Any]) -> str:
    """R4 GATE (gpu-14): SafeReturn to an app that ignores SIGTERM must end Returned."""
    scope = launch_held("ignore-term")
    before_timeouts = app_timeout_log_count()
    pressed = press_guide()
    wait_for(
        lambda: property_value(APP_UNIT, "ActiveState") == "failed",
        f"SIGKILL at TimeoutStopSec for {scope.session_id}",
        timeout=8,
    )
    stop_seconds = time.monotonic() - pressed
    result = property_value(APP_UNIT, "Result")
    wait_for(lambda: not unit_is_active(TARGET_UNIT), f"target release after {scope.session_id}")
    wait_for(lambda: unit_is_active(OWNER_UNIT), f"owner restore after {scope.session_id}")
    wait_for(lambda: not unit_is_active(BROKER_UNIT), f"broker stop after {scope.session_id}")
    wait_for_owner_grab(scope.session_id)
    try:
        events()
        rpc_state = "ok"
    except TestFailure as error:
        rpc_state = f"error:{error}".replace(" ", "_")
    phase = authority_state()["phase"]
    phase_name = phase if isinstance(phase, str) else next(iter(phase))
    payload = phase.get(phase_name, {}) if isinstance(phase, dict) else {}
    pending = payload.get("receipt")
    pending_name = pending if isinstance(pending, str) else json.dumps(pending, separators=(",", ":"))
    safe_return_log = (GRAB / "safe-return.log").read_text().splitlines()[-1:]
    evidence(
        f"r4_sigkill session={scope.session_id} app_result={result} "
        f"guide_to_failed_s={stop_seconds:.2f} authority_phase={phase_name} "
        f"rung={payload.get('rung')} pending_receipt={pending_name} "
        f"reason={str(payload.get('reason', 'none')).replace(' ', '_')} events_rpc={rpc_state} "
        f"systemctl_stop_exit_after_sigkill={r4['stop_exit']} probe_stop_s={r4['stop_seconds']:.2f} "
        f"systemctl_kill_exit_on_failed_unit={r4['kill_exit']} kill_stderr={r4['kill_stderr']} "
        f"broker_safe_return={safe_return_log}"
    )
    require(
        result == "timeout" and stop_seconds >= 1.9 and app_timeout_log_count() == before_timeouts + 1,
        f"R4: SafeReturn did not reach the SIGKILL path: result={result} stop_s={stop_seconds:.2f}",
    )
    require(
        phase_name == "Restoring"
        and payload.get("rung") == "PresentationAcknowledged"
        and pending == "Returned",
        f"R4 GATE FAILED: authority phase after SIGKILL at TimeoutStopSec=2s is {phase} "
        f"(systemctl stop exit {r4['stop_exit']}, systemctl kill exit {r4['kill_exit']})",
    )
    observed = rpc({"method": "observe", "observation": {"kind": "presentation_acknowledged"}})
    require(observed.get("result") == "ok", f"presentation acknowledgement failed: {observed}")
    final_events = events()
    require(len(session_events(final_events, scope, "returned")) == 1, "R4: Returned not published once")
    for other in ("crash", "forced_close", "recovery_required"):
        require(not session_events(final_events, scope, other), f"R4 session published {other}")
    require(history_entry(scope.session_id)["receipt"] == "Returned", "R4 receipt not durable")
    order.checkpoint(scope.session_id)
    return scope.session_id


def assert_broker_failure_never_traps() -> str:
    """A broker that cannot start keeps the app from starting AND gives the panel back."""
    command("systemctl", "reset-failed", APP_UNIT, BROKER_UNIT, check=False)
    MODE.write_text("hold\n")
    before_invocations = invocation_count()
    before_broker_grabs = broker_grab_count()
    previous_owner = owner_pid()
    UINPUT.unlink()
    try:
        scope = launch()
    finally:
        UINPUT.touch(mode=0o600)
    assert_result = property_value(BROKER_UNIT, "AssertResult")
    released = True
    try:
        wait_for(lambda: not unit_is_active(TARGET_UNIT), f"target release after broker failure in {scope.session_id}")
        wait_for(lambda: unit_is_active(OWNER_UNIT), f"owner restore after broker failure in {scope.session_id}")
        wait_for_owner_grab(scope.session_id)
    except TestFailure:
        released = False
    target_state = property_value(TARGET_UNIT, "ActiveState")
    owner_state = property_value(OWNER_UNIT, "ActiveState")
    events()
    phase = authority_state()["phase"]
    evidence(
        f"broker_start_failure session={scope.session_id} broker_assert_result={assert_result} "
        f"app_invocations={invocation_count() - before_invocations} target={target_state} "
        f"owner={owner_state} panel_returned={'yes' if released else 'no'} "
        f"authority_phase={json.dumps(phase, separators=(',', ':'))}"
    )
    require(assert_result == "no", f"broker AssertPathExists=/dev/uinput did not fail: {assert_result!r}")
    require(invocation_count() == before_invocations, "app started although its broker failed")
    require(broker_grab_count() == before_broker_grabs, "failed broker grabbed the pad")
    require(released, f"user trapped: broker start failure left target={target_state} owner={owner_state}")
    require(owner_pid() != previous_owner, "owner was not re-activated after the broker failure")
    require_session_phase(scope, "Restoring", "PresentationAcknowledged")
    observed = rpc({"method": "observe", "observation": {"kind": "presentation_acknowledged"}})
    require(observed.get("result") == "ok", f"presentation acknowledgement failed: {observed}")
    receipt = history_entry(scope.session_id)["receipt"]
    require(
        isinstance(receipt, dict) and "systemd_start_failed" in receipt.get("Crash", {}).get("summary", ""),
        f"broker failure receipt is not a systemd_start_failed Crash: {receipt}",
    )
    require(not session_events(events(), scope, "returned"), "broker failure published Returned")
    return scope.session_id


# --- tsp-f3fm.202.1.6: a broker that starts and then exits must fail ONCE -------------


def broker_attempts() -> int:
    return len(BROKER_ATTEMPTS.read_text().splitlines()) if BROKER_ATTEMPTS.exists() else 0


def phase_summary() -> tuple[str, dict[str, Any]]:
    phase = authority_state()["phase"]
    name = phase if isinstance(phase, str) else next(iter(phase))
    payload = phase.get(name, {}) if isinstance(phase, dict) else {}
    return name, payload


def compact(value: Any) -> str:
    return value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))


def waiting_on_presentation(scope: SessionEventScope) -> bool:
    """The authority waits on this session's presentation acknowledgement: at the rung, or
    after the rung's deadline in the one recovery a late acknowledgement completes."""
    name, payload = phase_summary()
    if payload.get("session_id") != scope.session_id:
        return False
    if name == "Restoring":
        return payload.get("rung") == "PresentationAcknowledged"
    return name == "RecoveryRequired" and str(payload.get("reason", "")).startswith(
        PRESENTATION_TIMEOUT_PREFIX
    )


def acknowledge_and_read_receipt(scope: SessionEventScope) -> Any:
    """Acknowledge presentation only when the authority is waiting for exactly that."""
    if not waiting_on_presentation(scope):
        return None
    observed = rpc({"method": "observe", "observation": {"kind": "presentation_acknowledged"}})
    require(observed.get("result") == "ok", f"presentation acknowledgement failed: {observed}")
    return history_entry(scope.session_id)["receipt"]


def watch_units(seconds: float) -> dict[str, Any]:
    """Sample the shell and the broker: a restart of either one, or a shell stop, shows here."""
    owner_pids: set[str] = set()
    owner_inactive = broker_up = samples = 0
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        owner_pids.add(property_value(OWNER_UNIT, "MainPID"))
        owner_inactive += 0 if unit_is_active(OWNER_UNIT) else 1
        broker_up += property_value(BROKER_UNIT, "ActiveState") in ("active", "activating", "reloading")
        samples += 1
        time.sleep(0.2)
    return {"owner_pids": owner_pids, "owner_inactive": owner_inactive, "broker_up": broker_up,
            "samples": samples}


def assert_broker_exit_before_ready_never_traps() -> str:
    """(a) The broker starts, then exits 1 before READY=1 (the .215 source refusal).

    The start job fails once, with no restart, so the app job fails as a dependency.
    The shell is back within 10 s and stays up, with no shell/broker ping-pong, for 30 s.
    """
    command("systemctl", "reset-failed", APP_UNIT, BROKER_UNIT, check=False)
    require(phase_summary()[0] == "Idle", f"authority busy before case (a): {authority_state()['phase']}")
    restart_policy = property_value(BROKER_UNIT, "Restart")
    MODE.write_text("hold\n")
    before_invocations = invocation_count()
    before_grabs = broker_grab_count()
    before_attempts = broker_attempts()
    previous_owner = owner_pid()
    restored_s: float | None = None
    BROKER_MODE.write_text("exit-before-ready\n")
    try:
        launched = time.monotonic()
        scope = launch()
        try:
            wait_for(
                lambda: unit_is_active(OWNER_UNIT) and owner_pid() not in (0, previous_owner),
                f"owner restore after the broker exited before READY in {scope.session_id}",
                timeout=10.0,
            )
            wait_for_owner_grab(scope.session_id)
            restored_s = time.monotonic() - launched
        except TestFailure:
            pass
        restored_pid = property_value(OWNER_UNIT, "MainPID")
        watch = watch_units(30.0)
    finally:
        BROKER_MODE.unlink(missing_ok=True)
    nrestarts = property_value(BROKER_UNIT, "NRestarts")
    broker_state = property_value(BROKER_UNIT, "ActiveState")
    broker_result = property_value(BROKER_UNIT, "Result")
    attempts = broker_attempts() - before_attempts
    violations = grab_violations()
    events()
    phase_name, payload = phase_summary()
    receipt = acknowledge_and_read_receipt(scope)
    evidence(
        f"broker_exit_before_ready session={scope.session_id} broker_restart={restart_policy} "
        f"broker_state={broker_state} broker_result={broker_result} broker_nrestarts={nrestarts} "
        f"broker_attempts={attempts} app_invocations={invocation_count() - before_invocations} "
        f"broker_grabs={broker_grab_count() - before_grabs} "
        f"owner_restore_s={'none' if restored_s is None else f'{restored_s:.2f}'} "
        f"watch_s=30 watch_samples={watch['samples']} owner_pids_in_watch={len(watch['owner_pids'])} "
        f"owner_inactive_samples={watch['owner_inactive']} broker_up_samples={watch['broker_up']} "
        f"grab_violations={len(violations)} authority_phase={phase_name} rung={payload.get('rung')} "
        f"receipt={compact(receipt)}"
    )
    require(restart_policy == "no", f"effective broker Restart={restart_policy!r}, want 'no'")
    require(attempts == 1 and nrestarts == "0", f"broker restarted: attempts={attempts} NRestarts={nrestarts}")
    require(broker_state == "failed" and broker_result == "exit-code",
            f"broker did not fail once with exit-code: {broker_state}/{broker_result}")
    require(invocation_count() == before_invocations, "app started although its broker exited before READY")
    require(broker_grab_count() == before_grabs, "broker grabbed although it exited before READY")
    require(restored_s is not None and restored_s <= 10.0, f"shell not back within 10 s: {restored_s}")
    require(
        watch["owner_pids"] == {restored_pid} and watch["owner_inactive"] == 0 and watch["broker_up"] == 0,
        f"shell/broker ping-pong in 30 s: {watch} restored_pid={restored_pid}",
    )
    require(not violations, f"grab model conflicts: {violations}")
    # The 30 s watch outlasts the presentation deadline and nothing acknowledges during it,
    # so the self-driven authority must have recorded the recoverable timeout (runtime#103).
    require(
        phase_name == "RecoveryRequired" and payload.get("session_id") == scope.session_id
        and str(payload.get("reason", "")).startswith(PRESENTATION_TIMEOUT_PREFIX)
        and "systemd_start_failed" in compact(payload.get("pending_receipt")),
        f"authority did not time out the presentation rung: phase={authority_state()['phase']}",
    )
    require(
        isinstance(receipt, dict) and "systemd_start_failed" in receipt.get("Crash", {}).get("summary", ""),
        f"receipt is not a systemd_start_failed Crash: {receipt}",
    )
    require(phase_summary()[0] == "Idle", f"late acknowledgement did not complete: {authority_state()['phase']}")
    require(not session_events(events(), scope, "returned"), "broker exit before READY published Returned")
    return scope.session_id


def assert_broker_exit_mid_session_never_traps(order: GrabOrder) -> str:
    """(b) The broker exits 1 mid-session, after READY=1, while the app runs.

    The broker fails once. pf-app@ is stopped because it is bound to the broker,
    the target is released, and the shell returns. The authority reaches its
    presentation rung and records a terminal receipt; it does not stall in Restoring.
    """
    command("systemctl", "reset-failed", APP_UNIT, BROKER_UNIT, check=False)
    scope = launch_held("hold")
    before_attempts = broker_attempts()
    before_invocations = invocation_count()
    reply = broker_control(b"crash")
    require(reply.strip() == b"crashing", f"fake broker did not accept the crash request: {reply!r}")
    crashed = time.monotonic()
    app_stopped = restored = True
    try:
        wait_for(
            lambda: property_value(APP_UNIT, "ActiveState") in ("inactive", "failed"),
            f"{APP_UNIT} to stop after its broker exited in {scope.session_id}",
            timeout=10.0,
        )
    except TestFailure:
        app_stopped = False
    try:
        wait_for(lambda: not unit_is_active(TARGET_UNIT), f"target release in {scope.session_id}", timeout=10.0)
        wait_for(lambda: unit_is_active(OWNER_UNIT), f"owner restore in {scope.session_id}", timeout=10.0)
        wait_for_owner_grab(scope.session_id)
    except TestFailure:
        restored = False
    restore_s = time.monotonic() - crashed
    # The runtime unit's RestartSec=2: wait past it so a restart would be visible.
    time.sleep(max(0.0, crashed + 3.0 - time.monotonic()))
    nrestarts = property_value(BROKER_UNIT, "NRestarts")
    attempts = broker_attempts() - before_attempts
    broker_state = property_value(BROKER_UNIT, "ActiveState")
    broker_result = property_value(BROKER_UNIT, "Result")
    app_state = property_value(APP_UNIT, "ActiveState")
    app_result = property_value(APP_UNIT, "Result")
    owner_state = property_value(OWNER_UNIT, "ActiveState")
    events()
    phase_name, payload = phase_summary()
    pending = payload.get("receipt")
    receipt = acknowledge_and_read_receipt(scope)
    evidence(
        f"broker_exit_mid_session session={scope.session_id} broker_state={broker_state} "
        f"broker_result={broker_result} broker_nrestarts={nrestarts} broker_restart_attempts={attempts} "
        f"app_state={app_state} app_result={app_result} app_stopped={'yes' if app_stopped else 'no'} "
        f"app_invocations={invocation_count() - before_invocations} owner={owner_state} "
        f"panel_returned={'yes' if restored else 'no'} exit_to_owner_grab_s={restore_s:.2f} "
        f"authority_phase={phase_name} rung={payload.get('rung')} pending_receipt={compact(pending)} "
        f"receipt={compact(receipt)}"
    )
    require(app_stopped and app_state != "active", f"user trapped: app still {app_state} after its broker exited")
    require(attempts == 0 and nrestarts == "0", f"broker restarted: attempts={attempts} NRestarts={nrestarts}")
    require(broker_state == "failed" and broker_result == "exit-code",
            f"broker did not fail once with exit-code: {broker_state}/{broker_result}")
    require(invocation_count() == before_invocations, "app was restarted after its broker exited")
    require(restored and restore_s <= 10.0, f"panel not returned within 10 s: restored={restored} {restore_s:.2f}s")
    require(
        phase_name == "Restoring" and payload.get("session_id") == scope.session_id
        and payload.get("rung") == "PresentationAcknowledged",
        f"authority stalled: phase={authority_state()['phase']}",
    )
    require(receipt == "Returned" or (isinstance(receipt, dict) and "Crash" in receipt),
            f"no Returned/Crash receipt recorded: {receipt}")
    terminal = [name for name in ("returned", "crash", "forced_close", "recovery_required")
                for _ in session_events(events(), scope, name)]
    require(len(terminal) == 1, f"terminal publications for {scope.session_id}: {terminal}")
    order.checkpoint(scope.session_id)
    return scope.session_id


def control_restart_on_failure_reproduces_trap() -> str:
    """Negative control, run LAST: the same exit-before-READY broker with the runtime
    unit's Restart=on-failure put back by a runtime drop-in must restart.

    This proves that case (a)'s broker_attempts, NRestarts and watch readings can see
    the .215 trap. The launch RPC may block, because the authority's systemctl start
    waits on the restarting broker. The authority is left mid-launch, and nothing
    runs after this.
    """
    require(phase_summary()[0] == "Idle", f"authority busy before the control: {authority_state()['phase']}")
    command("systemctl", "reset-failed", APP_UNIT, BROKER_UNIT, check=False)
    CONTROL_DROPIN.parent.mkdir(parents=True, exist_ok=True)
    CONTROL_DROPIN.write_text("[Service]\nRestart=on-failure\n")
    command("systemctl", "daemon-reload")
    restart_policy = property_value(BROKER_UNIT, "Restart")
    require(restart_policy == "on-failure", f"control drop-in not effective: Restart={restart_policy!r}")
    MODE.write_text("hold\n")
    before_attempts = broker_attempts()
    before_invocations = invocation_count()
    BROKER_MODE.write_text("exit-before-ready\n")
    try:
        launch()
        launch_rpc = "returned"
    except (OSError, TestFailure):
        launch_rpc = "blocked"
    try:
        wait_for(lambda: broker_attempts() - before_attempts >= 3, "control: broker restarts", timeout=15.0)
    except TestFailure:
        pass
    watch = watch_units(4.0)
    attempts = broker_attempts() - before_attempts
    nrestarts = property_value(BROKER_UNIT, "NRestarts")
    phase_name, payload = phase_summary()
    line = (
        f"control_restart_on_failure broker_restart={restart_policy} broker_attempts={attempts} "
        f"broker_nrestarts={nrestarts} app_invocations={invocation_count() - before_invocations} "
        f"launch_rpc={launch_rpc} owner_inactive_samples={watch['owner_inactive']}/{watch['samples']} "
        f"broker_up_samples={watch['broker_up']}/{watch['samples']} authority_phase={phase_name} "
        f"rung={payload.get('rung')} trap_reproduced={'yes' if attempts >= 3 else 'no'}"
    )
    evidence(line)
    require(attempts >= 3, f"negative control: Restart=on-failure did not restart the broker: {line}")
    require(invocation_count() == before_invocations, "negative control: the app started")
    return line


def assert_grab_timeline(order: GrabOrder) -> str:
    require(not grab_violations(), f"grab model conflicts: {grab_violations()}")
    entries = grab_timeline()
    grabs = [who for kind, who, _ in entries if kind == "grab"]
    require(grabs and grabs[0] == "shell" and grabs[-1] == "shell", f"grab sequence ends: {grabs}")
    for previous, current in zip(grabs, grabs[1:]):
        require(not (previous == current == "broker"), f"two broker grabs without a shell between: {grabs}")
    require(grabs.count("broker") == order.sessions, f"broker grabs {grabs.count('broker')} != sessions {order.sessions}")
    # Each grab follows the previous holder's SIGTERM by at least its 0.5 s hold:
    # the next unit started only after the previous one's process exited.
    gaps = {"shell->broker": [], "broker->shell": []}
    last_term: dict[str, int] = {}
    for kind, who, monotonic_ns in entries:
        if kind in ("term", "exit"):  # SIGTERM received, or a runtime exit (tsp-f3fm.202.1.6)
            last_term[who] = monotonic_ns
        elif who == "broker" and "shell" in last_term:
            gaps["shell->broker"].append(monotonic_ns - last_term.pop("shell"))
        elif who == "shell" and "broker" in last_term:
            gaps["broker->shell"].append(monotonic_ns - last_term.pop("broker"))
    for edge, values in gaps.items():
        require(len(values) == order.sessions, f"{edge} handoffs {len(values)} != sessions {order.sessions}")
        require(min(values) >= 450_000_000, f"{edge} handoff shorter than the 0.5 s release hold: {values}")
    cycles = command("journalctl", "--boot", "--no-pager", "--output", "cat").stdout
    require("ordering cycle" not in cycles, "systemd reported an ordering cycle")
    return (
        f"grab_sequence={','.join(grabs)} broker_sessions={order.sessions} violations=0 "
        f"min_shell_to_broker_ms={min(gaps['shell->broker']) // 1_000_000} "
        f"min_broker_to_shell_ms={min(gaps['broker->shell']) // 1_000_000} ordering_cycles=0"
    )


# --- tsp-f3fm.219 (I3): a crash with no client drives itself to a recoverable timeout ---


def authority_journal() -> str:
    return command("journalctl", "--unit", AUTHORITY_UNIT, "--no-pager", "--output", "cat").stdout


def assert_crash_self_driven_to_recovery_then_late_ack(order: GrabOrder) -> str:
    """After the launch RPC, NOTHING talks to the authority: the fake shell sends no RPC and
    the driver only reads systemd and authority.json. The authority's own tick must observe
    the crash, walk the restoration ladder to the presentation rung, record
    RecoveryRequired{presentation_not_acknowledged} within deadline + slack with its
    lifecycle_failure line, and refuse (and log) a launch while it waits. A late driver
    acknowledgement then completes the ladder to Idle with the Crash receipt in history.
    On runtime 0955d8a8 (no tick) the authority never leaves Running here.
    """
    require(phase_summary()[0] == "Idle", f"authority busy before I3: {authority_state()['phase']}")
    MODE.write_text("23\n")
    before_invocations = invocation_count()
    previous_owner = owner_pid()
    require(previous_owner > 0, "selected owner did not start before I3 launch")
    scope = launch()
    launched = time.monotonic()
    # From here until RecoveryRequired: no RPC of any kind.
    wait_for(lambda: invocation_count() == before_invocations + 1, f"fixture invocation for {scope.session_id}")
    wait_for(
        lambda: property_value(APP_UNIT, "ActiveState") == "failed",
        f"{APP_UNIT} to fail for {scope.session_id}",
    )
    wait_for(lambda: not unit_is_active(TARGET_UNIT), f"{TARGET_UNIT} to release for {scope.session_id}")
    wait_for(
        lambda: unit_is_active(OWNER_UNIT) and owner_pid() not in (0, previous_owner),
        f"{OWNER_UNIT} to be re-activated for {scope.session_id}",
    )
    wait_for(lambda: not unit_is_active(BROKER_UNIT), f"{BROKER_UNIT} to stop after {scope.session_id}")
    wait_for_owner_grab(scope.session_id)

    def at_rung() -> bool:
        name, payload = phase_summary()
        return (
            name == "Restoring"
            and payload.get("session_id") == scope.session_id
            and payload.get("rung") == "PresentationAcknowledged"
        )

    wait_for(at_rung, f"the self-driven tick to reach the presentation rung for {scope.session_id}")
    reached_rung = time.monotonic()
    wait_for(
        lambda: phase_summary()[0] == "RecoveryRequired",
        f"RecoveryRequired within {PRESENTATION_DEADLINE_S}+{DEADLINE_SLACK_S}s of the rung",
        timeout=PRESENTATION_DEADLINE_S + DEADLINE_SLACK_S,
    )
    recovery_s = time.monotonic() - reached_rung
    name, payload = phase_summary()
    require(payload.get("session_id") == scope.session_id, f"RecoveryRequired for another session: {payload}")
    require(
        str(payload.get("reason", "")).startswith(PRESENTATION_TIMEOUT_PREFIX),
        f"RecoveryRequired reason is not the presentation timeout: {payload}",
    )
    require(
        payload.get("pending_receipt") == {"Crash": {"summary": "systemd result: exit-code"}},
        f"owed Crash receipt not kept for the late acknowledgement: {payload}",
    )
    require(
        recovery_s >= PRESENTATION_DEADLINE_S - 1.0,
        f"presentation deadline expired early: {recovery_s:.2f}s after the rung",
    )
    failure_line = (
        "lifecycle_failure reason=presentation_not_acknowledged "
        f"item_id={json.dumps(APP_ID)}"
    )
    require(failure_line in authority_journal(), f"journal lacks {failure_line!r}")

    # RPCs are allowed again. The receipt is not truthful yet: nothing terminal was published.
    pending_events = events()
    require(
        len(session_events(pending_events, scope, "recovery_required")) == 1,
        f"RecoveryRequired publication count for {scope.session_id}: {pending_events}",
    )
    require(not session_events(pending_events, scope, "crash"), "Crash published before acknowledgement")
    require(history_entry(scope.session_id)["receipt"] is None, "history terminal before acknowledgement")
    busy = rpc({"method": "launch", "item_id": APP_ID})
    require(busy.get("result") == "rejected_busy", f"launch while recovery pending: {busy}")
    busy_line = (
        f"launch_refused reason=busy item_id={json.dumps(APP_ID)} phase=recovery_required"
    )
    require(busy_line in authority_journal(), f"journal lacks {busy_line!r}")
    require(invocation_count() == before_invocations + 1, "the refused launch started the app")

    observed = rpc({"method": "observe", "observation": {"kind": "presentation_acknowledged"}})
    require(observed.get("result") == "ok", f"late presentation acknowledgement failed: {observed}")
    require(phase_summary()[0] == "Idle", f"late acknowledgement did not reach Idle: {authority_state()['phase']}")
    final_events = events()
    crashes = session_events(final_events, scope, "crash")
    require(len(crashes) == 1, f"Crash publication count for {scope.session_id}: {crashes}")
    receipt = history_entry(scope.session_id)["receipt"]
    require(
        isinstance(receipt, dict) and receipt.get("Crash", {}).get("summary") == "systemd result: exit-code",
        f"late acknowledgement did not persist the Crash receipt: {receipt}",
    )
    order.checkpoint(scope.session_id)
    evidence(
        f"self_driven_recovery session={scope.session_id} launch_to_rung_s={reached_rung - launched:.2f} "
        f"rung_to_recovery_required_s={recovery_s:.2f} deadline_s={PRESENTATION_DEADLINE_S:.0f} "
        "rpcs_between_launch_and_recovery=0 lifecycle_failure_logged=yes busy_refusal_logged=yes "
        "late_ack=Idle receipt=Crash(systemd result: exit-code)"
    )
    return scope.session_id


def main() -> None:
    require(Path("/proc/1/comm").read_text().strip() == "systemd", "PID 1 is not systemd")
    require(command("uname", "-m").stdout.strip() == "x86_64", "container is not x86_64")
    framebuffer = Path("/dev/fb0")
    require(
        framebuffer.is_file() and framebuffer.stat().st_size == 0,
        "/dev/fb0 test prerequisite is absent or is not an empty regular file",
    )
    for prerequisite in (UINPUT, Path("/dev/input/pf-gamepad"), GRAB_LOCK):
        require(prerequisite.is_file(), f"{prerequisite} test prerequisite is not a regular file")
    wait_for(
        lambda: unit_is_active(AUTHORITY_UNIT) and authority_is_responding(),
        "authority socket",
    )
    wait_for(lambda: unit_is_active(OWNER_UNIT), "initial selected owner")
    wait_for_owner_grab("boot")
    broker_boot = assert_broker_dormant_at_boot()
    order = GrabOrder()

    assert_refusals_never_reach_systemd()
    before_clean_invocations = invocation_count()
    clean_session = assert_clean_exit_with_restart()
    clean_invocations = invocation_count() - before_clean_invocations
    require(clean_invocations == 1, f"clean launch invocation count: {clean_invocations}")
    order.checkpoint(clean_session)
    self_driven_session = assert_crash_self_driven_to_recovery_then_late_ack(order)
    before_crash_invocations = invocation_count()
    crash_session = assert_crash_exit()
    crash_invocations = invocation_count() - before_crash_invocations
    require(crash_invocations == 1, f"crash launch invocation count: {crash_invocations}")
    order.checkpoint(crash_session)

    print(
        "evidence: "
        f"clean_session={clean_session} returned=1 restart_mid_ladder=ok "
        f"crash_session={crash_session} crash=1 returned=0 "
        f"clean_invocations={clean_invocations} crash_invocations={crash_invocations} "
        "fb0=empty-regular-file "
        "session_scoping_negative_control=ok refused_systemctl_starts=0 owner_restore=ok "
        f"broker_at_boot=inactive,{broker_boot} grab_lock_negative_control=held-by-shell",
        flush=True,
    )
    graceful_session = assert_safe_return_graceful(order)
    r4 = probe_systemctl_stop_after_sigkill(order)
    sigkill_session = assert_safe_return_after_sigkill(order, r4)
    broker_failure_session = assert_broker_failure_never_traps()
    exit_before_ready_session = assert_broker_exit_before_ready_never_traps()
    exit_mid_session = assert_broker_exit_mid_session_never_traps(order)
    evidence(
        f"grab_order {assert_grab_timeline(order)} "
        f"sessions={clean_session},{self_driven_session},{crash_session},{graceful_session},r4-probe,"
        f"{sigkill_session},"
        f"{exit_mid_session} "
        f"broker_failure_session={broker_failure_session} "
        f"broker_exit_before_ready_session={exit_before_ready_session} "
        f"R4=Returned systemctl_stop_exit_after_sigkill={r4['stop_exit']}"
    )
    control_restart_on_failure_reproduces_trap()


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError, TestFailure, ValueError) as error:
        raise SystemExit(f"integration assertion failed: {error}") from error
