#!/usr/bin/env python3
"""Offline, fail-closed proof of the F13 owner/authority unit invariants."""

from configparser import ConfigParser
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
UNIT_DIR = ROOT / "rootfs-overlay/etc/systemd/system"


def load(name: str) -> ConfigParser:
    parser = ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    path = UNIT_DIR / name
    if not path.is_file():
        raise AssertionError(f"missing unit: {name}")
    parser.read(path)
    return parser


def words(unit: ConfigParser, section: str, key: str) -> set[str]:
    return set(unit.get(section, key, fallback="").split())


authority = load("pf-session-authorityd.service")
selected = load("pf-shell-selected.service")
foreground = load("pf-foreground@.service")
foreground_target = load("pocketforge-foreground.target")

# The authority is a separately enabled root service. No lifecycle edge from it
# to either writer is allowed; ordering Before= is explicitly not coupling.
for edge in ("Requires", "Wants", "BindsTo", "PartOf", "Conflicts", "Requisite"):
    values = words(authority, "Unit", edge)
    assert not any(v.startswith(("pf-shell-selected", "pf-foreground@")) for v in values), (
        f"authority lifetime coupled by {edge}: {sorted(values)}"
    )
assert authority["Service"]["ExecStart"].startswith(
    "/usr/bin/pf-session-authorityd --state-dir /var/lib/pocketforge/session-authority "
)
assert "--socket /run/pocketforge/session-authority.sock" in authority["Service"]["ExecStart"]

# Every instantiated session joins the foreground slot and waits for its
# activation. Starting one therefore stops the selected owner through the
# target, while the selected-owner drop-in restores that owner when the last
# session releases the target. The direct conflict is retained as additional
# serialization; systemd has no wildcard dependency meaning for an
# uninstantiated @.service.
assert "pocketforge-foreground.target" in words(foreground, "Unit", "Requires")
assert "pocketforge-foreground.target" in words(foreground, "Unit", "After")
assert foreground_target["Unit"].get("StopWhenUnneeded") == "yes"
assert "pf-shell-selected.service" in words(foreground, "Unit", "Conflicts")
owner_dropin = load("pocketforge-foreground.target.d/10-owner-shell.conf")
assert "pf-shell-selected.service" in words(owner_dropin, "Unit", "Conflicts")
assert "pf-shell-selected.service" in words(owner_dropin, "Unit", "After")
assert "pf-shell-selected.service" in words(owner_dropin, "Unit", "OnSuccess")
for name, unit in (("selected", selected), ("foreground", foreground)):
    assert unit["Service"]["ExecStart"].startswith("/usr/bin/pf-shell --fbdev "), name
    assert unit["Service"].get("User") == "gamer", name
assert selected["Service"].get("Restart") == "on-failure"
assert foreground["Service"].get("Restart") == "no"
assert foreground["Service"].get("TimeoutStopSec") == "2s"

builder = (ROOT / "scripts/build-rootfs.sh").read_text()
assert 'PF_PANEL_OWNER="shell"' in builder, "pf-shell is not the selected image owner"
for enabled in ("pf-session-authorityd.service", "pf-shell-selected.service"):
    assert f"multi-user.target.wants/{enabled}" in builder, f"{enabled} not enabled"

print("F13 unit graph: PASS")
print("foreground_writers=pf-shell-selected.service,pf-foreground@.service")
print("foreground_slot=pf-foreground@ Requires+After=pocketforge-foreground.target")
print("writer_exclusion=target-and-session Conflicts=selected-owner")
print("restore_path=target StopWhenUnneeded=yes OnSuccess=pf-shell-selected.service")
print("selected_owner=persistent Restart=on-failure enabled=multi-user.target")
print("authority_lifetime=independent enabled=multi-user.target lifecycle_edges=none")
print("authority_state=/var/lib/pocketforge/session-authority socket=/run/pocketforge/session-authority.sock")
