#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
systemd_root="${root}/rootfs-overlay/etc/systemd/system"
app="${systemd_root}/pf-app@.service"
publisher="${root}/rootfs-overlay/usr/lib/pocketforge/pf-session-publish"
publisher_unit="${systemd_root}/pocketforge-session-publisher.service"
gamescope_unit="${systemd_root}/pocketforge-gamescope.service"
steam_policy="${root}/build/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf"
broker="${systemd_root}/pf-input-broker.service.d/10-app-session.conf"
fallback="${systemd_root}/pocketforge-gamescope-fallback.service"
resident="${systemd_root}/pocketforge-gamescope-resident.service"
renderer="${root}/scripts/render-app-runtime-root.py"
take_panel="${root}/rootfs-overlay/usr/bin/pf-take-panel"
workflow="${root}/.github/workflows/hermetic-tests.yml"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-app-session-graph.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -F 'tests/test-pf-app-session-graph.sh' "${workflow}" >/dev/null \
    || fail "hermetic workflow does not run the pf-app session graph test"

# Exercise the producer rather than copying its expected text. The validator's
# negative controls distinguish the original relative Wayland name, a session
# record that overrides the private runtime directory, a shared runtime root,
# and a compositor socket outside the app-visible publication.
python3 - "${publisher}" "${publisher_unit}" "${gamescope_unit}" "${app}" \
    "${steam_policy}" "${scratch}" <<'PY'
import argparse
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import os
from pathlib import Path
import socket
import stat
import sys


def directives(text):
    section = ""
    parsed = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        key, separator, value = line.partition("=")
        assert separator, raw
        parsed.setdefault((section, key), []).append(value)
    return parsed


def check_contract(environment, app_text, publisher_text, gamescope_text):
    values = dict(line.split("=", 1) for line in environment.splitlines())
    app = directives(app_text)
    publisher = directives(publisher_text)
    gamescope = directives(gamescope_text)
    assert values["WAYLAND_DISPLAY"] == "/run/pocketforge/session/wayland-0", values
    assert "XDG_RUNTIME_DIR" not in values, values
    assert app[("Service", "RuntimeDirectory")] == ["pf-app/%i"]
    assert app[("Service", "RuntimeDirectoryMode")] == ["0700"]
    assert "XDG_RUNTIME_DIR=/run/pf-app/%i" in app[("Service", "Environment")]
    assert any(
        "/run/pf-app/%i" in row.split()
        for row in app[("Service", "ReadWritePaths")]
    )
    command = publisher[("Service", "ExecStart")]
    assert len(command) == 1
    assert "--wayland /run/pocketforge/gamescope/gamescope-0" in command[0]
    assert gamescope[("Service", "RuntimeDirectory")] == ["pocketforge/gamescope"]
    assert gamescope[("Service", "RuntimeDirectoryMode")] == ["0751"]


def rejected(*args):
    try:
        check_contract(*args)
    except (AssertionError, KeyError, ValueError):
        return
    raise AssertionError("invalid session/runtime contract was accepted")


publisher_path, publisher_unit_path, gamescope_path, app_path, steam_path, scratch = (
    Path(value) for value in sys.argv[1:]
)
loader = SourceFileLoader("pf_session_publish", str(publisher_path))
spec = spec_from_loader(loader.name, loader)
module = module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

runtime = scratch / "run"
runtime.mkdir()
wayland_path = runtime / "gamescope-0"
x11_path = runtime / "X0"
wayland = socket.socket(socket.AF_UNIX)
x11 = socket.socket(socket.AF_UNIX)
wayland.bind(str(wayland_path))
x11.bind(str(x11_path))
wayland.listen()
x11.listen()
proc_net_unix = scratch / "proc-net-unix"
proc_net_unix.write_text("", encoding="utf-8")
session = runtime / "session"
x11_environment = runtime / "x11-environment"
module.publish(argparse.Namespace(
    session=session,
    wayland=wayland_path,
    x11=x11_path,
    x11_environment=x11_environment,
    display=0,
    timeout=0.5,
    proc_net_unix=proc_net_unix,
    gid=os.getgid(),
    group=None,
))

environment = (session / "environment").read_text(encoding="utf-8")
app_text = app_path.read_text(encoding="utf-8")
publisher_text = publisher_unit_path.read_text(encoding="utf-8")
gamescope_text = gamescope_path.read_text(encoding="utf-8")
check_contract(environment, app_text, publisher_text, gamescope_text)

alias = session / "wayland-0"
assert alias.is_symlink()
assert alias.resolve(strict=True) == wayland_path
assert stat.S_ISSOCK(alias.stat().st_mode)
assert stat.S_IMODE(wayland_path.stat().st_mode) == 0o660
assert x11_environment.read_text(encoding="utf-8") == "DISPLAY=:0\n"
steam = directives(steam_path.read_text(encoding="utf-8"))
assert "/run/pocketforge/x11/.X11-unix/X0:/tmp/.X11-unix/X0" in steam[("Service", "BindPaths")]

rejected(environment.replace("/run/pocketforge/session/wayland-0", "wayland-0"),
         app_text, publisher_text, gamescope_text)
rejected(environment + "XDG_RUNTIME_DIR=/run/pocketforge/session\n",
         app_text, publisher_text, gamescope_text)
rejected(environment, app_text.replace("pf-app/%i", "pf-app/shared"),
         publisher_text, gamescope_text)
rejected(environment, app_text.replace("RuntimeDirectoryMode=0700", "RuntimeDirectoryMode=0750"),
         publisher_text, gamescope_text)
rejected(environment, app_text,
         publisher_text.replace("/run/pocketforge/gamescope/gamescope-0",
                                "/run/pocketforge/private/gamescope-0"),
         gamescope_text)
PY

# Validate the production directives, then prove that the same validator rejects
# the former per-app graph and a partially converted session-owner graph.
python3 - "${app}" "${broker}" <<'PY'
from pathlib import Path
import sys


def directives(text: str) -> dict[tuple[str, str], list[str]]:
    section = ""
    result: dict[tuple[str, str], list[str]] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        key, sep, value = line.partition("=")
        assert sep, raw
        result.setdefault((section, key), []).append(value)
    return result


def words(parsed: dict[tuple[str, str], list[str]], section: str, key: str) -> list[str]:
    values: list[str] = []
    for value in parsed.get((section, key), []):
        values = [] if not value else values + value.split()
    return values


def validate(app_text: str, broker_text: str) -> None:
    app = directives(app_text)
    broker = directives(broker_text)
    session = "pocketforge-gamescope-session.target"
    foreground = "pocketforge-foreground.target"

    assert words(app, "Unit", "Requires") == [session]
    assert words(app, "Unit", "PartOf") == [session]
    assert session in words(app, "Unit", "After")
    assert foreground not in words(app, "Unit", "Requires")
    assert foreground not in words(app, "Unit", "After")
    assert ("Unit", "ConditionPathExists") not in app
    assert app.get(("Service", "ExecStartPre")) == [
        "/usr/bin/test -S /run/pocketforge/session/wayland-0"
    ]
    assert app.get(("Service", "EnvironmentFile")) == [
        "/run/pocketforge/session/environment"
    ]
    assert words(app, "Service", "SupplementaryGroups") == ["pf-session"]

    assert words(broker, "Unit", "PartOf") == [session]
    assert words(broker, "Unit", "Wants") == []
    assert words(broker, "Unit", "After") == [
        "pf-input-decode.service", "pf-prefsd.service"
    ]
    assert words(broker, "Unit", "OnFailure") == [
        "pocketforge-gamescope-fallback.service"
    ]
    assert foreground not in words(broker, "Unit", "Wants")
    assert foreground not in words(broker, "Unit", "After")
    assert ("Unit", "AssertPathExists") not in broker
    assert broker.get(("Service", "ExecStartPre")) == [
        "/usr/bin/test -e /dev/uinput"
    ]


app_text = Path(sys.argv[1]).read_text(encoding="utf-8")
broker_text = Path(sys.argv[2]).read_text(encoding="utf-8")
validate(app_text, broker_text)

controls = {
    "app-old-foreground-edge": app_text.replace(
        "Requires=pocketforge-gamescope-session.target",
        "Requires=pocketforge-foreground.target",
    ),
    "broker-old-foreground-edge": broker_text.replace(
        "PartOf=pocketforge-gamescope-session.target",
        "PartOf=pocketforge-foreground.target",
    ),
    "broker-old-app-owned-edge": broker_text.replace(
        "PartOf=pocketforge-gamescope-session.target",
        "Wants=pocketforge-gamescope-session.target\nAfter=pocketforge-gamescope-session.target",
    ),
    "broker-missing-failure-fallback": broker_text.replace(
        "OnFailure=pocketforge-gamescope-fallback.service\n", ""
    ),
    "broker-missing-uinput-precheck": broker_text.replace(
        "ExecStartPre=/usr/bin/test -e /dev/uinput\n", ""
    ),
    "app-missing-session-stop-edge": app_text.replace(
        "PartOf=pocketforge-gamescope-session.target\n", ""
    ),
}
for name, candidate in controls.items():
    try:
        validate(candidate if name.startswith("app-") else app_text,
                 candidate if name.startswith("broker-") else broker_text)
    except AssertionError:
        continue
    raise AssertionError(f"negative control was accepted: {name}")
PY

python3 - "${resident}" "${app}" "${broker}" <<'PY'
from pathlib import Path
import sys

resident, app, broker = (Path(path).read_text(encoding="utf-8") for path in sys.argv[1:])
required = {
    "BindsTo=pocketforge-gamescope-session.target",
    "Before=pocketforge-gamescope-session.target",
    "Type=oneshot",
    "ExecStart=/usr/bin/true",
    "RemainAfterExit=yes",
}
lines = {line.strip() for line in resident.splitlines()}
assert required <= lines
assert "After=pocketforge-gamescope-session.target" not in lines
assert "[Install]" not in lines
assert "pocketforge-gamescope-resident.service" not in app
assert "pocketforge-gamescope-resident.service" not in broker

without_bind = resident.replace("BindsTo=pocketforge-gamescope-session.target\n", "")
assert "BindsTo=pocketforge-gamescope-session.target" not in {
    line.strip() for line in without_bind.splitlines()
}
after_target = resident.replace(
    "Before=pocketforge-gamescope-session.target\n",
    "After=pocketforge-gamescope-session.target\n",
)
assert "Before=pocketforge-gamescope-session.target" not in {
    line.strip() for line in after_target.splitlines()
}
PY

# Every terminal path below releases the session target, whose PartOf= edge
# stops Gamescope. Its OnSuccess=/OnFailure= fallback must be re-armable; a
# RemainAfterExit oneshot handles only the first app session in a boot.
python3 - "${fallback}" <<'PY'
from pathlib import Path
import sys


def reusable(text: str) -> bool:
    lines = [line.strip() for line in text.splitlines()]
    return (
        "Type=oneshot" in lines
        and "ExecStart=/usr/bin/systemctl reset-failed pf-shell-selected.service" in lines
        and "ExecStart=/usr/bin/systemctl start --no-block pf-shell-selected.service" in lines
        and lines.index("ExecStart=/usr/bin/systemctl reset-failed pf-shell-selected.service")
        < lines.index("ExecStart=/usr/bin/systemctl start --no-block pf-shell-selected.service")
        and not any(line in ("RemainAfterExit=yes", "RemainAfterExit=true") for line in lines)
    )


production = Path(sys.argv[1]).read_text(encoding="utf-8")
assert reusable(production)
assert not reusable(production + "\nRemainAfterExit=yes\n")
assert not reusable(production.replace(
    "ExecStart=/usr/bin/systemctl reset-failed pf-shell-selected.service\n", ""
))
PY

# The runtime-root extension resets inherited groups before adding its compiled
# capability groups. Preserve only the session transport group at that reset;
# x11 remains a later, manifest-derived projection rather than an ambient group.
grep -Fx '        "SupplementaryGroups=pf-session",' "${renderer}" >/dev/null \
    || fail "runtime-root exact instances do not preserve pf-session"

# fb0 remains reachable only through the explicit manual/bench path.
grep -F -- '--property=Requires=pocketforge-foreground.target' "${take_panel}" >/dev/null
grep -F -- '--property=After=pocketforge-foreground.target' "${take_panel}" >/dev/null
if grep -F 'pocketforge-gamescope-session.target' "${take_panel}" >/dev/null; then
    fail "pf-take-panel was coupled to the shipping compositor path"
fi

# Parse and order the real production graph with systemd. Only external units
# and executables are fixtures; the app, broker drop-in and supervisor units are
# the bytes that ship.
verify="${scratch}/root"
units="${verify}/etc/systemd/system"
mkdir -p "${units}/pf-input-broker.service.d" "${verify}/usr/bin" \
    "${verify}/usr/lib/pocketforge"
for unit in \
    pf-app@.service \
    pocketforge-gamescope-session.target \
    pocketforge-gamescope.service \
    pocketforge-gamescope-x11-authorize.service \
    pocketforge-session-publisher.service \
    pocketforge-gamescope-fallback.service \
    pocketforge-gamescope-resident.service; do
    cp "${systemd_root}/${unit}" "${units}/${unit}"
done
cp "${broker}" "${units}/pf-input-broker.service.d/10-app-session.conf"
cat >"${units}/pf-input-broker.service" <<'EOF'
[Unit]
Description=fixture input broker
[Service]
Type=notify
ExecStart=/usr/bin/pf-input-broker
EOF
for service in pf-prefsd.service pf-input-decode.service pf-open-gpu-gate.service \
    pocketforge-boot-animator.service pf-shell-selected.service systemd-udev-settle.service; do
    printf '[Unit]\nDescription=fixture\n[Service]\nType=oneshot\nExecStart=/usr/bin/systemctl\n' \
        >"${units}/${service}"
done
printf '[Unit]\nDescription=fixture\n' >"${units}/pocketforge-foreground.target"
for target in sysinit.target basic.target shutdown.target; do
    printf '[Unit]\nDescription=fixture\n' >"${units}/${target}"
done
for binary in pf-app-launch pf-input-broker gamescope systemctl test true; do
    printf '#!/bin/sh\nexit 0\n' >"${verify}/usr/bin/${binary}"
    chmod 0755 "${verify}/usr/bin/${binary}"
done
cp "${root}/rootfs-overlay/usr/lib/pocketforge/pf-session-publish" \
    "${verify}/usr/lib/pocketforge/pf-session-publish"
cp "${root}/rootfs-overlay/usr/lib/pocketforge/pf-gamescope-kms-select" \
    "${verify}/usr/lib/pocketforge/pf-gamescope-kms-select"
cp "${root}/rootfs-overlay/usr/lib/pocketforge/pf-x11-authorize" \
    "${verify}/usr/lib/pocketforge/pf-x11-authorize"
chmod 0755 "${verify}/usr/lib/pocketforge/pf-x11-authorize"

if ! systemd-analyze verify --man=no --root="${verify}" \
    pf-app@org.pocketforge.fixture.service \
    pocketforge-gamescope-session.target \
    pocketforge-gamescope.service \
    pocketforge-gamescope-x11-authorize.service \
    pocketforge-session-publisher.service \
    pocketforge-gamescope-fallback.service \
    pocketforge-gamescope-resident.service \
    >"${scratch}/verify.out" 2>&1; then
    cat "${scratch}/verify.out" >&2
    fail "systemd-analyze rejected the pf-app Gamescope graph"
fi
if test -s "${scratch}/verify.out"; then
    cat "${scratch}/verify.out" >&2
    fail "systemd-analyze reported a pf-app Gamescope graph warning"
fi

echo 'PASS: pf-app and input broker consume the Gamescope session; fb0 stays bench-only'
