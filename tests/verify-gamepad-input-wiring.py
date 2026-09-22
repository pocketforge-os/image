#!/usr/bin/env python3
"""Fail-closed proof of the decoder gamepad's udev and shell-unit wiring."""

from configparser import ConfigParser
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
UNIT_DIR = ROOT / "rootfs-overlay/etc/systemd/system"
RULE = ROOT / "rootfs-overlay/etc/udev/rules.d/72-pocketforge-input.rules"
GAMEPAD = "/dev/input/pf-gamepad"


def load_unit(name: str) -> ConfigParser:
    unit = ConfigParser(interpolation=None, strict=False)
    unit.optionxform = str
    unit.read(UNIT_DIR / name)
    return unit


for name in ("pf-shell-selected.service", "pf-foreground@.service"):
    unit = load_unit(name)
    command = unit["Service"]["ExecStart"]
    assert f"--input {GAMEPAD}" in command, f"{name}: unstable input path: {command}"
    assert "/dev/input/event" not in command, f"{name}: numbered evdev node remains"
    wait = unit["Service"].get("ExecStartPre", "")
    assert GAMEPAD in wait and "sleep 0.2" in wait and '"$i" -lt 20' in wait, (
        f"{name}: expected bounded four-second gamepad wait"
    )
    assert wait.endswith("exit 0'"), f"{name}: gamepad wait must be non-fatal"
    dependencies = " ".join(
        unit["Unit"].get(edge, "")
        for edge in ("After", "Before", "Wants", "Requires", "BindsTo", "Requisite")
    )
    assert "pf-gamepad.device" not in dependencies, f"{name}: forbidden device dependency"
    assert not re.search(r"dev-input-pf\\x2dgamepad\\.device", dependencies), (
        f"{name}: forbidden escaped device dependency"
    )

foreground = load_unit("pf-foreground@.service")
assert "pf-input-decode.service" in foreground["Unit"].get("After", "").split()

rule = RULE.read_text()
expected_rule = (
    'SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="TRIMUI Player1", '
    'ATTRS{id/vendor}=="045e", ATTRS{id/product}=="028e", '
    'SYMLINK+="input/pf-gamepad"'
)
assert rule.splitlines().count(expected_rule) == 1, "udev gamepad identity rule drifted"

builder = (ROOT / "scripts/build-rootfs.sh").read_text()
assert builder.count("72-pocketforge-input.rules") == 2, "udev rule is not installed exactly once"

print("gamepad-input-wiring=PASS")
print("gamepad-node=/dev/input/pf-gamepad identity=TRIMUI_Player1,045e:028e")
print("shell-units=pf-shell-selected.service,pf-foreground@.service")
print("device-unit-dependency=absent bounded-wait=4s,non-fatal")
