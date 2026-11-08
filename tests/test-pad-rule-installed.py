#!/usr/bin/env python3
"""The App Pad udev rule is staged, installed and ordered before Steam Link (offline)."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


docker = (ROOT / "build/Dockerfile.pf").read_text()
check("/out/udev/70-pf-app-pad.rules" in docker and "crates/pf-input-broker/systemd/70-pf-app-pad.rules" in docker,
      "Dockerfile.pf does not stage 70-pf-app-pad.rules into /out/udev")
check(re.search(r'\[ -f "?crates/pf-input-broker/systemd/70-pf-app-pad\.rules"? \]', docker) is not None,
      "Dockerfile.pf does not fail when the rule is absent")

inst = (ROOT / "scripts/install-default-app-support.sh").read_text()
check('${runtime_stage}/udev/70-pf-app-pad.rules' in inst, "installer does not reference the staged rule")
check(re.search(r'install -D -m 0644 "\$\{pad_rule\}"\s*\\\s*\n\s*"\$\{rootfs\}/etc/udev/rules\.d/70-pf-app-pad\.rules"', inst)
      is not None, "installer does not install the rule to /etc/udev/rules.d/70-pf-app-pad.rules")
check(inst.count('"${pad_rule}"') >= 3, "installer does not require the rule and forbid it on non-open profiles")

rule = (ROOT / "tests/fixtures/70-pf-app-pad.rules").read_text()
for needle in ('ATTRS{name}=="PocketForge App Pad"', 'ATTRS{id/bustype}=="0006"',
               'ATTRS{id/vendor}=="5046"', 'ATTRS{id/product}=="0100"', 'SYMLINK+="input/pf-app-pad"'):
    check(needle in rule, f"rule fixture lacks {needle}")

d = ROOT / "build/pf-app@org.pocketforge.steamlink.service.d"
order = (d / "20-pad-order.conf").read_text().splitlines()
check("After=pf-input-broker.service" in order, "steamlink drop-in does not order After=pf-input-broker.service")
check("ExecStartPre=+/usr/bin/udevadm settle --timeout=5" in order, "steamlink drop-in lacks the udevadm settle ExecStartPre")
check(any(l.startswith("#") and "Wants=" in l for l in order), "drop-in must state why there is no Wants=")
policy = (d / "10-policy.conf").read_text().splitlines()
check("BindPaths=/dev/input/pf-app-pad:/dev/input/event0" in policy, "non-optional pad bind changed")
check(not any(l.startswith(("Wants=", "BindPaths=-")) for l in order), "order drop-in must not add Wants= or optional binds")
gs = (ROOT / "scripts/install-gamescope-session.sh").read_text()
check("20-pad-order.conf" in gs, "gamescope installer does not install 20-pad-order.conf")

if failures:
    print("\n".join("FAIL: " + f for f in failures))
    sys.exit(1)
print("ok")
