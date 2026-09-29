#!/usr/bin/env python3
"""Parity of the session-authority harness's pf-shell-selected fixture with the
real unit (bd tsp-3rd3.12, on the tsp-f3fm B4 harness).

tests/test-session-authority-systemd.sh proves the shell/broker grab order
(`grab_sequence ... violations=0 ordering_cycles=0`). It runs the real broker
unit and drop-ins, but a FIXTURE pf-shell-selected.service with a fake
ExecStart, because the real unit's executable and devices do not exist in the
container. Without this check, an edit to the real unit's relationships could
change the grab order, and the harness would neither re-run nor fail.

This check FAILS when any of the following holds:
  - The real unit and the fixture differ on any dependency edge whose other end
    is a unit the harness runs. The harness units are read from the
    Containerfile, so a newly modelled unit is covered automatically. The
    shell's drop-in (10-input-broker.conf) is installed verbatim on both sides.
  - The real unit names, in any edge or Exec* command, a unit that the harness
    does not run and that is not in NOT_MODELLED below with its reason. A new
    edge must be modelled in the fixture, or listed here in review.
  - DefaultDependencies= or Type= differ. Type sets where the start job
    completes, and that orders the next jobs.
  - The fixture names a unit outside the harness.
Other [Service] differences are deliberate: the fake ExecStart, and no
User=/device waits. Every ExecStartPre= runs inside the start job, after the
start job has been ordered behind the broker's stop, so it can delay the grab
but never reorder it. A command that names a harness unit is refused above.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SYSTEMD = ROOT / "rootfs-overlay/etc/systemd/system"
FIXTURES = ROOT / "tests/session-authority-systemd"
DEP_KEYS = ("Requires", "Requisite", "Wants", "BindsTo", "PartOf", "Upholds", "Conflicts",
            "Before", "After", "OnSuccess", "OnFailure", "PropagatesStopTo",
            "StopPropagatedFrom", "PropagatesReloadTo", "ReloadPropagatedFrom",
            "JoinsNamespaceOf", "Slice")
EXEC_KEYS = ("ExecCondition", "ExecStartPre", "ExecStart", "ExecStartPost", "ExecReload",
             "ExecStop", "ExecStopPost")
UNIT_NAME = re.compile(r"[A-Za-z0-9:_.@\\-]+\.(?:service|target|device|path|mount|socket|slice|timer|scope)")
# Units the real unit names that the harness deliberately does not run.
NOT_MODELLED = {
    "dev-fb0.device": "the harness's /dev/fb0 is a tmpfiles regular file; no device unit",
    "pf-input-decode.service": "the gamepad decoder; the harness feeds input through the fake broker",
    "pf-prefsd.service": "preference daemon; no part in the grab order",
    "pocketforge-boot-animator.service": "boot splash, stopped by ExecStartPre before ExecStart; "
                                         "it never grabs input (bd tsp-3rd3.12)",
    "pocketforge-menu.service": "an alternative panel owner, never enabled with the shell",
    "pocketforge-placeholder.service": "an alternative panel owner, never enabled with the shell",
    "shutdown.target": "shutdown ordering (the fixture gets it from DefaultDependencies=yes)",
}


def fail(message: str) -> None:
    raise SystemExit(f"session-authority shell-fixture parity: FAIL: {message}")


def directives(path: Path) -> dict[str, list[str]]:
    """{key: [values in file order]} over all sections; comments skipped."""
    out: dict[str, list[str]] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";", "[")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        out.setdefault(key.strip(), []).append(value.strip())
    return out


def harness_units(containerfile: Path) -> set[str]:
    units = set()
    for match in re.finditer(r"^COPY\s+\S+\s+/etc/systemd/system/(\S+)$", containerfile.read_text(),
                             flags=re.MULTILINE):
        name = match.group(1).split("/")[0]
        units.add(name[:-2] if name.endswith(".d") else name)
    return units


def in_harness(name: str, harness: set[str]) -> bool:
    if name in harness:
        return True
    template = re.sub(r"@[^.]*\.", "@.", name)      # pf-app@x.service -> pf-app@.service
    return template in harness


def edges(values: dict[str, list[str]]) -> dict[str, set[str]]:
    return {key: {w for v in values.get(key, []) for w in v.split()} for key in DEP_KEYS}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--real", type=Path, default=SYSTEMD / "pf-shell-selected.service")
    parser.add_argument("--fixture", type=Path, default=FIXTURES / "pf-shell-selected.service")
    parser.add_argument("--containerfile", type=Path, default=FIXTURES / "Containerfile")
    args = parser.parse_args()

    harness = harness_units(args.containerfile)
    if "pf-shell-selected.service" not in harness or "pf-input-broker.service" not in harness:
        fail(f"cannot read the harness unit set from {args.containerfile}: {sorted(harness)}")
    real, fixture = directives(args.real), directives(args.fixture)
    real_edges, fixture_edges = edges(real), edges(fixture)

    named = {w for ws in real_edges.values() for w in ws}
    for key in EXEC_KEYS:
        for command in real.get(key, []):
            for name in UNIT_NAME.findall(command):
                if in_harness(name, harness):
                    fail(f"real {key}= acts on harness unit {name}; model it in the fixture: {command}")
                named.add(name)
    unknown = sorted(n for n in named if not in_harness(n, harness) and n not in NOT_MODELLED)
    if unknown:
        fail(f"real unit names units the harness neither runs nor lists as NOT_MODELLED: {unknown}")

    modelled = 0
    for key in DEP_KEYS:
        want = {n for n in real_edges[key] if in_harness(n, harness)}
        have = {n for n in fixture_edges[key] if in_harness(n, harness)}
        if want != have:
            fail(f"{key}= toward harness units differs: real {sorted(want)} fixture {sorted(have)}")
        stray = sorted(n for n in fixture_edges[key] if not in_harness(n, harness))
        if stray:
            fail(f"fixture {key}= names units outside the harness: {stray}")
        modelled += len(want)
    for key, default in (("DefaultDependencies", "yes"), ("Type", "simple")):
        r, f = real.get(key, [default])[-1], fixture.get(key, [default])[-1]
        if r != f:
            fail(f"{key}= differs: real {r} fixture {f}")

    not_modelled = sorted(n for n in named if n in NOT_MODELLED)
    print("session-authority shell-fixture parity: PASS "
          f"harness_units={len(harness)} edges_to_harness_units={modelled} "
          f"not_modelled={','.join(not_modelled)} type={real.get('Type', ['simple'])[-1]}")


if __name__ == "__main__":
    main()
