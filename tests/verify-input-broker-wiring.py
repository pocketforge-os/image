#!/usr/bin/env python3
"""Static contract for default-app input delivery (bd: tsp-f3fm.202.1.4, B4).

Checks the unit wiring the ruling fixed, the cross-file path agreements (descriptor,
acquire socket, SafeReturn socket), the A133-open-only Dockerfile structure, and that
docs/DEFAULT-APPS.md shows the exact directives that ship.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYSTEMD = ROOT / "rootfs-overlay/etc/systemd/system"
APP_UNIT = SYSTEMD / "pf-app@.service"
BROKER_DROPIN = SYSTEMD / "pf-input-broker.service.d/10-app-session.conf"
SHELL_DROPIN = SYSTEMD / "pf-shell-selected.service.d/10-input-broker.conf"
DOC = ROOT / "docs/DEFAULT-APPS.md"
DOCKERFILE = ROOT / "build/Dockerfile.pf"

DESCRIPTOR = "/usr/share/pocketforge/devices/a133/capabilities.toml"
BROKER_SOCK = "/run/pocketforge/input-broker.sock"
AUTHORITY_SOCK = "/run/pocketforge/session-authority.sock"


def directives(text: str) -> list[tuple[str, str, str]]:
    """Ordered (section, key, value) triples; comments and blanks dropped."""
    section = ""
    result = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        key, _, value = line.partition("=")
        result.append((section, key.strip(), value.strip()))
    return result


def values(entries: list[tuple[str, str, str]], section: str, key: str) -> list[str]:
    """Effective list for a key: an empty assignment resets what came before."""
    found: list[str] = []
    for entry_section, entry_key, value in entries:
        if (entry_section, entry_key) == (section, key):
            found = [] if value == "" else found + value.split()
    return found


def directive_text(entries: list[tuple[str, str, str]]) -> str:
    lines, section = [], None
    for entry_section, key, value in entries:
        if entry_section != section:
            if lines:
                lines.append("")
            lines.append(f"[{entry_section}]")
            section = entry_section
        lines.append(f"{key}={value}")
    return "\n".join(lines) + "\n"


app = directives(APP_UNIT.read_text())
broker = directives(BROKER_DROPIN.read_text())
shell = directives(SHELL_DROPIN.read_text())

# pf-app@: the session pulls the broker in and gets the facade environment.
# BindsTo=, not Requires= (bd: tsp-f3fm.202.1.6): Requires= does not stop the app when
# the broker exits by itself mid-session, and the app would keep the panel with no
# Menu intake (real-systemd harness, case (b)).
assert values(app, "Unit", "BindsTo") == ["pf-input-broker.service"], "pf-app@ must be BindsTo= the broker"
assert "pf-input-broker.service" not in values(app, "Unit", "Requires"), "broker belongs in BindsTo=, not Requires="
assert "pf-input-broker.service" in values(app, "Unit", "After"), "pf-app@ must order After the broker"
assert "pocketforge-foreground.target" in values(app, "Unit", "Requires")
environment = values(app, "Service", "Environment")
assert f"PF_DESCRIPTOR={DESCRIPTOR}" in environment, environment
assert f"PF_BROKER_SOCK={BROKER_SOCK}" in environment, environment
assert values(app, "Service", "InaccessiblePaths") == [f"-{AUTHORITY_SOCK}"]
assert not any(section == "Install" for section, _, _ in app), "pf-app@ must stay dormant"

# Broker drop-in: exactly the ruling's directives plus the Condition->Assert fix.
assert broker == [
    ("Unit", "StopWhenUnneeded", "yes"),
    ("Unit", "Wants", "pocketforge-foreground.target"),
    ("Unit", "After", "pocketforge-foreground.target pf-input-decode.service pf-prefsd.service"),
    ("Unit", "Conflicts", "pf-shell-selected.service"),
    ("Unit", "ConditionPathExists", ""),
    ("Unit", "AssertPathExists", "/dev/uinput"),
    ("Service", "Group", "gamer"),
    ("Service", "UMask", "0007"),
    ("Service", "Environment", "PF_PREFSD_SOCK=/run/pocketforge/prefsd.sock"),
    ("Service", "Restart", "no"),
    ("Service", "ExecStart", ""),
    ("Service", "ExecStart", "/usr/bin/pf-input-broker --descriptor " + DESCRIPTOR
     + " --acquire-sock " + BROKER_SOCK + " --source /dev/input/pf-gamepad"
     + " --safe-return-sock " + AUTHORITY_SOCK),
], broker
exec_start = values(broker, "Service", "ExecStart")
flags = dict(zip(exec_start[1::2], exec_start[2::2]))
assert flags["--descriptor"] == DESCRIPTOR == environment[environment.index(f"PF_DESCRIPTOR={DESCRIPTOR}")].split("=", 1)[1]
assert flags["--acquire-sock"] == BROKER_SOCK
assert flags["--safe-return-sock"] == values(app, "Service", "InaccessiblePaths")[0].lstrip("-")
assert shell == [("Unit", "After", "pf-input-broker.service")], shell


def effective_restart(dropin_dir: Path, base: str = "on-failure") -> str:
    """Restart= as systemd resolves it: the runtime unit's value (Restart=on-failure,
    pinned by hash in tests/test-session-authority-systemd.sh), then every drop-in in
    lexical file-name order; the last assignment wins, and an empty one resets it."""
    value = base
    for dropin in sorted(dropin_dir.glob("*.conf"), key=lambda path: path.name):
        for section, key, assigned in directives(dropin.read_text()):
            if (section, key) == ("Service", "Restart"):
                value = assigned or "no"
    return value


# App-session broker must fail ONCE (bd: tsp-f3fm.202.1.6): an auto-restart re-applies
# Conflicts=pf-shell-selected.service on every start and keeps the launcher down.
assert effective_restart(BROKER_DROPIN.parent) == "no", effective_restart(BROKER_DROPIN.parent)
# Negative control in the same run: a later drop-in that restores on-failure must be seen.
import tempfile  # noqa: E402

with tempfile.TemporaryDirectory() as scratch:
    control = Path(scratch)
    (control / BROKER_DROPIN.name).write_text(BROKER_DROPIN.read_text())
    (control / "20-later.conf").write_text("[Service]\nRestart=on-failure\n")
    assert effective_restart(control) == "on-failure", "effective_restart missed a later drop-in"
    (control / "20-later.conf").unlink()
    (control / BROKER_DROPIN.name).write_text(BROKER_DROPIN.read_text().replace("Restart=no\n", ""))
    assert effective_restart(control) == "on-failure", "effective_restart missed the inherited value"

# Never enabled in the overlay (the installer also refuses a *.wants link).
assert not list(SYSTEMD.glob("*.wants/pf-input-broker.service"))

# Doc/unit drift: the doc shows exactly what ships.
doc = DOC.read_text()
for heading in (
    "### R1: the one staged device descriptor",
    "### Input delivery",
    "### Protected Safe Return during app sessions",
    "### Updated units",
    "### Failure modes (amendment)",
    "### Sequence (B1-B6)",
    "### Non-goals (amendment)",
):
    assert heading in doc, f"DEFAULT-APPS.md lacks {heading!r}"
assert "<!-- R4-EVIDENCE -->" not in doc, "DEFAULT-APPS.md still has the R4 evidence placeholder"
ini_blocks = re.findall(r"```ini\n(.*?)```", doc, flags=re.S)
assert APP_UNIT.read_text() in ini_blocks, "DEFAULT-APPS.md pf-app@ block drifted from the unit"
assert directive_text(broker) in ini_blocks, "DEFAULT-APPS.md broker drop-in block drifted"
assert directive_text(shell) in ini_blocks, "DEFAULT-APPS.md shell drop-in block drifted"

# Dockerfile: the open-only descriptor context and the runtime-stage build/install.
dockerfile = DOCKERFILE.read_text()
stages = re.split(r"(?m)^(?=FROM )", dockerfile)
copies = [stage for stage in stages if "COPY --from=platform-inputs-src" in stage]
assert len(copies) == 1 and copies[0].startswith("FROM ${PF_CONTAINER} AS platform-inputs-open\n"), copies
assert dockerfile.count("COPY --from=platform-inputs-src") == 1
for stage in ("platform-inputs-ddk", "platform-inputs-none"):
    assert f"FROM ${{PF_CONTAINER}} AS {stage}\nRUN mkdir -p /out\n" in dockerfile, stage
assert "FROM platform-inputs-${PF_GPU_MODEL} AS platform-inputs\n" in dockerfile
runtime = next(stage for stage in stages if stage.startswith("FROM ${PF_CONTAINER} AS runtime\n"))
for line in (
    "ARG PF_DEVICE_DESCRIPTOR_ID=\n",
    "ARG PF_DEVICE_DESCRIPTOR_SHA256=\n",
    "COPY --from=platform-inputs /out /work/platform-inputs\n",
    "COPY --from=image-src scripts/check-device-descriptor.sh /usr/local/bin/check-device-descriptor\n",
    "COPY --from=image-src scripts/check-libpocketforge.sh /usr/local/bin/check-libpocketforge\n",
    "COPY --from=image-src build/pf-descriptor-validate.rs /work/runtime/crates/pf-input-broker/examples/pf-descriptor-validate.rs\n",
):
    assert line in runtime, line
# The contract check runs for every profile, before the non-a133 early exit.
check_at = runtime.index('DESCRIPTOR="$(check-device-descriptor "${PF_GPU_MODEL:-ddk}" /work/platform-inputs')
not_a133_at = runtime.index('if [ "${PF_SOC}" != "sun50iw10p1" ]; then')
assert check_at < not_a133_at
open_block = runtime[runtime.index('if [ "${PF_GPU_MODEL:-ddk}" = "open" ]; then'):]
for needle in (
    "cargo build --offline --locked --release -p pf-input-broker --example pf-descriptor-validate",
    'target/release/examples/pf-descriptor-validate "${DESCRIPTOR}" "${PF_DEVICE_DESCRIPTOR_ID}"',
    'install -D -m 0644 "${DESCRIPTOR}" "/out/share/devices/${PF_DEVICE_DESCRIPTOR_ID}/capabilities.toml"',
    'cargo build --offline --locked --release --target "${PF_RUNTIME_TARGET}" -p pf-input-broker --bin pf-input-broker',
    "pf-input-broker is dynamically linked (expected static musl)",
    'install -D -m 0755 "${BROKER_BIN}" /out/bin/pf-input-broker',
    "crates/pf-input-broker/systemd/pf-input-broker.service /out/systemd/pf-input-broker.service",
    'CDYLIB="target/aarch64-unknown-linux-gnu/release/libpocketforge.so"',
    'check-libpocketforge "${CDYLIB}" abi/libpocketforge.v1.abi',
    'install -D -m 0644 "${CDYLIB}" /out/lib/libpocketforge.so.1',
):
    assert needle in open_block, needle
# Validation precedes staging: nothing enters /out before its gate passes.
assert open_block.index("pf-descriptor-validate \"${DESCRIPTOR}\"") < open_block.index("/out/share/devices/")
assert open_block.index('check-libpocketforge "${CDYLIB}"') < open_block.index("/out/lib/libpocketforge.so.1")

a523 = (ROOT / "scripts/build-rootfs-a523.sh").read_text()
for forbidden in ("pf-input-broker", "libpocketforge", "platform-inputs", "PF_DEVICE_DESCRIPTOR"):
    assert forbidden not in a523, forbidden

workflow = (ROOT / ".github/workflows/session-authority-systemd.yml").read_text()
assert "rootfs-overlay/etc/systemd/system/pf-input-broker.service.d/**" in workflow
assert "rootfs-overlay/etc/systemd/system/pf-shell-selected.service.d/10-input-broker.conf" in workflow
# The harness runs a fixture shell; an edit to the real unit must re-run it and pass
# the fixture-parity check (bd tsp-3rd3.12).
assert "      - rootfs-overlay/etc/systemd/system/pf-shell-selected.service\n" in workflow
assert "tests/verify-session-authority-shell-fixture.py" in workflow

print("PASS default-app input wiring (units, cross-file paths, broker Restart=no, open-only Dockerfile, doc drift)")
