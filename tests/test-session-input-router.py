#!/usr/bin/env python3
"""Static contract for the session-wide controller owner (tsp-ihne1.7)."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SYSTEMD = ROOT / "rootfs-overlay/etc/systemd/system"


def unit(path: Path) -> dict[str, dict[str, list[str]]]:
    parsed: dict[str, dict[str, list[str]]] = {}
    section = ""
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            parsed.setdefault(section, {})
            continue
        key, separator, value = line.partition("=")
        assert separator, f"invalid directive in {path}: {raw}"
        parsed.setdefault(section, {}).setdefault(key, []).append(value)
    return parsed


def words(parsed: dict[str, dict[str, list[str]]], section: str, key: str) -> list[str]:
    result: list[str] = []
    for value in parsed.get(section, {}).get(key, []):
        result = [] if not value else result + value.split()
    return result


broker = unit(SYSTEMD / "pf-input-broker.service.d/10-app-session.conf")
app = unit(SYSTEMD / "pf-app@.service")
session = unit(SYSTEMD / "pocketforge-gamescope-session.target")
gamescope = unit(SYSTEMD / "pocketforge-gamescope.service")
shell = unit(SYSTEMD / "pf-shell-selected.service.d/10-input-broker.conf")

# One broker spans the complete compositor session. App churn cannot stop or restart it.
assert "pf-input-broker.service" in words(session, "Unit", "Requires")
assert "pf-input-broker.service" in words(session, "Unit", "After")
assert "pocketforge-gamescope-session.target" in words(broker, "Unit", "PartOf")
assert words(broker, "Unit", "StopWhenUnneeded") == []
assert "pf-input-broker.service" not in words(app, "Unit", "BindsTo")
assert "pf-input-broker.service" not in words(app, "Unit", "After")

# The physical pad has one holder throughout the session. Gamescope only receives the
# broker's private virtual devices; the selected shell can start only after broker teardown.
assert "pf-input-broker.service" in words(gamescope, "Unit", "After")
assert words(shell, "Unit", "After") == ["pf-input-broker.service"]
assert "pf-shell-selected.service" in words(broker, "Unit", "Conflicts")

# Gamescope registers on the frozen compositor endpoint. The router derives its session uid from
# the configured account and authenticates the exact gamescope unit plus role group at accept.
command = words(broker, "Service", "ExecStart")
assert command[command.index("--compositor-sock") + 1] == "/run/pocketforge/input/compositor.sock"
assert command[command.index("--session-user") + 1] == "gamer"

# Restart immediately once. RestartMode=direct suppresses OnFailure during that retry;
# StartLimitBurst=2 makes the second failure terminal and activates the shell fallback.
assert words(broker, "Service", "Restart") == ["on-failure"]
assert words(broker, "Service", "RestartSec") == ["0"]
assert words(broker, "Service", "RestartMode") == ["direct"]
assert words(broker, "Unit", "StartLimitBurst") == ["2"]
assert words(broker, "Unit", "OnFailure") == ["pocketforge-gamescope-fallback.service"]

# The exact in-ipc endpoints are created beneath a non-app-traversable parent.
tmpfiles = (ROOT / "rootfs-overlay/usr/lib/tmpfiles.d/pf-input.conf").read_text()
assert "d /run/pocketforge/input 0750 root pf-input -" in tmpfiles
sysusers = (ROOT / "rootfs-overlay/usr/lib/sysusers.d/pf-input.conf").read_text()
for group in ("pf-input", "pf-input-compositor", "pf-input-keyboard", "pf-input-menu"):
    assert f"g {group} -" in sysusers
assert "m gamer pf-input" not in sysusers

print("session input router wiring: PASS owner=session restart_failures=2 app_controls_lifetime=no")
