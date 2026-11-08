"""Acceptance contract for tsp-mc9m.60.29.84.81.3 (initrd PF_SELF_FLASH_V3_PROGRESS markers).

Worker authors tests/test-self-flash-v3-progress.sh (hermetic, exits 0) proving the markers
appear at intervals with byte counts and that the write/verify path is unchanged.
"""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "boards" / "tsp" / "initrd" / "self-flash-v3.sh"
WORKER_TEST = ROOT / "tests" / "test-self-flash-v3-progress.sh"


class ProgressContract(unittest.TestCase):
    def test_script_emits_marker(self):
        self.assertIn("PF_SELF_FLASH_V3_PROGRESS", SCRIPT.read_text())

    def test_script_syntax(self):
        r = subprocess.run(["sh", "-n", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_worker_test_passes(self):
        self.assertTrue(WORKER_TEST.is_file(), "missing %s" % WORKER_TEST)
        r = subprocess.run(["sh", str(WORKER_TEST)], cwd=ROOT, capture_output=True,
                           text=True, timeout=300)
        self.assertEqual(r.returncode, 0, (r.stdout + r.stderr)[-2000:])


if __name__ == "__main__":
    unittest.main()
