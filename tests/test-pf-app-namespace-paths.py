#!/usr/bin/env python3
"""Every pf-app@ mount-namespace path must exist when the unit starts, or be optional ('-').

systemd builds the unit's mount namespace before ExecStartPre, so a missing non-optional
BindPaths/BindReadOnlyPaths/TemporaryFileSystem/ReadOnlyPaths/ReadWritePaths target stops the
app with 226/NAMESPACE (image F: /dev/input/event0; image G: /run/pf-ime-door).
A path passes if it is: optional ('-' prefix); created by a tmpfiles.d line, a Runtime/State/
CacheDirectory= of the unit, or shipped in rootfs-overlay; or on the explicit fail-closed
allowlist below (kernel/udev nodes and session-start sockets the app must not start without).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UNIT = ROOT / "rootfs-overlay/etc/systemd/system/pf-app@.service"
DROPINS = sorted((ROOT / "build").glob("pf-app@*.service.d/*.conf")) + sorted(
    (ROOT / "rootfs-overlay/etc/systemd/system/pf-app@.service.d").glob("*.conf"))
TMPFILES = sorted((ROOT / "rootfs-overlay/usr/lib/tmpfiles.d").glob("*.conf"))
KEYS = ("BindPaths", "BindReadOnlyPaths", "TemporaryFileSystem", "ReadOnlyPaths", "ReadWritePaths",
        "InaccessiblePaths", "ReadOnlyDirectories", "ReadWriteDirectories", "InaccessibleDirectories")
# Fail-closed by design: absent means the app must not start. Each has a stated provider.
ALLOW = (
    (re.compile(r"^/(dev|proc|sys)(/|$)"), "kernel/udev node"),
    (re.compile(r"^/run/pocketforge/(session|x11)(/|$)"), "created by the gamescope session target"),
    (re.compile(r"^/opt/pocketforge/apps/"), "app root written by the app installer before the unit is started"),
)
failures = []


def tmpfiles_dirs():
    out = set()
    for f in TMPFILES:
        for line in f.read_text().splitlines():
            p = line.split()
            if len(p) >= 2 and p[0][:1] in "dDfFLpcCvqQ" and p[1].startswith("/"):
                out.add(p[1].rstrip("/"))
    return out


def dir_keys(text):
    got = set()
    for m in re.finditer(r"^(Runtime|State|Cache)Directory=(.+)$", text, re.M):
        base = {"Runtime": "/run", "State": "/var/lib", "Cache": "/var/cache"}[m.group(1)]
        for d in m.group(2).split():
            got.add(f"{base}/{d}".rstrip("/"))
    return got


def under(path, made):
    return any(path == m or path.startswith(m + "/") for m in made)


def covered(path, made):
    if "%" in path:
        path = re.sub(r"%[a-zA-Z]", "X", path)
        made = {re.sub(r"%[a-zA-Z]", "X", m) for m in made}
    if under(path, made):
        return "tmpfiles/unit directory"
    if (ROOT / "rootfs-overlay" / path.lstrip("/")).exists():
        return "rootfs-overlay"
    for rx, why in ALLOW:
        if rx.match(path):
            return why
    return None


def check_unit(path, made):
    text = path.read_text()
    made = made | dir_keys(text)
    for m in re.finditer(r"^(%s)=(.+)$" % "|".join(KEYS), text, re.M):
        key, val = m.group(1), m.group(2).split("#")[0]
        for tok in val.split():
            if tok.startswith(("-", "+")) and key != "TemporaryFileSystem":
                continue  # optional
            if key == "TemporaryFileSystem":
                tok = tok.split(":")[0]
                if tok.startswith("-"):
                    continue
            if key in ("BindPaths", "BindReadOnlyPaths"):
                tok = tok.split(":")[0].lstrip("-+")
            if not tok.startswith("/"):
                continue
            if covered(tok, made) is None:
                failures.append(f"{path.relative_to(ROOT)}: {key}={tok} is non-optional and nothing creates it before the unit starts")


made = tmpfiles_dirs()
for p in [UNIT] + DROPINS:
    check_unit(p, made)

# Controls: a path nothing creates must be reported.
sample = ROOT / ".ns-neg-control.tmp"
sample.write_text("[Service]\nTemporaryFileSystem=/run/nothing-creates-this:ro\nBindPaths=-/run/optional-ok\n")
n = len(failures)
check_unit(sample, made)
sample.unlink()
if len(failures) != n + 1 or "nothing-creates-this" not in failures[-1]:
    print("FAIL: negative control did not fire")
    sys.exit(1)
failures.pop()

if failures:
    print("\n".join("FAIL: " + f for f in failures))
    sys.exit(1)
print("pf-app namespace paths: PASS")
