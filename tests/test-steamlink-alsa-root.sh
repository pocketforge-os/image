#!/bin/sh
# .26: Steam Link's SDL3 dlopens libasound.so.2 (no sound server on the DUT). The rooted
# app root must carry libasound2t64 (built-in dmix/softvol/plug, alsa.conf via libasound2-data)
# and the platform /etc/asound.conf (Codec card by id), and the installer must expect it.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import pathlib, re, sys
inst = (pathlib.Path(sys.argv[1]) / "scripts/install-steamlink-first-run.sh").read_text()
if "--package libasound2t64" not in inst:
    raise SystemExit("installer does not request --package libasound2t64")
m = re.search(r"expected_packages = \[([^\]]*)\]", inst)
if not m or "libasound2t64" not in m.group(1):
    raise SystemExit("installer root metadata expectation lacks libasound2t64")
if not re.search(r'etc/asound\.conf', inst) or "app_root_overlay" not in inst.split("etc/asound.conf", 1)[0][-400:] + inst.split("etc/asound.conf", 1)[1][:400]:
    raise SystemExit("installer does not place /etc/asound.conf into the app-root overlay")
print("Steam Link ALSA root: PASS")
PY
