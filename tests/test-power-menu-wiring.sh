#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dockerfile="${root}/build/Dockerfile.pf"
builder="${root}/scripts/build-rootfs.sh"
shell_unit="${root}/rootfs-overlay/etc/systemd/system/pf-shell-selected.service"

for needle in \
    '-p pf-powerd --bin pf-powerd' \
    'install -D -m 0755 "${POWERD_BIN}" /out/bin/pf-powerd' \
    'install -D -m 0644 systemd/pf-powerd.service /out/systemd/pf-powerd.service'; do
    grep -F -- "${needle}" "${dockerfile}" >/dev/null
done

for needle in \
    'install -D -m 0755 "${POWERD_BIN}" "${ROOTFS}/usr/bin/pf-powerd"' \
    '"${ROOTFS}/etc/systemd/system/pf-powerd.service"' \
    '"${ROOTFS}/etc/systemd/system/multi-user.target.wants/pf-powerd.service"'; do
    grep -F -- "${needle}" "${builder}" >/dev/null
done

grep -Fx 'Wants=pf-powerd.service' "${shell_unit}" >/dev/null
grep -E '^After=.*[[:space:]]pf-powerd\.service([[:space:]]|$)' "${shell_unit}" >/dev/null
grep -Fx 'Environment=PF_POWER_SOCK=/run/pocketforge-power/power.sock' "${shell_unit}" >/dev/null

policy="${root}/power-key-policy/60-pocketforge-power-key.conf"
grep -Fx 'HandlePowerKey=ignore' "${policy}" >/dev/null
grep -Fx 'HandlePowerKeyLongPress=poweroff' "${policy}" >/dev/null
grep -F '"${ROOTFS}/etc/systemd/logind.conf.d/60-pocketforge-power-key.conf"' "${builder}" >/dev/null

# The bulk overlay deploy path does not ship powerd or the selected shell. Its
# payload must never contain the paired policy, in any flag combination.
python3 - "${root}" <<'PYTEST'
import itertools
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="power-key-deploy-") as temp:
    fixture = Path(temp)
    (fixture / "bin").mkdir()
    (fixture / "rootfs-overlay").symlink_to(root / "rootfs-overlay", target_is_directory=True)
    (fixture / "power-key-policy").symlink_to(root / "power-key-policy", target_is_directory=True)
    ssh = fixture / "bin/ssh"
    ssh.write_text("#!/bin/sh\nexit 0\n")
    rsync = fixture / "bin/rsync"
    rsync.write_text(r"""#!/usr/bin/env python3
import os
from pathlib import Path
import sys
with open(os.environ['PAYLOAD_CAPTURE'], 'a') as capture:
    for arg in sys.argv[1:]:
        source = Path(arg)
        if source.is_dir() and str(source).startswith(os.environ['SRC_DIR']):
            for child in source.rglob('*'):
                if child.is_file():
                    capture.write(str(child.relative_to(source)) + '\n')
""")
    ssh.chmod(0o755)
    rsync.chmod(0o755)
    capture = fixture / "payload.txt"
    env = os.environ | {
        "PATH": str(fixture / "bin") + os.pathsep + os.environ['PATH'],
        "SRC_DIR": str(fixture), "PAYLOAD_CAPTURE": str(capture),
        "LIBSDL3_DIR": str(fixture / "library"),
        "TSP_HOST": "fixture@invalid", "SSH_KEY": str(fixture / "unused-key"),
    }
    library = fixture / "library/libSDL3-pocketforge.so.0"
    library.parent.mkdir()
    flags = ["--overlay-only", "--pocketforge-only", "--no-restart"]
    checked = 0
    for library_present in (False, True):
        if library_present:
            library.write_text("fixture library")
        for size in range(4):
            for args in itertools.permutations(flags, size):
                capture.write_text("")
                subprocess.run([str(root / "scripts/deploy.sh"), *args], env=env,
                               check=True, timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                assert "60-pocketforge-power-key.conf" not in capture.read_text(), args
                checked += 1
    assert checked == 32
print("PASS power policy excluded from all 16 deploy flag sequences with library present and absent")
PYTEST

echo 'PASS power menu authority is built, installed, enabled, and ordered before pf-shell'
