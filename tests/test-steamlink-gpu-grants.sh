#!/bin/sh
# Steam Link Landlock grants for Mesa device discovery (sat3 r19 EACCES evidence):
# read-only (file+dir) access to the DRM/sysfs/proc paths the client needs, via the
# inventory's session-environment class, mirrored as BindReadOnlyPaths in the drop-in.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
inventory=${root}/build/app-policy-a133-open-g1-v1.json
fragment=${root}/build/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf
python3 - "$inventory" "$fragment" <<'PY'
import json, pathlib, sys
inv = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
frag = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
need = ["/dev/dri", "/sys/dev/char", "/sys/devices/platform", "/sys/class/drm",
        "/proc/cpuinfo", "/proc/sys/vm/overcommit_memory", "/dev/urandom",
        # sat3w/sat3x: PVR sizes its heap from these; denied -> 484 MiB heap, ZINK vkCreateDevice OOM
        "/proc/meminfo", "/proc/stat", "/sys/devices/system/cpu"]
env = inv["resources"]["session-environment"]
for p in need:
    if p not in env:
        raise SystemExit(f"inventory session-environment lacks {p}")
    if f"BindReadOnlyPaths={p}" not in frag:
        raise SystemExit(f"drop-in lacks BindReadOnlyPaths={p}")
if "/run/pocketforge/session/environment" not in env:
    raise SystemExit("session-environment lost the session environment file")
if inv["resources"]["render-devices"] != ["/dev/dri/renderD128"]:
    raise SystemExit("render-devices must stay the single render node")
print("Steam Link GPU grants: PASS")
PY
