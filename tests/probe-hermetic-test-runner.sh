#!/bin/sh
set -eu

blocked()
{
    printf 'BLOCKED: missing %s\n' "$1" >&2
    exit 75
}

for tool in bwrap python3 systemd; do
    command -v "$tool" >/dev/null 2>&1 || blocked "$tool"
done

bwrap --ro-bind / / --dev /dev /bin/true >/dev/null 2>&1 || blocked bwrap

test "${PF_HERMETIC_PROBE_INOTIFY:-probe}" != missing || blocked inotify
python3 - <<'PY' >/dev/null 2>&1 || blocked inotify
import ctypes
import os

libc = ctypes.CDLL(None, use_errno=True)
fd = libc.inotify_init1(os.O_CLOEXEC)
if fd < 0:
    raise OSError(ctypes.get_errno(), "inotify_init1")
os.close(fd)
PY

printf '%s\n' \
    'hermetic_runner_probe=PASS capabilities=bwrap,inotify,systemd'
