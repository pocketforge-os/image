#!/usr/bin/env python3
"""Steam Link shell platform libraries must be supplied by the platform runtime.

build-steamlink-app-root-prototype.sh is_platform_library() keeps these
soname families OUT of the app root, so the platform runtime seed list in
build/app-platform-runtime-a133-open-v1.json must provide every one the
fetched Steam Link shell NEEDs. r4 on image 4e383594 failed at start with
'libepoxy.so.0: cannot open shared object file'.
"""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "build/app-platform-runtime-a133-open-v1.json"
PROTOTYPE = ROOT / "scripts/build-steamlink-app-root-prototype.sh"
# Sonames the shell is known to need that are excluded from the app root.
# Direct NEEDED of Steam Link 1.3.32.316 bin/shell (readelf -d) that
# is_platform_library() excludes from the app root, minus the ffmpeg59 runtime
# (libavcodec/libavutil) which has its own bound runtime.  libepoxy's own
# NEEDED (libdl, libc, ld-linux) are all base_sonames.
KNOWN_SHELL_NEEDS = (
    "libdrm.so.2",
    "libepoxy.so.0",
    "libwayland-client.so.0",
    "libwayland-egl.so.1",
)


class SteamLinkShellPlatformNeededTest(unittest.TestCase):
    def test_known_shell_needs_are_platform_runtime_seeds(self):
        seeds = {Path(s).name for s in json.loads(CONFIG.read_text())["seeds"]}
        for soname in KNOWN_SHELL_NEEDS:
            with self.subTest(soname=soname):
                self.assertIn(soname, seeds)

    def test_known_needs_are_excluded_from_app_root(self):
        # Guards the premise: if this stops being a platform library the fix
        # layer changes and this test must be revisited.
        text = PROTOTYPE.read_text()
        block = re.search(r"is_platform_library\(\) \{.*?\n\}", text, re.S).group(0)
        self.assertIn("libepoxy.so.*", block)


if __name__ == "__main__":
    unittest.main()
