#!/usr/bin/env python3
"""Hermetic positive and failure controls for typed root-growth results."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
REPORTER = ROOT / "rootfs-overlay/usr/lib/pocketforge/root-grow-result"
sys.dont_write_bytecode = True


def load_reporter():
    loader = importlib.machinery.SourceFileLoader("root_grow_result", str(REPORTER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create reporter import spec")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class RootGrowResultTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.reporter = load_reporter()

    def setUp(self):
        self.marker = {
            "baked_start_sector": 274432,
            "baked_sectors": 655360,
        }
        self.grown = {
            "root_start_sector": 274432,
            "root_sectors": 1822687,
            "disk_sectors": 2097152,
            "filesystem_bytes": 1822687 * 512 - 3584,
        }

    def test_grown_then_second_boot_is_already(self):
        outcome = self.reporter.classify(self.marker, self.grown, prior_complete=False)
        self.assertEqual((outcome.state, outcome.reason), ("grown", "complete"))

        outcome = self.reporter.classify(self.marker, self.grown, prior_complete=True)
        self.assertEqual((outcome.state, outcome.reason), ("already", "complete"))

    def test_partition_and_filesystem_failure_controls_are_typed(self):
        cases = {
            "root_start_mismatch": dict(self.grown, root_start_sector=274433),
            "partition_shrunk": dict(self.grown, root_sectors=655359),
            "partition_not_grown": dict(self.grown, root_sectors=655360),
            "partition_not_at_disk_end": dict(self.grown, root_sectors=655361),
            "filesystem_exceeds_partition": dict(
                self.grown,
                filesystem_bytes=self.grown["root_sectors"] * 512 + 1,
            ),
            "filesystem_not_grown": dict(
                self.grown,
                filesystem_bytes=self.marker["baked_sectors"] * 512,
            ),
        }
        for reason, geometry in cases.items():
            with self.subTest(reason=reason):
                outcome = self.reporter.classify(
                    self.marker, geometry, prior_complete=False
                )
                self.assertEqual((outcome.state, outcome.reason), ("failed", reason))

    def test_probe_failure_logs_typed_line_and_does_not_block_boot(self):
        def fail_probe(_marker):
            raise OSError("fixture probe failure")

        with tempfile.TemporaryDirectory() as directory:
            output = io.StringIO()
            marker_path = Path(directory) / "marker"
            marker_path.write_text(
                "Schema=pocketforge.root-grow/v1\n"
                "BakedRootPartitionStartSector=274432\n"
                "BakedRootPartitionSectors=655360\n",
                encoding="ascii",
            )
            result = self.reporter.run(
                probe=fail_probe,
                marker_path=marker_path,
                state_path=Path(directory) / "state",
                output=output,
            )

        self.assertEqual(result, 0)
        self.assertEqual(
            output.getvalue(),
            "PF_ROOT_GROW state=failed reason=probe_failed\n",
        )

    def test_all_reporting_failures_are_nonfatal_and_typed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            valid_marker = root / "marker"
            valid_marker.write_text(
                "Schema=pocketforge.root-grow/v1\n"
                "BakedRootPartitionStartSector=274432\n"
                "BakedRootPartitionSectors=655360\n",
                encoding="ascii",
            )

            cases = (
                (
                    "marker_invalid",
                    root / "missing-marker",
                    lambda _marker: self.grown,
                    root / "unused-state",
                ),
                (
                    "classification_failed",
                    valid_marker,
                    lambda _marker: {},
                    root / "unused-state-two",
                ),
                (
                    "state_write_failed",
                    valid_marker,
                    lambda _marker: self.grown,
                    root,
                ),
            )
            for reason, marker_path, probe, state_path in cases:
                with self.subTest(reason=reason):
                    output = io.StringIO()
                    result = self.reporter.run(
                        probe=probe,
                        marker_path=marker_path,
                        state_path=state_path,
                        output=output,
                    )
                    self.assertEqual(result, 0)
                    self.assertEqual(
                        output.getvalue(),
                        f"PF_ROOT_GROW state=failed reason={reason}\n",
                    )


if __name__ == "__main__":
    unittest.main()
