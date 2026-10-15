#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
publisher="${root}/rootfs-overlay/usr/lib/pocketforge/pf-session-publish"
installer="${root}/scripts/install-gamescope-session.sh"
workflow="${root}/.github/workflows/hermetic-tests.yml"
dockerfile="${root}/build/Dockerfile.pf"
builder="${root}/scripts/build-rootfs.sh"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/gamescope-session-test.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

test -x "${publisher}" || fail "session publisher is missing"
test -x "${installer}" || fail "Gamescope session installer is missing"
grep -F 'tests/test-gamescope-session-supervisor.sh' "${workflow}" >/dev/null \
    || fail "hermetic workflow does not run this test"
grep -F 'install-gamescope-session.sh "${PF_GAMESCOPE_MODE}" "${ROOTFS}"' "${builder}" >/dev/null
test "$(grep -Fc '/work/src/scripts/check-runtime-path-producers.py' "${builder}")" -eq 1 \
    || fail "rootfs build must invoke the shared producer audit exactly once"
grep -F 'COPY --from=image-src build/app-policy-a133-open-g1-v1.json' "${dockerfile}" >/dev/null
grep -F 'g1) POLICY=/work/app-policy-a133-open-g1-v1.json' "${dockerfile}" >/dev/null

# Only g1 images receive the dormant supervisor graph. Neither mode enables it.
mkdir -p "${scratch}/absent" "${scratch}/g1"
"${installer}" not-shipped "${scratch}/absent"
test -z "$(find "${scratch}/absent" -mindepth 1 -print -quit)" \
    || fail "not-shipped mode leaked supervisor artifacts"
"${installer}" g1 "${scratch}/g1"
unit_root="${scratch}/g1/etc/systemd/system"
for unit in pocketforge-gamescope-session.target pocketforge-gamescope.service \
    pocketforge-session-publisher.service pocketforge-gamescope-fallback.service \
    pocketforge-gamescope-resident.service; do
    test -f "${unit_root}/${unit}" || fail "g1 install omitted ${unit}"
done
test -z "$(find "${unit_root}" -path '*.wants/*' -print -quit)" \
    || fail "Gamescope session was enabled by the installer"

owner="${unit_root}/pocketforge-gamescope.service"
drm_systemd_rule="${root}/rootfs-overlay/etc/udev/rules.d/70-pocketforge-drm-systemd.rules"
check_drm_readiness_contract() {
    local unit=$1
    local rule=$2

    grep -Fx 'RestrictAddressFamilies=AF_UNIX AF_NETLINK' "${unit}" >/dev/null \
        || return 1
    ! grep -v '^[[:space:]]*#' "${unit}" \
        | grep -F 'systemd-udev-settle.service' >/dev/null \
        || return 1
    grep -Fx 'SUBSYSTEM=="drm", KERNEL=="card*", TAG+="systemd"' "${rule}" >/dev/null \
        || return 1
}

# Gamescope's libseat/udev session needs netlink and tagged DRM primary nodes.
# The session must not pull in the global udev-settle boot barrier.
check_drm_readiness_contract "${owner}" "${drm_systemd_rule}" \
    || fail "Gamescope DRM readiness contract is incomplete"
cp "${owner}" "${scratch}/owner-missing-netlink.service"
sed -i 's/ AF_NETLINK//' "${scratch}/owner-missing-netlink.service"
if check_drm_readiness_contract "${scratch}/owner-missing-netlink.service" "${drm_systemd_rule}"; then
    fail "DRM readiness check accepted a unit without AF_NETLINK"
fi
cp "${drm_systemd_rule}" "${scratch}/rule-missing-card-tag.rules"
sed -i '/KERNEL=="card\*"/d' "${scratch}/rule-missing-card-tag.rules"
if check_drm_readiness_contract "${owner}" "${scratch}/rule-missing-card-tag.rules"; then
    fail "DRM readiness check accepted untagged primary nodes"
fi
grep -Fx 'Restart=no' "${owner}" >/dev/null
grep -Fx 'StartLimitBurst=1' "${owner}" >/dev/null
grep -Fx 'StartLimitIntervalSec=infinity' "${owner}" >/dev/null
grep -F 'OnFailure=pocketforge-gamescope-fallback.service' "${owner}" >/dev/null
grep -F 'OnSuccess=pocketforge-gamescope-fallback.service' "${owner}" >/dev/null
grep -F 'ExecStartPre=+/usr/bin/systemctl stop pocketforge-boot-animator.service pf-shell-selected.service' "${owner}" >/dev/null
grep -F 'SupplementaryGroups=video render pf-compositor-input' "${owner}" >/dev/null
! grep -E 'SupplementaryGroups=.*(^| )input( |$)' "${owner}" >/dev/null
grep -F -- '--xwayland-count 1' "${owner}" >/dev/null
fallback="${unit_root}/pocketforge-gamescope-fallback.service"
resident="${unit_root}/pocketforge-gamescope-resident.service"
check_resident_hold() {
    local unit=$1

    grep -Fx 'BindsTo=pocketforge-gamescope-session.target' "${unit}" >/dev/null \
        && grep -Fx 'After=pocketforge-gamescope-session.target' "${unit}" >/dev/null \
        && grep -Fx 'Type=oneshot' "${unit}" >/dev/null \
        && grep -Fx 'ExecStart=/usr/bin/true' "${unit}" >/dev/null \
        && grep -Fx 'RemainAfterExit=yes' "${unit}" >/dev/null \
        && ! grep -q '^\[Install\]$' "${unit}"
}
check_resident_hold "${resident}" \
    || fail "resident opt-in is not an explicit BoundBy hold"
cp "${resident}" "${scratch}/resident-without-bind.service"
sed -i '/^BindsTo=/d' "${scratch}/resident-without-bind.service"
if check_resident_hold "${scratch}/resident-without-bind.service"; then
    fail "resident hold check accepted a unit without BindsTo"
fi
if grep -Eq 'pocketforge-gamescope-resident\.service' \
    "${root}/rootfs-overlay/etc/systemd/system/pf-app@.service" \
    "${root}/rootfs-overlay/etc/systemd/system/pf-input-broker.service.d/10-app-session.conf"; then
    fail "an app-session unit starts the resident hold"
fi
check_rearmable_fallback() {
    local unit=$1

    grep -Fx 'Type=oneshot' "${unit}" >/dev/null \
        && ! grep -Eq '^RemainAfterExit=(yes|true)$' "${unit}" \
        && test "$(grep -Fc 'ExecStart=' "${unit}")" -eq 2 \
        && grep -Fx 'ExecStart=/usr/bin/systemctl reset-failed pf-shell-selected.service' \
            "${unit}" >/dev/null \
        && grep -Fx 'ExecStart=/usr/bin/systemctl start --no-block pf-shell-selected.service' \
            "${unit}" >/dev/null \
        && test "$(grep -n '^ExecStart=' "${unit}" | head -n 1 | cut -d: -f2-)" \
            = 'ExecStart=/usr/bin/systemctl reset-failed pf-shell-selected.service'
}
check_rearmable_fallback "${fallback}" \
    || fail "fallback cannot reactivate the selected shell after every session"
cp "${fallback}" "${scratch}/sticky-fallback.service"
printf '\nRemainAfterExit=yes\n' >>"${scratch}/sticky-fallback.service"
if check_rearmable_fallback "${scratch}/sticky-fallback.service"; then
    fail "fallback check accepted a once-per-boot sticky unit"
fi
sed '/reset-failed pf-shell-selected.service/d' "${fallback}" \
    >"${scratch}/fallback-with-stale-start-limit.service"
if check_rearmable_fallback "${scratch}/fallback-with-stale-start-limit.service"; then
    fail "fallback check accepted a stale selected-shell start limit"
fi

rules="${scratch}/g1/etc/udev/rules.d/73-pocketforge-compositor-input.rules"
for property in ID_INPUT_KEYBOARD ID_INPUT_MOUSE ID_INPUT_TOUCHSCREEN; do
    grep -F "ENV{${property}}==\"1\"" "${rules}" >/dev/null \
        || fail "input contract rule omits ${property}"
done
grep -F 'ATTRS{name}=="PocketForge virtual mouse"' "${rules}" >/dev/null
! grep -E 'ID_INPUT_(JOYSTICK|GAMEPAD).*GROUP=' "${rules}" >/dev/null \
    || fail "Gamescope input group admits a controller"

# Verify the installed graph with systemd's parser. Stubs supply only external
# dependencies; the four units under test are the installed production files.
verify_root="${scratch}/g1"
mkdir -p "${verify_root}/usr/bin"
for binary in gamescope systemctl true; do
    printf '#!/bin/sh\nexit 0\n' > "${verify_root}/usr/bin/${binary}"
    chmod 0755 "${verify_root}/usr/bin/${binary}"
done
for service in pf-input-broker.service pf-kbd-layout-env.service pf-open-gpu-gate.service pf-prefsd.service pocketforge-boot-animator.service \
    pf-shell-selected.service systemd-udev-settle.service; do
    printf '[Unit]\nDescription=fixture\n[Service]\nType=oneshot\nExecStart=/usr/bin/systemctl\n' \
        > "${unit_root}/${service}"
done
printf '[Unit]\nDescription=fixture\n' > "${unit_root}/pocketforge-foreground.target"
for target in sysinit.target basic.target shutdown.target; do
    printf '[Unit]\nDescription=fixture\n' > "${unit_root}/${target}"
done
if ! systemd-analyze verify --man=no --root="${verify_root}" \
    pocketforge-gamescope-session.target pocketforge-gamescope.service \
    pocketforge-session-publisher.service pocketforge-gamescope-fallback.service \
    pocketforge-gamescope-resident.service \
    >"${scratch}/systemd-verify.out" 2>&1; then
    cat "${scratch}/systemd-verify.out" >&2
    fail "systemd-analyze rejected the Gamescope session graph"
fi
if test -s "${scratch}/systemd-verify.out"; then
    cat "${scratch}/systemd-verify.out" >&2
    fail "systemd-analyze reported a Gamescope session warning"
fi

# Exercise publication with real filesystem Unix sockets and a controlled
# /proc/net/unix view. The helper owns the atomic generation and projection.
python3 - "${publisher}" "${scratch}" <<'PY'
import json
import os
from pathlib import Path
import socket
import subprocess
import sys

publisher = sys.argv[1]
scratch = Path(sys.argv[2])
sockets = scratch / "sockets"
sockets.mkdir()
wayland = sockets / "gamescope-0"
x11_dir = scratch / "tmp" / ".X11-unix"
x11_dir.mkdir(parents=True)
x11 = x11_dir / "X0"
listeners = []
for path in (wayland, x11):
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(str(path))
    sock.listen(16)
    listeners.append(sock)

proc = scratch / "proc-net-unix"
proc.write_text("Num RefCount Protocol Flags Type St Inode Path\n", encoding="utf-8")
session = scratch / "run" / "pocketforge" / "session"
common = [
    publisher, "publish", "--session", str(session),
    "--wayland", str(wayland), "--x11", str(x11),
    "--proc-net-unix", str(proc), "--gid", str(os.getgid()),
]
subprocess.run(common, check=True)
assert session.is_symlink()
generation = session.resolve()
assert (generation.stat().st_mode & 0o777) == 0o755
assert (generation / "environment").read_text() == (
    "POCKETFORGE_SESSION=/run/pocketforge/session\n"
    "POCKETFORGE_SESSION_GENERATION=1\n"
    "WAYLAND_DISPLAY=wayland-0\n"
)
assert not any(
    line.startswith(("DISPLAY=", "XAUTHORITY="))
    for line in (generation / "environment").read_text().splitlines()
)
assert (generation / "environment").stat().st_mode & 0o777 == 0o444
assert (generation / "capabilities" / "x11" / "environment").read_text() == "DISPLAY=:0\n"
assert (generation / "wayland-0").resolve() == wayland.resolve()

allowed = scratch / "allowed"
subprocess.run([
    publisher, "project-x11", "--session", str(session), "--output", str(allowed),
    "--capability", "x11",
], check=True)
assert (allowed / "environment").read_text() == "DISPLAY=:0\n"
assert (allowed / ".X11-unix" / "X0").resolve() == x11.resolve()
fragment = (allowed / "systemd.conf").read_text()
assert "SupplementaryGroups=pf-session" in fragment
assert "BindPaths=/run/pocketforge/session/capabilities/x11/X0:/tmp/.X11-unix/X0" in fragment
assert "EnvironmentFile=/run/pocketforge/session/capabilities/x11/environment" in fragment

denied = scratch / "denied"
subprocess.run([
    publisher, "project-x11", "--session", str(session), "--output", str(denied),
    "--capability", "audio",
], check=True)
assert not denied.exists()

stale_x11 = x11_dir / "X1"
stale_listener = socket.socket(socket.AF_UNIX)
stale_listener.bind(str(stale_x11))
stale_listener.listen(1)
stale_listener.close()
stale = scratch / "stale-x11"
failed = subprocess.run([
    publisher, "publish", "--session", str(stale),
    "--wayland", str(wayland), "--x11", str(stale_x11), "--display", "1",
    "--proc-net-unix", str(proc), "--gid", str(os.getgid()), "--timeout", "0",
], text=True, capture_output=True)
assert failed.returncode != 0
assert "socket_readiness_timeout" in failed.stderr
assert not stale.exists()

refused = scratch / "refused"
proc.write_text(
    "Num RefCount Protocol Flags Type St Inode Path\n"
    "000: 00000002 00000000 00010000 0001 01 1 @/tmp/.X11-unix/X0\n",
    encoding="utf-8",
)
failed = subprocess.run([
    publisher, "publish", "--session", str(refused),
    "--wayland", str(wayland), "--x11", str(x11),
    "--proc-net-unix", str(proc), "--gid", str(os.getgid()),
], text=True, capture_output=True)
assert failed.returncode != 0
assert "abstract_x11_listener" in failed.stderr
assert not refused.exists()

not_ready = scratch / "not-ready"
failed = subprocess.run([
    publisher, "publish", "--session", str(not_ready),
    "--wayland", str(sockets / "missing"), "--x11", str(x11),
    "--proc-net-unix", str(proc), "--gid", str(os.getgid()), "--timeout", "0",
], text=True, capture_output=True)
assert failed.returncode != 0
assert "socket_readiness_timeout" in failed.stderr
assert not not_ready.exists()
for listener in listeners:
    listener.close()
PY

# The producer inventory and audit must agree: required paths pass, deleting a
# producer makes the same invocation fail, and not-shipped has no requirements.
checker="${root}/scripts/check-runtime-path-producers.py"
manifest="${scratch}/g1/usr/share/pocketforge/runtime-path-producers.json"
policy="${root}/build/app-policy-a133-open-g1-v1.json"
python3 - "${root}/rootfs-overlay/usr/share/pocketforge/runtime-path-producers.json" \
    "${manifest}" <<'PY'
import json
import sys

base = json.load(open(sys.argv[1], encoding="utf-8"))["producers"]
g1 = json.load(open(sys.argv[2], encoding="utf-8"))["producers"]
assert set(base) == {
    "/run/pocketforge/input-broker.sock",
    "/run/pocketforge/prefsd.sock",
}
assert set(g1) == {
    "/run/pocketforge/input-broker.sock",
    "/run/pocketforge/prefsd.sock",
    "/run/pocketforge/session/environment",
    "/run/pocketforge/session/wayland-0",
    "/run/pocketforge/session/capabilities/x11/environment",
    "/run/pocketforge/session/capabilities/x11/X0",
}
PY
"${checker}" --root "${scratch}/g1" --inventory "${policy}" --producers "${manifest}"
cp "${manifest}" "${scratch}/missing-producer.json"
python3 - "${scratch}/missing-producer.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
del data["producers"]["/run/pocketforge/session/capabilities/x11/X0"]
open(path, "w", encoding="utf-8").write(json.dumps(data))
PY
if "${checker}" --root "${scratch}/g1" --inventory "${policy}" \
    --producers "${scratch}/missing-producer.json" >"${scratch}/negative.out" 2>&1; then
    fail "producer audit accepted a missing required producer"
fi
grep -F '/run/pocketforge/session/capabilities/x11/X0' "${scratch}/negative.out" >/dev/null

echo 'PASS: dormant Gamescope session supervisor, atomic producer, scoped X11, input contract and producer audit'
