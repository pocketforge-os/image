#!/usr/bin/env python3
"""Drive the production session-authority binary against real systemd."""

from __future__ import annotations

import json
import socket
import struct
import subprocess
import time
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


def session_events(
    all_events: list[tuple[int, dict[str, Any]]], session_id: str, event_name: str
) -> list[tuple[int, dict[str, Any]]]:
    return [
        (sequence, event)
        for sequence, event in all_events
        if event.get("event") == event_name and event.get("session_id") == session_id
    ]


def history_entry(session_id: str) -> dict[str, Any]:
    response = rpc({"method": "history"})
    require(response.get("result") == "history", f"unexpected history response: {response}")
    matches = [entry for entry in response["entries"] if entry["session_id"] == session_id]
    require(len(matches) == 1, f"history does not contain exactly one {session_id}: {matches}")
    return matches[0]


def authority_is_responding() -> bool:
    try:
        return rpc({"method": "history"}).get("result") == "history"
    except (OSError, TestFailure, ValueError):
        return False


def launch() -> str:
    response = rpc({"method": "launch", "item_id": APP_ID})
    require(response.get("result") == "accepted", f"launch was not accepted: {response}")
    return str(response["session_id"])


def assert_no_terminal_before_presentation(session_id: str) -> None:
    current = events()
    require(
        not session_events(current, session_id, "returned")
        and not session_events(current, session_id, "crash"),
        f"terminal receipt published before presentation acknowledgement for {session_id}",
    )
    require(
        history_entry(session_id)["receipt"] is None,
        f"history became terminal before presentation acknowledgement for {session_id}",
    )


def wait_for_app_exit(expected_state: str) -> None:
    wait_for(
        lambda: property_value(APP_UNIT, "ActiveState") == expected_state,
        f"{APP_UNIT} to become {expected_state}",
    )
    wait_for(lambda: not unit_is_active(TARGET_UNIT), f"{TARGET_UNIT} to release")
    wait_for(lambda: unit_is_active(OWNER_UNIT), f"{OWNER_UNIT} to become active again")


def assert_start_and_exit(exit_code: int, expected_state: str) -> tuple[str, int]:
    MODE.write_text(f"{exit_code}\n")
    before_invocations = invocation_count()
    previous_owner_pid = owner_pid()
    require(previous_owner_pid > 0, "selected owner did not start before launch")

    session_id = launch()
    wait_for(
        lambda: invocation_count() == before_invocations + 1,
        f"fixture invocation for {session_id}",
    )
    require(unit_is_active(APP_UNIT), f"{APP_UNIT} never reached active")
    require(not unit_is_active(OWNER_UNIT), "selected owner stayed active while app owned the slot")

    running_events = events()
    require(
        any(event.get("event") == "running" for _, event in running_events),
        f"authority did not observe {session_id} running",
    )

    wait_for_app_exit(expected_state)
    restored_owner_pid = owner_pid()
    require(restored_owner_pid > 0, "selected owner has no process after restoration")
    require(
        restored_owner_pid != previous_owner_pid,
        "selected owner was not stopped and newly activated around app ownership",
    )
    return session_id, restored_owner_pid


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
    session_id, _ = assert_start_and_exit(0, "inactive")
    require(property_value(APP_UNIT, "Result") == "success", "clean fixture did not exit successfully")

    assert_no_terminal_before_presentation(session_id)
    state = json.loads(
        Path("/var/lib/pocketforge/session-authority/authority.json").read_text()
    )
    restoring = state["phase"].get("Restoring", {})
    require(
        restoring.get("rung") == "PresentationAcknowledged",
        f"authority was not paused immediately before presentation: {state['phase']}",
    )

    command("systemctl", "restart", AUTHORITY_UNIT)
    wait_for(
        lambda: unit_is_active(AUTHORITY_UNIT) and authority_is_responding(),
        "authority restart",
    )
    assert_no_terminal_before_presentation(session_id)

    observed = rpc(
        {"method": "observe", "observation": {"kind": "presentation_acknowledged"}}
    )
    require(observed.get("result") == "ok", f"presentation acknowledgement failed: {observed}")

    final_events = events()
    returned = session_events(final_events, session_id, "returned")
    require(len(returned) == 1, f"Returned publication count for {session_id}: {returned}")
    require(not session_events(final_events, session_id, "crash"), "clean exit reported Crash")
    require(history_entry(session_id)["receipt"] == "Returned", "clean receipt was not durable")

    replayed_events = events()
    require(
        session_events(replayed_events, session_id, "returned") == returned,
        "authority restart or replay changed the single durable Returned publication",
    )
    require(unit_is_active(OWNER_UNIT), "selected owner inactive after clean receipt")
    return session_id


def assert_crash_exit() -> str:
    session_id, _ = assert_start_and_exit(23, "failed")
    require(property_value(APP_UNIT, "Result") == "exit-code", "crash fixture result was not exit-code")
    assert_no_terminal_before_presentation(session_id)

    observed = rpc(
        {"method": "observe", "observation": {"kind": "presentation_acknowledged"}}
    )
    require(observed.get("result") == "ok", f"presentation acknowledgement failed: {observed}")

    final_events = events()
    crashes = session_events(final_events, session_id, "crash")
    require(len(crashes) == 1, f"Crash publication count for {session_id}: {crashes}")
    require(
        "systemd result: exit-code" in crashes[0][1].get("summary", ""),
        f"Crash summary did not preserve systemd result: {crashes}",
    )
    require(
        not session_events(final_events, session_id, "returned"),
        "crashed session published Returned",
    )
    receipt = history_entry(session_id)["receipt"]
    require(
        isinstance(receipt, dict)
        and receipt.get("Crash", {}).get("summary") == "systemd result: exit-code",
        f"crash receipt was not durable: {receipt}",
    )
    require(unit_is_active(OWNER_UNIT), "selected owner inactive after crash receipt")
    return session_id


def main() -> None:
    require(Path("/proc/1/comm").read_text().strip() == "systemd", "PID 1 is not systemd")
    require(command("uname", "-m").stdout.strip() == "x86_64", "container is not x86_64")
    Path("/dev/fb0").touch()
    wait_for(
        lambda: unit_is_active(AUTHORITY_UNIT) and authority_is_responding(),
        "authority socket",
    )
    wait_for(lambda: unit_is_active(OWNER_UNIT), "initial selected owner")

    assert_refusals_never_reach_systemd()
    clean_session = assert_clean_exit_with_restart()
    crash_session = assert_crash_exit()

    print(
        "evidence: "
        f"clean_session={clean_session} returned=1 restart_mid_ladder=ok "
        f"crash_session={crash_session} crash=1 returned=0 "
        "refused_systemctl_starts=0 owner_restore=ok"
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError, TestFailure, ValueError) as error:
        raise SystemExit(f"integration assertion failed: {error}") from error
