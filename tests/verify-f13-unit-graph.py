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


selected = load("pf-shell-selected.service")
foreground = load("pf-foreground@.service")
foreground_target = load("pocketforge-foreground.target")

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

# Boot handoff from the animator (bd tsp-3rd3.12). The animator
# (basic.target.wants) and every boot-enabled owner (multi-user.target.wants)
# share ONE boot transaction. An owner-side Conflicts= on the animator puts a
# conflicting stop job into that transaction, and systemd deletes the
# animator's start. So an owner orders After= the animator, never pulls it in or
# conflicts with it, and stops it synchronously as its LAST ExecStartPre. The
# RuntimeDirectory marker lets the animator yield (a condition skip) while an
# owner is live. The behaviour itself is proven by
# tests/test-panel-owner-boot-handoff.py; this pins the shape.
ANIMATOR = "pocketforge-boot-animator.service"
STOP_ANIMATOR = f"-+/bin/systemctl stop {ANIMATOR}"


def lines(name: str, key: str) -> list[str]:
    """All values of a (possibly repeated) key; ConfigParser keeps only the last."""
    return [line.split("=", 1)[1] for line in (UNIT_DIR / name).read_text().splitlines()
            if line.startswith(f"{key}=")]


for owner in ("pf-shell-selected.service", "pocketforge-menu.service",
              "pocketforge-placeholder.service"):
    edges = {key: {word for value in lines(owner, key) for word in value.split()}
             for key in ("Conflicts", "After", "Requires", "Requisite", "Wants", "BindsTo",
                         "PartOf", "Upholds")}
    assert ANIMATOR not in edges["Conflicts"], f"{owner}: Conflicts= deletes the animator's boot start"
    assert ANIMATOR in edges["After"], f"{owner}: must start after the animator's start"
    for key in ("Requires", "Requisite", "Wants", "BindsTo", "PartOf", "Upholds"):
        assert ANIMATOR not in edges[key], f"{owner}: {key}= couples the owner to the animator"
    pre = lines(owner, "ExecStartPre")
    assert pre and pre[-1] == STOP_ANIMATOR, f"{owner}: last ExecStartPre must be {STOP_ANIMATOR!r}: {pre}"
    assert lines(owner, "RuntimeDirectory") == ["pocketforge-panel-owner/%N"], owner
animator_guard = lines(ANIMATOR, "ConditionDirectoryNotEmpty")
assert animator_guard == ["!/run/pocketforge-panel-owner"], animator_guard

builder = (ROOT / "scripts/build-rootfs.sh").read_text()
assert 'PF_PANEL_OWNER="shell"' in builder, "pf-shell is not the selected image owner"
assert '"${RUNTIME_DIR}/systemd/pf-session-authorityd.service"' in builder
for enabled in ("pf-session-authorityd.service", "pf-shell-selected.service"):
    assert f"multi-user.target.wants/{enabled}" in builder, f"{enabled} not enabled"

print("F13 unit graph: PASS")
print("foreground_writers=pf-shell-selected.service,pf-foreground@.service")
print("foreground_slot=pf-foreground@ Requires+After=pocketforge-foreground.target")
print("writer_exclusion=target-and-session Conflicts=selected-owner")
print("restore_path=target StopWhenUnneeded=yes OnSuccess=pf-shell-selected.service")
print("selected_owner=persistent Restart=on-failure enabled=multi-user.target")
print("animator_handoff=owners After=animator, no Conflicts=, last ExecStartPre stops it; "
      "animator yields while /run/pocketforge-panel-owner is non-empty")
print("authority_lifetime=independent enabled=multi-user.target lifecycle_edges=none")
print("authority_state=/var/lib/pocketforge/session-authority socket=/run/pocketforge/session-authority.sock")
