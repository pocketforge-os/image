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
    pocketforge-gamescope-x11-authorize.service pocketforge-session-publisher.service \
    pocketforge-gamescope-fallback.service \
    pocketforge-gamescope-resident.service; do
    test -f "${unit_root}/${unit}" || fail "g1 install omitted ${unit}"
done
test -z "$(find "${unit_root}" -path '*.wants/*' -print -quit)" \
    || fail "Gamescope session was enabled by the installer"
cmp "${root}/build/app-policy-a133-open-g1-v1.json" \
    "${scratch}/g1/usr/share/pocketforge/app-policy/org.pocketforge.steamlink.resources.json"
cmp "${root}/build/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf" \
    "${unit_root}/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf"

owner="${unit_root}/pocketforge-gamescope.service"
publisher_unit="${unit_root}/pocketforge-session-publisher.service"
x11_tmpfiles="${scratch}/g1/usr/lib/tmpfiles.d/pocketforge-gamescope-x11.conf"
drm_systemd_rule="${root}/rootfs-overlay/etc/udev/rules.d/70-pocketforge-drm-systemd.rules"

# Xwayland's default uid check is the only authorization primitive provided by
# the pinned wlroots launch path. Keep the compositor owner uid isolated, but
# add exactly the app uid through the X11 server-interpreted local-user ACL.
# There is deliberately no cookie producer or xhost-all grant. Keep the
# negative control in this invocation: an ACL for another uid must fail.
check_xwayland_authorization_contract() {
    local owner_unit=$1
    local publisher_service=$2
    local auth_unit=$3
    local helper=$4

    python3 - "${owner_unit}" "${publisher_service}" "${auth_unit}" \
        "${helper}" <<'PY'
import pathlib
import sys

owner_path, publisher_path, auth_path, helper_path = map(pathlib.Path, sys.argv[1:])
owner = owner_path.read_text(encoding="utf-8")
publisher = publisher_path.read_text(encoding="utf-8")
auth = auth_path.read_text(encoding="utf-8")
if "User=pf-gamescope" not in owner or "Group=pf-gamescope" not in owner:
    raise SystemExit("Gamescope no longer owns the Xwayland server")
if "User=pf-gamescope" not in auth or "Group=pf-gamescope" not in auth:
    raise SystemExit("X11 ACL helper is not confined to the compositor uid")
if "--socket /run/pocketforge/x11/.X11-unix/X0" not in auth:
    raise SystemExit("X11 ACL helper does not target the published socket")
if "--user gamer" not in auth:
    raise SystemExit("X11 ACL helper does not grant only the app uid")
if "SupplementaryGroups=pf-session" not in auth:
    raise SystemExit("X11 ACL helper cannot project the private app socket group")
if "--group pf-session" not in auth or "--mode 0660" not in auth:
    raise SystemExit("X11 ACL helper does not enforce the private socket projection")
if "Type=notify" not in auth or "NotifyAccess=main" not in auth:
    raise SystemExit("X11 ACL helper does not gate publication on initial authorization")
if "--monitor" not in auth or "Restart=on-failure" not in auth:
    raise SystemExit("X11 ACL helper does not re-authorize restarted Xwayland children")
if "RemainAfterExit=yes" in auth:
    raise SystemExit("X11 ACL helper is a one-shot authorization")
if "Requires=pocketforge-gamescope-x11-authorize.service" not in publisher:
    raise SystemExit("publisher does not require X11 authorization")
if "After=pocketforge-gamescope-x11-authorize.service" not in publisher:
    raise SystemExit("publisher can race X11 authorization")
if not helper_path.is_file() or not (helper_path.stat().st_mode & 0o111):
    raise SystemExit("X11 ACL helper is missing or not executable")
xhost_name = "x" + "host"
if xhost_name in helper_path.read_text(encoding="utf-8"):
    raise SystemExit("X11 ACL helper delegates to an unrestricted host tool")
PY
}

authorization_unit="${unit_root}/pocketforge-gamescope-x11-authorize.service"
authorization_helper="${root}/rootfs-overlay/usr/lib/pocketforge/pf-x11-authorize"
check_xwayland_authorization_contract "${owner}" "${publisher_unit}" \
    "${authorization_unit}" "${authorization_helper}" \
    || fail "Xwayland authorization projection contract is incomplete"
cp "${authorization_unit}" "${scratch}/authorization-for-unauthorized-user.service"
sed -i 's/--user gamer/--user unauthorized/' \
    "${scratch}/authorization-for-unauthorized-user.service"
if check_xwayland_authorization_contract "${owner}" \
    "${publisher_unit}" "${scratch}/authorization-for-unauthorized-user.service" \
    "${authorization_helper}"; then
    fail "authorization check accepted an ACL for an unauthorized uid"
fi

check_xwayland_write_contract() {
    local owner_unit=$1
    local publisher_service=$2
    local tmpfiles_config=$3

    python3 - "${owner_unit}" "${publisher_service}" "${tmpfiles_config}" <<'PY'
import pathlib
import sys

owner_path, publisher_path, tmpfiles_path = map(pathlib.Path, sys.argv[1:])
try:
    owner = owner_path.read_text(encoding="utf-8").splitlines()
    publisher = publisher_path.read_text(encoding="utf-8").splitlines()
    tmpfiles = tmpfiles_path.read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError):
    raise SystemExit(1)

def values(lines, key):
    prefix = key + "="
    return [line[len(prefix):].split() for line in lines if line.startswith(prefix)]

if values(owner, "ProtectSystem") != [["strict"]]:
    raise SystemExit(1)
if any(value in (["yes"], ["true"]) for value in values(owner, "PrivateTmp")):
    raise SystemExit(1)
if values(owner, "BindPaths") != [["/run/pocketforge/x11:/tmp"]]:
    raise SystemExit(1)
if values(owner, "ReadWritePaths") != [["/run/pocketforge/x11"]]:
    raise SystemExit(1)
if any(path == "/tmp" for row in values(owner, "ReadWritePaths") for path in row):
    raise SystemExit(1)
if values(owner, "RuntimeDirectoryMode") != [["0751"]]:
    raise SystemExit(1)

entries = {tuple(line.split()) for line in tmpfiles if line and not line.startswith("#")}
required = {
    ("d", "/run/pocketforge", "0775", "root", "gamer", "-"),
    ("d", "/run/pocketforge/x11", "1777", "root", "root", "-"),
    ("d", "/run/pocketforge/x11/.X11-unix", "1777", "root", "root", "-"),
    ("d", "/run/pocketforge/x11/policy", "0755", "root", "root", "-"),
}
if not required.issubset(entries):
    raise SystemExit(1)

# Reapplying the exact production rows must converge an old gamer-owned parent
# without changing the root-owned X11 subtree on the second pass.
state = {"/run/pocketforge": ("0755", "gamer", "gamer")}
for _ in range(2):
    for kind, path, mode, owner_name, group_name, _age in entries:
        if kind == "d" and path.startswith("/run/pocketforge"):
            state[path] = (mode, owner_name, group_name)
    if state["/run/pocketforge"] != ("0775", "root", "gamer"):
        raise SystemExit(1)
    if state["/run/pocketforge/x11/policy"] != ("0755", "root", "root"):
        raise SystemExit(1)

# wlroots' fixed namespace paths must resolve to the same host-visible tree
# consumed by the publisher. The display lock is deliberately created at
# runtime with O_EXCL, so only its writable parent is provisioned.
resolved_lock = "/run/pocketforge/x11/.X0-lock"
resolved_socket = "/run/pocketforge/x11/.X11-unix/X0"
if not resolved_lock.startswith("/run/pocketforge/x11/"):
    raise SystemExit(1)
exec_starts = [" ".join(row) for row in values(publisher, "ExecStart")]
if len(exec_starts) != 1 or f"--x11 {resolved_socket}" not in exec_starts[0]:
    raise SystemExit(1)
if "--x11-environment /run/pocketforge/x11/policy/environment" not in exec_starts[0]:
    raise SystemExit(1)
if any("/tmp/.X11-unix" in line for line in publisher):
    raise SystemExit(1)
PY
}

# Gamescope must have writable storage for wlroots' /tmp/.X<N>-lock and
# /tmp/.X11-unix/X<N> without receiving write access to the host's whole /tmp.
check_xwayland_write_contract "${owner}" "${publisher_unit}" "${x11_tmpfiles}" \
    || fail "Gamescope Xwayland write namespace is incomplete"
cp "${x11_tmpfiles}" "${scratch}/x11-without-safe-parent.conf"
sed -i '\#^d /run/pocketforge 0775 root gamer -$#d' \
    "${scratch}/x11-without-safe-parent.conf"
if check_xwayland_write_contract "${owner}" "${publisher_unit}" \
    "${scratch}/x11-without-safe-parent.conf"; then
    fail "Xwayland write check accepted an unsafe runtime parent"
fi
cp "${owner}" "${scratch}/owner-without-x11-bind.service"
sed -i '/^BindPaths=/d' "${scratch}/owner-without-x11-bind.service"
if check_xwayland_write_contract "${scratch}/owner-without-x11-bind.service" \
    "${publisher_unit}" "${x11_tmpfiles}"; then
    fail "Xwayland write check accepted a missing namespace bind"
fi
cp "${owner}" "${scratch}/owner-without-app-traverse.service"
sed -i 's/^RuntimeDirectoryMode=0751$/RuntimeDirectoryMode=0750/' \
    "${scratch}/owner-without-app-traverse.service"
if check_xwayland_write_contract "${scratch}/owner-without-app-traverse.service" \
    "${publisher_unit}" "${x11_tmpfiles}"; then
    fail "Xwayland write check accepted an app-inaccessible runtime directory"
fi
cp "${x11_tmpfiles}" "${scratch}/x11-without-sticky.conf"
sed -i 's#x11/.X11-unix 1777#x11/.X11-unix 0777#' \
    "${scratch}/x11-without-sticky.conf"
if check_xwayland_write_contract "${owner}" "${publisher_unit}" \
    "${scratch}/x11-without-sticky.conf"; then
    fail "Xwayland write check accepted a non-sticky socket directory"
fi
cp "${publisher_unit}" "${scratch}/publisher-private-x11.service"
sed -i 's#/run/pocketforge/x11/.X11-unix/X0#/tmp/.X11-unix/X0#' \
    "${scratch}/publisher-private-x11.service"
if check_xwayland_write_contract "${owner}" \
    "${scratch}/publisher-private-x11.service" "${x11_tmpfiles}"; then
    fail "Xwayland write check accepted a publisher-invisible socket path"
fi
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
        && grep -Fx 'Before=pocketforge-gamescope-session.target' "${unit}" >/dev/null \
        && ! grep -Fx 'After=pocketforge-gamescope-session.target' "${unit}" >/dev/null \
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
cp "${resident}" "${scratch}/resident-after-target.service"
sed -i 's/^Before=/After=/' "${scratch}/resident-after-target.service"
if check_resident_hold "${scratch}/resident-after-target.service"; then
    fail "resident hold check accepted the StopWhenUnneeded startup race"
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
    pocketforge-gamescope-x11-authorize.service pocketforge-session-publisher.service \
    pocketforge-gamescope-fallback.service \
    pocketforge-gamescope-resident.service \
    >"${scratch}/systemd-verify.out" 2>&1; then
    cat "${scratch}/systemd-verify.out" >&2
    fail "systemd-analyze rejected the Gamescope session graph"
fi
if test -s "${scratch}/systemd-verify.out"; then
    cat "${scratch}/systemd-verify.out" >&2
    fail "systemd-analyze reported a Gamescope session warning"
fi

# Exercise the ACL helper's real X11 request shape against a hermetic server
# stub. The positive control must request only localuser:gamer; the negative
# control must refuse another uid before it can connect.
python3 - "${authorization_helper}" "${scratch}/x11-authorize.sock" <<'PY'
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading
import grp
import os

helper = sys.argv[1]
path = Path(sys.argv[2])
seen = []
ready = threading.Event()

def recv_exact(client, size):
    data = bytearray()
    while len(data) < size:
        chunk = client.recv(size - len(data))
        assert chunk
        data.extend(chunk)
    return bytes(data)

def serve():
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(path))
    listener.listen(1)
    ready.set()
    with listener:
        client, _ = listener.accept()
        with client:
            assert recv_exact(client, 12)[0] == ord("l")
            client.sendall(struct.pack("<BBHHH", 1, 0, 11, 0, 0))
            header = recv_exact(client, 8)
            assert header[0] == 109
            request_length = struct.unpack_from("<H", header, 2)[0]
            body = recv_exact(client, request_length * 4 - 8)
            address_length = struct.unpack_from("<H", header, 6)[0]
            seen.append((header[4], body[:address_length]))
            assert recv_exact(client, 4) == struct.pack("<BBH", 43, 0, 1)
            client.sendall(b"\1" + b"\0" * 31)

thread = threading.Thread(target=serve)
thread.start()
assert ready.wait(2)
positive = subprocess.run(
    [
        helper, "--socket", str(path), "--user", "gamer",
        "--group", grp.getgrgid(os.getgid()).gr_name,
        "--mode", "0660", "--timeout", "2",
    ],
    text=True, capture_output=True,
)
thread.join(2)
assert positive.returncode == 0, positive.stderr
assert seen == [(5, b"localuser\0gamer")]
assert path.stat().st_gid == os.getgid()
assert path.stat().st_mode & 0o777 == 0o660
negative = subprocess.run(
    [
        helper, "--socket", str(path), "--user", "unauthorized",
        "--group", grp.getgrgid(os.getgid()).gr_name,
        "--mode", "0660", "--timeout", "0",
    ],
    text=True, capture_output=True,
)
assert negative.returncode != 0
assert "unsupported_user" in negative.stderr
assert not negative.stdout
public_mode = subprocess.run(
    [
        helper, "--socket", str(path), "--user", "gamer",
        "--group", grp.getgrgid(os.getgid()).gr_name,
        "--mode", "0666", "--timeout", "0",
    ],
    text=True, capture_output=True,
)
assert public_mode.returncode != 0
assert "unsupported_mode" in public_mode.stderr
assert not public_mode.stdout
PY

# The Xwayland child can be replaced while Gamescope keeps X0 published. The
# monitor must gate readiness on the first ACL and repeat the request for the
# replacement socket.
python3 - "${authorization_helper}" "${scratch}" <<'PY'
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import threading
import time
import grp

helper = sys.argv[1]
scratch = Path(sys.argv[2])
path = scratch / "x11-monitor.sock"
notify_path = scratch / "x11-notify.sock"
ready = threading.Event()
accepted = []

def serve_x11() -> None:
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(str(path))
    listener.listen(1)
    initial_inode = path.stat().st_ino
    ready.set()
    for generation in range(2):
        client, _ = listener.accept()
        with client:
            setup = client.recv(12)
            assert len(setup) == 12 and setup[0] == ord("l")
            client.sendall(struct.pack("<BBHHH", 1, 0, 11, 0, 0))
            header = client.recv(8)
            assert len(header) == 8 and header[0] == 109
            body = client.recv(struct.unpack_from("<H", header, 2)[0] * 4 - 8)
            accepted.append((header[4], body))
            assert path.stat().st_gid == os.getgid()
            assert path.stat().st_mode & 0o777 == 0o660
            assert client.recv(4) == struct.pack("<BBH", 43, 0, 1)
            client.sendall(b"\1" + b"\0" * 31)
        if generation == 0:
            path.chmod(0o777)
            time.sleep(0.2)
    assert path.stat().st_ino == initial_inode
    listener.close()
    path.unlink()

notify = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
notify.bind(str(notify_path))
environment = dict(os.environ, NOTIFY_SOCKET=str(notify_path))
server = threading.Thread(target=serve_x11, daemon=True)
server.start()
assert ready.wait(2)
process = subprocess.Popen(
    [
        helper, "--socket", str(path), "--user", "gamer",
        "--group", grp.getgrgid(os.getgid()).gr_name,
        "--mode", "0660", "--timeout", "2", "--monitor",
    ],
    env=environment,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)
try:
    notify.settimeout(2)
    assert notify.recv(256).startswith(b"READY=1")
    readable, _, _ = select.select([process.stdout], [], [], 2)
    assert readable, "x11 ready marker was not flushed while monitor remained active"
    assert process.stdout.readline().strip() == "x11-authorization-ready user=gamer"
    server.join(4)
    assert not server.is_alive()
    assert len(accepted) == 2
    assert all(family == 5 and b"localuser\0gamer" in body for family, body in accepted)
finally:
    process.terminate()
    process.wait(timeout=2)
    notify.close()
assert process.returncode == -15
PY

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
x11_environment = scratch / "tmp" / "policy" / "environment"
x11_environment.parent.mkdir()
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
    "--x11-environment", str(x11_environment),
    "--proc-net-unix", str(proc), "--gid", str(os.getgid()),
]

for display in (1, -1):
    nonzero_session = scratch / f"nonzero-session-{display}"
    nonzero_environment = scratch / "tmp" / "policy" / f"nonzero-{display}"
    failed = subprocess.run([
        publisher, "publish", "--session", str(nonzero_session),
        "--wayland", str(wayland), "--x11", str(x11),
        "--x11-environment", str(nonzero_environment),
        "--proc-net-unix", str(proc), "--gid", str(os.getgid()),
        "--display", str(display),
    ], text=True, capture_output=True)
    assert failed.returncode != 0
    assert "unsupported_x11_display" in failed.stderr
    assert not nonzero_session.exists() and not nonzero_session.is_symlink()
    assert not nonzero_environment.exists()

subprocess.run(common, check=True)
assert session.is_symlink()
generation = session.resolve()
assert (generation.stat().st_mode & 0o777) == 0o755
assert (generation / "environment").read_text() == (
    "POCKETFORGE_SESSION=/run/pocketforge/session\n"
    "POCKETFORGE_SESSION_GENERATION=1\n"
    "WAYLAND_DISPLAY=/run/pocketforge/session/wayland-0\n"
)
assert not any(
    line.startswith(("DISPLAY=", "XAUTHORITY="))
    for line in (generation / "environment").read_text().splitlines()
)
assert (generation / "environment").stat().st_mode & 0o777 == 0o444
assert x11_environment.read_text() == "DISPLAY=:0\n"
assert (x11_environment.stat().st_mode & 0o777) == 0o444
assert not (generation / "capabilities" / "x11").exists()
assert (generation / "wayland-0").resolve() == wayland.resolve()

stale_x11 = x11_dir / "X1"
stale_listener = socket.socket(socket.AF_UNIX)
stale_listener.bind(str(stale_x11))
stale_listener.listen(1)
stale_listener.close()
stale = scratch / "stale-x11"
failed = subprocess.run([
    publisher, "publish", "--session", str(stale),
    "--wayland", str(wayland), "--x11", str(stale_x11),
    "--x11-environment", str(scratch / "stale-environment"),
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
    "--x11-environment", str(scratch / "refused-environment"),
    "--proc-net-unix", str(proc), "--gid", str(os.getgid()),
], text=True, capture_output=True)
assert failed.returncode != 0
assert "abstract_x11_listener" in failed.stderr
assert not refused.exists()

not_ready = scratch / "not-ready"
failed = subprocess.run([
    publisher, "publish", "--session", str(not_ready),
    "--wayland", str(sockets / "missing"), "--x11", str(x11),
    "--x11-environment", str(scratch / "not-ready-environment"),
    "--proc-net-unix", str(proc), "--gid", str(os.getgid()), "--timeout", "0",
], text=True, capture_output=True)
assert failed.returncode != 0
assert "socket_readiness_timeout" in failed.stderr
assert not not_ready.exists()
environment_failed = scratch / "environment-failed"
failed = subprocess.run([
    publisher, "publish", "--session", str(environment_failed),
    "--wayland", str(wayland), "--x11", str(x11),
    "--x11-environment", str(scratch / "missing-policy-parent" / "environment"),
    "--proc-net-unix", str(proc), "--gid", str(os.getgid()),
], text=True, capture_output=True)
assert failed.returncode != 0
assert not environment_failed.exists() and not environment_failed.is_symlink()
subprocess.run([
    publisher, "cleanup", "--session", str(session),
    "--x11-environment", str(x11_environment),
], check=True)
assert not session.exists() and not session.is_symlink()
assert not x11_environment.exists()
for listener in listeners:
    listener.close()
PY

# The producer inventory and audit must agree: required paths pass, deleting a
# producer makes the same invocation fail, and not-shipped has no requirements.
mkdir -p "${scratch}/g1/run/dbus"
: >"${scratch}/g1/run/dbus/system_bus_socket"
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
    "/run/pocketforge/x11/policy/environment",
    "/run/pocketforge/x11/.X11-unix/X0",
}
PY
"${checker}" --root "${scratch}/g1" --inventory "${policy}" --producers "${manifest}"
cp "${manifest}" "${scratch}/missing-producer.json"
python3 - "${scratch}/missing-producer.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
del data["producers"]["/run/pocketforge/x11/.X11-unix/X0"]
open(path, "w", encoding="utf-8").write(json.dumps(data))
PY
if "${checker}" --root "${scratch}/g1" --inventory "${policy}" \
    --producers "${scratch}/missing-producer.json" >"${scratch}/negative.out" 2>&1; then
    fail "producer audit accepted a missing required producer"
fi
grep -F '/run/pocketforge/x11/.X11-unix/X0' "${scratch}/negative.out" >/dev/null

echo 'PASS: dormant Gamescope session supervisor, atomic producer, scoped X11, input contract and producer audit'
