#!/usr/bin/env python3
"""Hermetic controls for bounded first-boot self-flash v3 growth."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import io
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "rootfs-overlay/usr/lib/pocketforge/self-flash-v3-grow"
BUILDER = ROOT / "scripts/build-rootfs.sh"
CLOUD_OVERRIDE = ROOT / "rootfs-overlay/etc/cloud/cloud.cfg.d/99-pocketforge-self-flash-v3.cfg"
UNIT = ROOT / "rootfs-overlay/etc/systemd/system/pocketforge-self-flash-v3-grow.service"
sys.dont_write_bytecode = True


def load_helper():
    loader = importlib.machinery.SourceFileLoader("self_flash_v3_grow", str(HELPER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create helper import spec")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


sf = load_helper()


class GrowthGeometryTests(unittest.TestCase):
    def setUp(self):
        self.card_bytes = 62_534_975_488
        self.start_sector = 251_904
        self.baked_sectors = 2_611_200
        self.partitions = [
            {"number": 1, "start_sector": 16_384, "sectors": 65_536},
            {
                "number": 5,
                "start_sector": self.start_sector,
                "sectors": self.baked_sectors,
            },
        ]

    def test_baked_and_already_capped_are_positive_wrong_or_overgrown_refuses(self):
        plan = sf.derive_growth_plan(
            card_bytes=self.card_bytes,
            partitions=self.partitions,
            baked_start_sector=self.start_sector,
            baked_sectors=self.baked_sectors,
        )
        self.assertEqual(plan["tail_start"], 61_459_136_512)
        self.assertEqual(plan["before_end_sector"], self.start_sector + self.baked_sectors)
        self.assertEqual(plan["after_end_sector"], plan["tail_start"] // 512)
        self.assertTrue(plan["needs_partition_growth"])

        capped = [dict(item) for item in self.partitions]
        capped[1]["sectors"] = plan["after_end_sector"] - self.start_sector
        self.assertFalse(
            sf.derive_growth_plan(
                card_bytes=self.card_bytes,
                partitions=capped,
                baked_start_sector=self.start_sector,
                baked_sectors=self.baked_sectors,
            )["needs_partition_growth"]
        )

        for bad in (
            self.baked_sectors + 1,
            plan["after_end_sector"] - self.start_sector + 1,
        ):
            wrong = [dict(item) for item in self.partitions]
            wrong[1]["sectors"] = bad
            with self.subTest(sectors=bad), self.assertRaises(sf.Refusal):
                sf.derive_growth_plan(
                    card_bytes=self.card_bytes,
                    partitions=wrong,
                    baked_start_sector=self.start_sector,
                    baked_sectors=self.baked_sectors,
                )

        overlap = [dict(item) for item in self.partitions]
        overlap.append(
            {
                "number": 6,
                "start_sector": plan["after_end_sector"] - 1,
                "sectors": 2,
            }
        )
        with self.assertRaises(sf.Refusal):
            sf.derive_growth_plan(
                card_bytes=self.card_bytes,
                partitions=overlap,
                baked_start_sector=self.start_sector,
                baked_sectors=self.baked_sectors,
            )


class ControlSlotTests(unittest.TestCase):
    def test_only_two_control_slots_are_zeroed_and_read_back(self):
        arm_offset = 4096
        receipt_offset = arm_offset + sf.SLOT_BYTES
        before = b"Q" * (receipt_offset + sf.SLOT_BYTES + 4096)
        device = io.BytesIO(before)

        sf.initialize_control_slots(
            device,
            arm_offset=arm_offset,
            receipt_offset=receipt_offset,
            sync=lambda: None,
        )
        after = device.getvalue()
        self.assertEqual(after[:arm_offset], before[:arm_offset])
        self.assertEqual(after[arm_offset:receipt_offset], bytes(sf.SLOT_BYTES))
        self.assertEqual(
            after[receipt_offset : receipt_offset + sf.SLOT_BYTES],
            bytes(sf.SLOT_BYTES),
        )
        self.assertEqual(
            after[receipt_offset + sf.SLOT_BYTES :],
            before[receipt_offset + sf.SLOT_BYTES :],
        )

        class ShortWrite(io.BytesIO):
            def write(self, payload):
                return max(0, len(payload) - 1)

        with self.assertRaises(sf.Refusal):
            sf.initialize_control_slots(
                ShortWrite(before),
                arm_offset=arm_offset,
                receipt_offset=receipt_offset,
                sync=lambda: None,
            )


class InstalledPolicyTests(unittest.TestCase):
    def test_root_only_unit_cloud_override_and_packages_are_wired(self):
        cloud = CLOUD_OVERRIDE.read_text(encoding="utf-8")
        self.assertEqual(cloud, "growpart:\n  mode: off\nresize_rootfs: false\n")

        unit = UNIT.read_text(encoding="utf-8")
        self.assertIn("Before=cloud-init-local.service cloud-init.service ssh.service", unit)
        self.assertIn("ExecStart=/usr/lib/pocketforge/self-flash-v3-grow", unit)
        self.assertIn("ConditionPathExists=/etc/pocketforge-selfflash-v3", unit)

        packages = (ROOT / "rootfs-packages-dev.txt").read_text(encoding="utf-8").splitlines()
        for package in ("e2fsprogs", "fdisk", "util-linux"):
            self.assertIn(package, packages)

        builder = BUILDER.read_text(encoding="utf-8")
        for literal in (
            "self-flash-v3-grow",
            "99-pocketforge-self-flash-v3.cfg",
            "pocketforge-self-flash-v3-grow.service",
            "BakedRootPartitionStartSector=251904",
            "BakedRootPartitionSectors=${SELF_FLASH_V3_BAKED_ROOT_SECTORS}",
            "-m 0700",
        ):
            self.assertIn(literal, builder)
        self.assertIn("tests/test-self-flash-v3-growth.py", (ROOT / ".github/workflows/hermetic-tests.yml").read_text())

    def test_growth_cli_has_no_device_or_geometry_authority(self):
        parser = sf.make_argument_parser()
        option_strings = {
            option for action in parser._actions for option in action.option_strings
        }
        self.assertEqual(option_strings, {"-h", "--help"})
        source = HELPER.read_text(encoding="utf-8")
        for forbidden in ("/run/", "/dev/shm", "--device", "--offset", "--seek", "--skip"):
            self.assertNotIn(forbidden, source)

    def test_receipt_truthfully_records_control_initialization(self):
        receipt = sf.build_growth_receipt(
            contract_sha256="a" * 64,
            card_serial="0x1234abcd",
            card_bytes=62_534_975_488,
            root_start_sector=251_904,
            before_end_sector=2_863_104,
            after_end_sector=120_037_376,
            tail_start=61_459_136_512,
            filesystem_bytes_before=1_336_934_400,
            filesystem_bytes_after=61_330_161_664,
        )
        self.assertEqual(receipt["Schema"], "pocketforge.self-flash-growth/v3")
        self.assertEqual(receipt["ControlSlotsInitialized"], "pass")
        self.assertEqual(receipt["GPTRelocation"], "pass")


if __name__ == "__main__":
    unittest.main(verbosity=2)
