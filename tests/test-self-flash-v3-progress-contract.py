"""Acceptance contract for tsp-mc9m.60.29.84.81.3 (initrd PF_SELF_FLASH_V3_PROGRESS markers).

Worker authors tests/test-self-flash-v3-progress.sh (hermetic, exits 0) proving the markers
appear at intervals with byte counts and that the write/verify path is unchanged.
"""
import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "boards" / "tsp" / "initrd" / "self-flash-v3.sh"
WORKER_TEST = ROOT / "tests" / "test-self-flash-v3-progress.sh"

# Verbatim copy of pocketforge-automation scripts/lib/pf_self_flash_v3_live.py
# _PROGRESS. Only lines that fullmatch it count as runner progress; this repo must
# not change that grammar, and DETAIL/heartbeat lines must never match it.
RUNNER_PROGRESS = re.compile(
    r"^PF_SELF_FLASH_V3_PROGRESS phase="
    r"(start|write|write-end|stamp) percent=(0|[1-9][0-9]?|100)$")


def _statements(text):
    """Shell statements with backslash continuations joined."""
    return text.replace("\\\n", " ").splitlines()


def _progress_printfs(text):
    out = []
    for stmt in _statements(text):
        m = re.search(r"printf '(PF_SELF_FLASH_V3_PROGRESS[^']*)'", stmt)
        if m:
            out.append((m.group(1), stmt))
    return out


class ProgressContract(unittest.TestCase):
    def test_script_emits_marker(self):
        self.assertIn("PF_SELF_FLASH_V3_PROGRESS", SCRIPT.read_text())

    def test_script_syntax(self):
        r = subprocess.run(["sh", "-n", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_one_grammar_format_and_details_never_match(self):
        fmts = _progress_printfs(SCRIPT.read_text())
        grammar = [f for f, _ in fmts if f.startswith("PF_SELF_FLASH_V3_PROGRESS ")]
        self.assertEqual(grammar, ["PF_SELF_FLASH_V3_PROGRESS phase=%s percent=%s\\n"])
        details = [f for f, _ in fmts if not f.startswith("PF_SELF_FLASH_V3_PROGRESS ")]
        self.assertGreaterEqual(len(details), 3, details)  # write, write heartbeat, verify
        phases = set()
        for fmt in details:
            self.assertTrue(fmt.startswith("PF_SELF_FLASH_V3_PROGRESS_DETAIL phase="), fmt)
            phases.add(fmt.split()[1])
            for phase in ("start", "write", "write-end", "stamp", "verify"):
                rendered = fmt.replace("phase=%s", "phase=" + phase)
                for value in ("0", "1", "50", "100"):
                    line = rendered.replace("%s", value).removesuffix("\\n")
                    self.assertIsNone(RUNNER_PROGRESS.fullmatch(line), line)
        self.assertIn("phase=verify", phases)

    def test_progress_lines_go_to_stderr_and_cannot_fail(self):
        for fmt, stmt in _progress_printfs(SCRIPT.read_text()):
            self.assertRegex(stmt, r">&2 \|\| :\s*$", stmt)

    def test_samplers_only_run_in_background_subshells(self):
        calls = [ln.strip() for ln in SCRIPT.read_text().splitlines()
                 if "sf_v3_progress_sampler" in ln and not ln.lstrip().startswith("#")
                 and not re.match(r"\s*sf_v3_progress_sampler\(\)", ln)]
        self.assertGreaterEqual(len(calls), 2, calls)  # verify + write
        for call in calls:
            self.assertRegex(call, r"^\( sf_v3_progress_sampler (verify|write) \) </dev/null &$")

    def test_sink_is_not_identified_by_cmdline(self):
        # BusyBox runs dd as a NOEXEC applet: its cmdline is the shell's argv.
        self.assertNotIn("/cmdline", SCRIPT.read_text().split(
            "# ---- PF_SELF_FLASH_V3_PROGRESS", 1)[1].split("sf_v3_stream_verify() {", 1)[0])

    def test_worker_test_passes(self):
        self.assertTrue(WORKER_TEST.is_file(), "missing %s" % WORKER_TEST)
        r = subprocess.run(["sh", str(WORKER_TEST)], cwd=ROOT, capture_output=True,
                           text=True, timeout=300)
        self.assertEqual(r.returncode, 0, (r.stdout + r.stderr)[-2000:])


if __name__ == "__main__":
    unittest.main()
