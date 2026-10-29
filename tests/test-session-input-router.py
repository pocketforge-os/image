#!/usr/bin/env python3
"""Static contract for the session-wide controller owner (tsp-ihne1.7)."""

import json
import re
import tomllib
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


def selects_input_broker(
    capabilities: list[str], resources: dict[str, list[str]]
) -> bool:
    requested_input = {"input", "rumble", "vibration"}.intersection(capabilities)
    requested_brokered = {
        "accelerometer",
        "gnss",
        "gyroscope",
        "imu",
        "leds",
        "location",
        "magnetometer",
    }.intersection(capabilities)
    return bool(resources.get("broker-sockets")) and bool(
        requested_input or requested_brokered
    )


fixture_manifest = tomllib.loads(
    (ROOT / "tests/session-authority-systemd/app.toml").read_text()
)
fixture_capabilities = fixture_manifest["app"]["use"]
inventory = json.loads(
    (ROOT / "build/app-policy-a133-open-g1-v1.json").read_text()
)["resources"]
drive = (ROOT / "tests/session-authority-systemd/drive.py").read_text()

# The signed G1 inventory selects raw input for this fixture. The live collector
# must therefore prove that pf-app-launch scrubs its ambient broker selector.
assert fixture_capabilities == ["input"], fixture_capabilities
assert inventory.get("input-devices"), inventory
assert not selects_input_broker(fixture_capabilities, inventory), inventory
assert 'probe["PF_BROKER_SOCK"] == ""' in drive
assert 'probe["broker_connect"] == "unset"' in drive

# Positive and negative controls in the same invocation: adding the canonical
# broker inventory selects it for input, while no input authority selects none.
broker_inventory = dict(inventory)
broker_inventory["broker-sockets"] = ["/run/pocketforge/input-broker.sock"]
assert selects_input_broker(fixture_capabilities, broker_inventory)
assert not selects_input_broker([], broker_inventory)

# One broker spans the complete compositor session. App churn cannot stop or restart it.
assert "pf-input-broker.service" in words(session, "Unit", "Requires")
assert "pf-input-broker.service" in words(session, "Unit", "After")
assert "pocketforge-gamescope-session.target" in words(broker, "Unit", "PartOf")
assert words(broker, "Unit", "StopWhenUnneeded") == []
assert "pf-input-broker.service" not in words(app, "Unit", "BindsTo")
assert "pf-input-broker.service" not in words(app, "Unit", "After")
assert words(app, "Unit", "PartOf") == ["pocketforge-gamescope-session.target"]

# The physical pad has one holder throughout the session. Gamescope only receives the
# broker's private virtual devices; the selected shell can start only after broker teardown.
assert "pf-input-broker.service" in words(gamescope, "Unit", "After")
assert words(shell, "Unit", "After") == ["pf-input-broker.service"]
assert "pf-shell-selected.service" in words(broker, "Unit", "Conflicts")

# Gamescope registers on the frozen compositor endpoint. Trusted roles use their schema-pinned
# service users, groups and units; the app/session uid is never a fallback authority.
command = words(broker, "Service", "ExecStart")
assert command[command.index("--compositor-sock") + 1] == "/run/pocketforge/input/compositor.sock"
assert "--session-user" not in command
# The production image must build the broker from the paired runtime head that
# implements this endpoint, not merely exercise that head in the live fixture.
dockerfile = (ROOT / "build/Dockerfile.pf").read_text()
runtime_pins = re.findall(
    r'^\[ "\$\{PF_RUNTIME_SHA\}" = "([0-9a-f]{40})" \]', dockerfile, flags=re.MULTILINE
)
assert runtime_pins == ["8c87d7b60ceb604489b6343355732504a06d743c"], runtime_pins

# The image's systemd predates RestartMode=direct. The supervisor owns exactly one retry,
# so successful session churn cannot consume a global systemd start-rate counter.
assert words(broker, "Service", "Restart") == ["no"]
assert words(broker, "Service", "NotifyAccess") == ["all"]
# systemd must signal only the supervisor on a normal stop. The supervisor forwards one
# TERM and waits for the broker's evdev/socket release; SIGKILL remains group-wide on timeout.
assert words(broker, "Service", "KillMode") == ["mixed"]
assert words(broker, "Unit", "StartLimitIntervalSec") == ["0"]
assert words(broker, "Unit", "StartLimitBurst") == []
assert words(broker, "Unit", "OnFailure") == ["pocketforge-gamescope-fallback.service"]
assert command[:2] == [
    "/usr/lib/pocketforge/pf-input-broker-supervisor",
    "/usr/bin/pf-input-broker",
]

# The exact in-ipc endpoints are created beneath a non-app-traversable parent.
tmpfiles = (ROOT / "rootfs-overlay/usr/lib/tmpfiles.d/pf-input.conf").read_text()
assert "d /run/pocketforge/input 0750 root pf-input -" in tmpfiles
sysusers = (ROOT / "rootfs-overlay/usr/lib/sysusers.d/pf-input.conf").read_text()
for group in ("pf-input", "pf-input-compositor", "pf-input-keyboard", "pf-input-menu"):
    assert f"g {group} -" in sysusers
assert "m gamer pf-input" not in sysusers
assert "m pf-gamescope pf-input-compositor" in sysusers
assert "m pf-ime pf-input-keyboard" in sysusers
# The menu UI/unit belongs to tsp-ihne1.17. Until it lands, this image must not create an
# identity that could accidentally authorize a different process as the system menu.
assert "pf-menu" not in sysusers
assert not (SYSTEMD / "pf-system-menu.service").exists()

print("session input router wiring: PASS owner=session restart_failures=2 app_controls_lifetime=no")
