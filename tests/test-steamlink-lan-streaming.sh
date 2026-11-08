#!/bin/sh
# sat3y demo blockers: LAN discovery/streaming needs AF_NETLINK, the Steam Link UDP/TCP
# ports in the declared egress, and a writable XDG_DATA_HOME for streaming_settings.bin.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import pathlib, re, sys, tomllib
root = pathlib.Path(sys.argv[1])
use = tomllib.loads((root / "apps/steamlink/app.toml").read_text())["app"]["use"]
want = [f"egress:udp/{p}@*" for p in range(27031, 27037)] + ["egress:tcp/27036@*", "egress:tcp/27037@*"]
# sat3z/r25 (CURL 7 on wss://cmp1-syd1.steamserver.net:27018): Valve client CM range 27015-27030 tcp+udp
want += [f"egress:{proto}/{p}@*" for proto in ("tcp", "udp") for p in range(27015, 27031)]
for w in want:
    if w not in use:
        raise SystemExit(f"app.toml use lacks {w}")
frag = (root / "build/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf").read_text()
if "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" not in frag:
    raise SystemExit("10-policy.conf lacks AF_NETLINK for the networked app")
import json
inv = json.loads((root / "build/app-policy-a133-open-g1-v1.json").read_text())
# sat3z r25: ALSA dmix "unable to open timer" - /dev/snd/timer must be a granted audio device
if "/dev/snd/timer" not in inv["resources"]["audio-devices"]:
    raise SystemExit("inventory audio-devices lacks /dev/snd/timer")
if "DeviceAllow=/dev/snd/timer rw" not in frag:
    raise SystemExit("10-policy.conf lacks DeviceAllow=/dev/snd/timer rw")
launch = (root / "apps/steamlink/pf-launch").read_text()
if not re.search(r'XDG_DATA_HOME=.*state', launch) or "Valve Corporation/SteamLink" not in launch:
    raise SystemExit("pf-launch lacks a writable default XDG_DATA_HOME")
for f in ("docs/STEAM-LINK-APP-RUNTIME-ROOT.md", "scripts/build-steamlink-app-root-prototype.sh"):
    if "egress:udp/27031@*" not in (root / f).read_text():
        raise SystemExit(f"{f} lacks the LAN egress list")
print("Steam Link LAN streaming: PASS")
PY
