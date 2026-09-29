#!/usr/bin/env python3
"""Drive the production session-authority binary against real systemd."""

from __future__ import annotations

import json
import socket
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
SOCKET = Path("/run/pocketforge/session-authority.sock")
MODE = Path("/run/pocketforge/fixture-exit-code")
INVOCATIONS = Path(f"/var/lib/pocketforge/apps/{APP_ID}/state/invocations")
CLIENT_ID = "image-real-systemd"


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

    wait_for_app_exit(scope, expected_state)
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
    require(
        any(event.get("event") == "running" for _, event in durable),
        "negative control requires a durable Running event from the clean session",
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


def main() -> None:
    require(Path("/proc/1/comm").read_text().strip() == "systemd", "PID 1 is not systemd")
    require(command("uname", "-m").stdout.strip() == "x86_64", "container is not x86_64")
    framebuffer = Path("/dev/fb0")
    require(
        framebuffer.is_file() and framebuffer.stat().st_size == 0,
        "/dev/fb0 test prerequisite is absent or is not an empty regular file",
    )
    wait_for(
        lambda: unit_is_active(AUTHORITY_UNIT) and authority_is_responding(),
        "authority socket",
    )
    wait_for(lambda: unit_is_active(OWNER_UNIT), "initial selected owner")

    assert_refusals_never_reach_systemd()
    before_clean_invocations = invocation_count()
    clean_session = assert_clean_exit_with_restart()
    clean_invocations = invocation_count() - before_clean_invocations
    require(clean_invocations == 1, f"clean launch invocation count: {clean_invocations}")
    before_crash_invocations = invocation_count()
    crash_session = assert_crash_exit()
    crash_invocations = invocation_count() - before_crash_invocations
    require(crash_invocations == 1, f"crash launch invocation count: {crash_invocations}")

    print(
        "evidence: "
        f"clean_session={clean_session} returned=1 restart_mid_ladder=ok "
        f"crash_session={crash_session} crash=1 returned=0 "
        f"clean_invocations={clean_invocations} crash_invocations={crash_invocations} "
        "fb0=empty-regular-file "
        "session_scoping_negative_control=ok refused_systemctl_starts=0 owner_restore=ok"
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError, TestFailure, ValueError) as error:
        raise SystemExit(f"integration assertion failed: {error}") from error
