#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
systemd_root="${root}/rootfs-overlay/etc/systemd/system"
app="${systemd_root}/pf-app@.service"
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

# Validate the production directives, then prove that the same validator rejects
# each old half-graph. Moving only pf-app or only the broker would ask systemd to
# start both compositor ownership targets, which conflict with each other.
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

    assert words(broker, "Unit", "Wants") == [session]
    assert session in words(broker, "Unit", "After")
    assert foreground not in words(broker, "Unit", "Wants")
    assert foreground not in words(broker, "Unit", "After")


app_text = Path(sys.argv[1]).read_text(encoding="utf-8")
broker_text = Path(sys.argv[2]).read_text(encoding="utf-8")
validate(app_text, broker_text)

controls = {
    "app-old-foreground-edge": app_text.replace(
        "Requires=pocketforge-gamescope-session.target",
        "Requires=pocketforge-foreground.target",
    ),
    "broker-old-foreground-edge": broker_text.replace(
        "Wants=pocketforge-gamescope-session.target",
        "Wants=pocketforge-foreground.target",
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
    "After=pocketforge-gamescope-session.target",
    "Type=oneshot",
    "ExecStart=/usr/bin/true",
    "RemainAfterExit=yes",
}
lines = {line.strip() for line in resident.splitlines()}
assert required <= lines
assert "[Install]" not in lines
assert "pocketforge-gamescope-resident.service" not in app
assert "pocketforge-gamescope-resident.service" not in broker

without_bind = resident.replace("BindsTo=pocketforge-gamescope-session.target\n", "")
assert "BindsTo=pocketforge-gamescope-session.target" not in {
    line.strip() for line in without_bind.splitlines()
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

if ! systemd-analyze verify --man=no --root="${verify}" \
    pf-app@org.pocketforge.fixture.service \
    pocketforge-gamescope-session.target \
    pocketforge-gamescope.service \
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
