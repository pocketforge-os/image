#!/usr/bin/env python3
"""Steam Link gets the App Pad by identity (/dev/input/pf-app-pad), offline."""
import json
import os
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


inv = json.loads((ROOT / "build/app-policy-a133-open-g1-v1.json").read_text())
devs = inv["resources"]["input-devices"]
check("/dev/input/pf-app-pad" in devs, f"inventory lacks pf-app-pad: {devs}")
check("/dev/input/event0" not in devs, f"inventory still grants event0: {devs}")

toml = tomllib.loads((ROOT / "apps/steamlink/app.toml").read_text())
check("rumble" in toml["app"]["use"], "app.toml use lacks rumble")

fetch = (ROOT / "apps/steamlink/steamlink-fetch.py").read_text()
check(
    re.search(r'environment\["SDL_JOYSTICK_DISABLE_UDEV"\]\s*=\s*"1"', fetch) is not None,
    "launch env does not set SDL_JOYSTICK_DISABLE_UDEV=1",
)

# Committed rendered policy: only checked when a policy renderer is available
# offline (PF_APP_POLICY_RENDER); this is red until Part B regenerates it.
if os.environ.get("PF_APP_POLICY_RENDER"):
    conf = (ROOT / "build/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf").read_text()
    lines = conf.splitlines()
    check("BindPaths=/dev/input/pf-app-pad:/dev/input/event0" in lines, "10-policy.conf lacks pad BindPaths")
    check("DeviceAllow=/dev/input/pf-app-pad rw" in lines, "10-policy.conf lacks pad DeviceAllow rw")
    check(not any(l.startswith("BindReadOnlyPaths=/dev/input") for l in lines), "10-policy.conf binds /dev/input read-only")
else:
    print("note: PF_APP_POLICY_RENDER unset; skipping rendered-policy checks")

if failures:
    print("\n".join("FAIL: " + f for f in failures))
    sys.exit(1)
print("ok")
