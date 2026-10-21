#!/usr/bin/env python3
"""Hermetic controls for the self-flash v3 normal-root staging helper."""

from __future__ import annotations

import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "rootfs-overlay/usr/lib/pocketforge/self-flash-v3-stage"
sys.dont_write_bytecode = True


def load_helper():
    loader = importlib.machinery.SourceFileLoader("self_flash_v3_stage", str(HELPER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create helper import spec")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


sf = load_helper()


class LayoutTests(unittest.TestCase):
    def test_measured_card_positive_layout(self):
        layout = sf.derive_layout(
            card_bytes=62_534_975_488,
            base_raw_bytes=1_465_929_728,
            target_raw_bytes=1_783_648_256,
            compressed_bytes=278_275_448,
            seed_bytes=1_048_576,
        )
        self.assertEqual(layout["tail_start"], 61_459_136_512)
        self.assertEqual(layout["stage_offset"], 61_463_330_816)
        self.assertLessEqual(layout["seed_end"], layout["control_offset"])
        self.assertLess(layout["control_end"], layout["card_bytes"])

        sf.validate_partition_bounds(
            layout,
            [
                {"number": 1, "start": 8_388_608, "end": 41_943_040},
                {"number": 5, "start": 128_976_896, "end": layout["tail_start"]},
            ],
        )

    def test_layout_refuses_overlap_underflow_and_capacity(self):
        valid = dict(
            card_bytes=62_534_975_488,
            base_raw_bytes=1_465_929_728,
            target_raw_bytes=1_783_648_256,
            compressed_bytes=278_275_448,
            seed_bytes=1_048_576,
        )
        for mutation in (
            {"card_bytes": 1_073_741_824},
            {"card_bytes": 62_534_975_489},
            {"target_raw_bytes": 62_000_000_000},
            {"compressed_bytes": 1_100_000_000},
            {"seed_bytes": sf.SEED_MAX_BYTES + 1},
        ):
            with self.subTest(mutation=mutation), self.assertRaises(sf.Refusal):
                sf.derive_layout(**(valid | mutation))

        layout = sf.derive_layout(**valid)
        with self.assertRaises(sf.Refusal):
            sf.validate_partition_bounds(
                layout,
                [{"number": 5, "start": 128_976_896, "end": layout["tail_start"] + 512}],
            )


class DeviceSelectionTests(unittest.TestCase):
    def setUp(self):
        self.sd = {
            "name": "mmcblk1",
            "controller": "04020000",
            "card_type": "SD",
            "serial": "0x1234abcd",
            "bytes": 62_534_975_488,
            "logical_sector_bytes": 512,
            "partition5_major_minor": "179:5",
        }

    def test_sd_positive_and_emmc_negative_in_same_invocation(self):
        selected = sf.select_sd([self.sd], root_major_minor="179:5")
        self.assertEqual(selected["name"], "mmcblk1")

        emmc = self.sd | {"name": "mmcblk0", "controller": "04022000", "card_type": "MMC"}
        with self.assertRaises(sf.Refusal):
            sf.select_sd([emmc], root_major_minor="179:5")
        with self.assertRaises(sf.Refusal):
            sf.select_sd([self.sd, self.sd | {"name": "mmcblk2"}], root_major_minor="179:5")
        with self.assertRaises(sf.Refusal):
            sf.select_sd([], root_major_minor="179:5")
        with self.assertRaises(sf.Refusal):
            sf.select_sd([self.sd], root_major_minor="179:9")


class ExactStreamTests(unittest.TestCase):
    def test_exact_stream_is_durable_and_short_or_long_refuses(self):
        payload = bytes(range(251)) * 19
        with tempfile.TemporaryDirectory(prefix="pf-sf3-stage-") as directory:
            device = Path(directory) / "card.img"
            device.write_bytes(b"Z" * 16_384)

            with device.open("r+b", buffering=0) as output:
                observed = sf.copy_exact_stream(
                    io.BytesIO(payload), output, offset=4096, expected_bytes=len(payload)
                )
            self.assertEqual(observed, len(payload))
            result = device.read_bytes()
            self.assertEqual(result[4096 : 4096 + len(payload)], payload)
            self.assertEqual(result[:4096], b"Z" * 4096)
            self.assertEqual(hashlib.sha256(payload).hexdigest(), hashlib.sha256(result[4096 : 4096 + len(payload)]).hexdigest())

            for candidate in (payload[:-1], payload + b"x"):
                before = device.read_bytes()
                with self.subTest(size=len(candidate)), device.open("r+b", buffering=0) as output:
                    with self.assertRaises(sf.Refusal):
                        sf.copy_exact_stream(
                            io.BytesIO(candidate), output, offset=4096, expected_bytes=len(payload)
                        )
                # A partial candidate is permitted, but no caller may arm it;
                # the helper communicates refusal by raising before returning.
                self.assertEqual(len(device.read_bytes()), len(before))


class SurfaceTests(unittest.TestCase):
    @staticmethod
    def _fake_systemctl(path: Path, invocation_id: str, result: str, active_state: str) -> None:
        path.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' 'InvocationID={invocation_id}' "
            f"'Result={result}' 'ActiveState={active_state}'\n",
            encoding="ascii",
        )
        path.chmod(0o755)

    def test_growth_receipt_requires_current_successful_systemd_activation(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt_path = Path(directory) / "growth"
            boot_id_path = Path(directory) / "boot_id"
            systemctl_path = Path(directory) / "systemctl"
            boot_id_path.write_text("11111111-2222-4333-8444-555555555555\n")
            receipt_path.write_text(
                json.dumps(
                    {
                        "Schema": "pocketforge.self-flash-growth/v3",
                        "BootID": "11111111-2222-4333-8444-555555555555",
                        "InvocationID": "1" * 32,
                        "GPTRelocation": "pass",
                        "PartitionGrowth": "pass",
                        "PartitionTableReread": "pass",
                        "Ext4Growth": "pass",
                        "ControlSlotsInitialized": "zeroed-and-read-back",
                    }
                )
            )
            for invocation_id, result, accepted in (
                ("1" * 32, "success", True),
                ("2" * 32, "success", False),
                ("1" * 32, "failed", False),
            ):
                with self.subTest(invocation_id=invocation_id, result=result):
                    self._fake_systemctl(systemctl_path, invocation_id, result, "inactive")
                    patches = (
                        mock.patch.object(sf, "GROWTH_RECEIPT_PATH", receipt_path, create=True),
                        mock.patch.object(sf, "BOOT_ID_PATH", boot_id_path, create=True),
                        mock.patch.object(sf, "SYSTEMCTL_PATH", systemctl_path, create=True),
                    )
                    with patches[0], patches[1], patches[2]:
                        if accepted:
                            sf._require_current_growth_receipt()
                        else:
                            with self.assertRaises(sf.Refusal):
                                sf._require_current_growth_receipt()

            self._fake_systemctl(systemctl_path, "1" * 32, "success", "inactive")
            receipt = json.loads(receipt_path.read_text(encoding="ascii"))
            receipt["BootID"] = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            receipt_path.write_text(json.dumps(receipt), encoding="ascii")
            with (
                mock.patch.object(sf, "GROWTH_RECEIPT_PATH", receipt_path, create=True),
                mock.patch.object(sf, "BOOT_ID_PATH", boot_id_path, create=True),
                mock.patch.object(sf, "SYSTEMCTL_PATH", systemctl_path, create=True),
                mock.patch.object(sf, "_load_request") as load_request,
                self.assertRaises(sf.Refusal),
            ):
                sf.stage(Path("unused"), Path("unused"), io.BytesIO())
            load_request.assert_not_called()

    def test_cli_has_no_device_or_offset_authority(self):
        parser = sf.make_argument_parser()
        option_strings = {
            option
            for action in parser._actions
            for option in action.option_strings
        }
        self.assertEqual(option_strings, {"-h", "--help", "--request", "--seed"})
        source = HELPER.read_text(encoding="utf-8")
        for forbidden in ("/run/", "/dev/shm", "--device", "--offset", "--seek", "--skip"):
            self.assertNotIn(forbidden, source)

    def test_dev_rootfs_installs_root_only_helper_and_hashed_marker(self):
        builder = (ROOT / "scripts/build-rootfs.sh").read_text(encoding="utf-8")
        self.assertIn("self-flash-v3-stage", builder)
        self.assertIn("-m 0700", builder)
        self.assertIn("sha256sum", builder)
        self.assertIn('${SRC_DIR}/docs/SELF-FLASH-V3.md', builder)
        self.assertIn("Schema=pocketforge.self-flash-capability/v3", builder)
        dev_block = builder.split('if [ "${VARIANT}" = "dev" ]; then', 1)[1]
        release_block = dev_block.split('elif [ "${VARIANT}" = "release" ]', 1)[0]
        self.assertIn("self-flash-v3-stage", release_block)


if __name__ == "__main__":
    unittest.main(verbosity=2)
