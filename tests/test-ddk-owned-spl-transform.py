#!/usr/bin/env python3
"""Red gate (gpu-16 09:34Z key gfx7-gapsheet-go): CLI contract of the closed-DDK owned-SPL transform.

Contract fixed here; the worker adds the synthetic-image behaviour tests (gap sheet Row 5 checks 1-7) as a second
red commit before the implementation:
  scripts/ddk-owned-spl-transform.py build  --ddk-image F --ddk-sha256 H --spl-fit F --spl-fit-sha256 H --out F
  scripts/ddk-owned-spl-transform.py verify --ddk-image F --spl-fit F --image F
build refuses (nonzero, no output file) when an input does not match its pinned sha256; verify fails closed
(nonzero) on anything that is not exactly the pinned DDK image plus the declared transform.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "ddk-owned-spl-transform.py"
DDK_SHA = "31271d568c20269e30628a3ea98199fd40d52fb627e1e59864b8ebe7fe2049e6"


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True, timeout=120)


class Contract(unittest.TestCase):
    def test_script_exists_and_has_modes(self):
        self.assertTrue(SCRIPT.is_file())
        for mode in ("build", "verify"):
            self.assertEqual(run(mode, "--help").returncode, 0, mode)

    def test_build_refuses_unpinned_inputs_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            ddk = Path(tmp) / "ddk.img"
            ddk.write_bytes(b"not the pinned image")
            spl = Path(tmp) / "spl.bin"
            spl.write_bytes(b"spl")
            out = Path(tmp) / "out.img"
            r = run("build", "--ddk-image", str(ddk), "--ddk-sha256", DDK_SHA,
                    "--spl-fit", str(spl), "--spl-fit-sha256", "0" * 64, "--out", str(out))
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(out.exists())

    def test_verify_fails_closed_on_a_non_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            junk = Path(tmp) / "junk.img"
            junk.write_bytes(b"\0" * 4096)
            r = run("verify", "--ddk-image", str(junk), "--spl-fit", str(junk), "--image", str(junk))
            self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
