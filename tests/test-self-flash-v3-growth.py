#!/usr/bin/env python3
"""Hermetic controls for bounded first-boot self-flash v3 growth."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "rootfs-overlay/usr/lib/pocketforge/self-flash-v3-grow"
STAGE_HELPER = ROOT / "rootfs-overlay/usr/lib/pocketforge/self-flash-v3-stage"
BUILDER = ROOT / "scripts/build-rootfs.sh"
CLOUD_OVERRIDE = ROOT / "rootfs-overlay/etc/cloud/cloud.cfg.d/99-pocketforge-self-flash-v3.cfg"
UNIT = ROOT / "rootfs-overlay/etc/systemd/system/pocketforge-self-flash-v3-grow.service"
sys.dont_write_bytecode = True


def load_helper(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise RuntimeError("could not create helper import spec")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


sf = load_helper("self_flash_v3_grow", HELPER)
stage = load_helper("self_flash_v3_stage_for_growth", STAGE_HELPER)
CURRENT_BOOT_ID = "11111111-2222-4333-8444-555555555555"
PRIOR_BOOT_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"


def receipt_is_eligible(path: Path, boot_id: str = CURRENT_BOOT_ID) -> bool:
    try:
        receipt = json.loads(path.read_text(encoding="ascii"))
        stage.validate_growth_receipt(receipt, boot_id)
    except (OSError, ValueError, stage.Refusal):
        return False
    return True


def write_eligible_receipt(path: Path, boot_id: str = PRIOR_BOOT_ID) -> None:
    path.write_text(
        json.dumps(
            {
                "Schema": "pocketforge.self-flash-growth/v3",
                "BootID": boot_id,
                "GPTRelocation": "pass",
                "PartitionGrowth": "pass",
                "PartitionTableReread": "pass",
                "Ext4Growth": "pass",
            }
        ),
        encoding="ascii",
    )


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

    def test_build33_qemu_two_gib_media_reproduces_reserve_refusal(self):
        # Build 33's published image is 1,466,978,304 bytes. Its real baked p5
        # ends at byte 1,466,909,696, but the acceptance harness expands the
        # medium to only 2 GiB. A 1 GiB tail reserve therefore starts below p5.
        with self.assertRaisesRegex(sf.Refusal, "reserve_too_small_for_baked_root"):
            sf.derive_growth_plan(
                card_bytes=2_147_483_648,
                partitions=self.partitions,
                baked_start_sector=self.start_sector,
                baked_sectors=self.baked_sectors,
            )


class ControlSlotTests(unittest.TestCase):
    def test_only_two_control_slots_are_zeroed_and_read_back(self):
        arm_offset = 4096
        receipt_offset = arm_offset + sf.SLOT_BYTES
        before = b"Q" * (receipt_offset + sf.SLOT_BYTES + 4096)
        device = io.BytesIO(before)

        disposition = sf.initialize_control_slots(
            device,
            arm_offset=arm_offset,
            receipt_offset=receipt_offset,
            sync=lambda: None,
        )
        self.assertEqual(disposition, "zeroed-and-read-back")
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
        self.assertIn("TimeoutStartSec=90s", unit)
        self.assertIn("ConditionPathExists=/etc/pocketforge-selfflash-v3", unit)
        self.assertIn("WantedBy=multi-user.target", unit)
        self.assertNotIn("Requires=", unit)
        self.assertNotIn("RequiredBy=", unit)

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
            boot_id=CURRENT_BOOT_ID,
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
        self.assertEqual(receipt["BootID"], CURRENT_BOOT_ID)
        self.assertEqual(receipt["ControlSlotsInitialized"], "zeroed-and-read-back")
        self.assertEqual(receipt["GPTRelocation"], "pass")

        stage.validate_growth_receipt(receipt, CURRENT_BOOT_ID)
        with self.assertRaises(stage.Refusal):
            stage.validate_growth_receipt(receipt, PRIOR_BOOT_ID)

    def test_known_growth_refusal_degrades_and_records_reason(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt_path = Path(directory) / "self-flash-v3-growth"
            with (
                mock.patch.object(sf, "RECEIPT_PATH", receipt_path),
                mock.patch.object(
                    sf,
                    "grow",
                    side_effect=sf.Refusal("reserve_too_small_for_baked_root"),
                ),
                mock.patch.object(sf.os, "geteuid", return_value=0),
                mock.patch.object(sys, "argv", ["self-flash-v3-grow"]),
            ):
                self.assertEqual(sf.main(), 0)

            receipt = json.loads(receipt_path.read_text(encoding="ascii"))
            self.assertEqual(receipt["Schema"], "pocketforge.self-flash-growth-degraded/v3")
            self.assertEqual(receipt["State"], "degraded")
            self.assertEqual(receipt["FailureReason"], "reserve_too_small_for_baked_root")

    def test_refusal_invalidates_prior_success_before_each_receipt_write_failure(self):
        class FailingOutput:
            def __init__(self, output, phase):
                self.output = output
                self.phase = phase

            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_value, traceback):
                self.output.close()
                return False

            def write(self, data):
                if self.phase == "temp_write":
                    raise OSError("injected temp write failure")
                return self.output.write(data)

            def flush(self):
                if self.phase == "temp_flush":
                    raise OSError("injected temp flush failure")
                return self.output.flush()

            def fileno(self):
                return self.output.fileno()

        phases = (
            "parent_creation",
            "preexisting_new",
            "temp_creation",
            "temp_write",
            "temp_flush",
            "temp_fsync",
            "replace",
        )
        for phase in phases:
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                receipt_path = Path(directory) / "state" / "self-flash-v3-growth"
                receipt_path.parent.mkdir()
                prior = b'{"GPTRelocation":"pass","State":"pass"}\n'
                receipt_path.write_bytes(prior)
                temporary = receipt_path.with_name(receipt_path.name + ".new")
                if phase == "preexisting_new":
                    temporary.write_bytes(b"stale temporary\n")

                real_mkdir = Path.mkdir
                real_open = sf.os.open
                real_fdopen = sf.os.fdopen
                real_fsync = sf.os.fsync

                def maybe_fail_mkdir(path, *args, **kwargs):
                    if phase == "parent_creation" and path == receipt_path.parent:
                        raise OSError("injected parent creation failure")
                    return real_mkdir(path, *args, **kwargs)

                def maybe_fail_open(path, flags, *args, **kwargs):
                    if phase == "temp_creation" and Path(path) == temporary:
                        raise OSError("injected temp creation failure")
                    return real_open(path, flags, *args, **kwargs)

                def maybe_fail_fdopen(descriptor, *args, **kwargs):
                    output = real_fdopen(descriptor, *args, **kwargs)
                    if phase in ("temp_write", "temp_flush"):
                        return FailingOutput(output, phase)
                    return output

                def maybe_fail_fsync(descriptor):
                    open_path = Path(f"/proc/self/fd/{descriptor}").resolve()
                    if phase == "temp_fsync" and open_path == temporary:
                        raise OSError("injected temp fsync failure")
                    return real_fsync(descriptor)

                replace = sf.os.replace
                if phase == "replace":
                    replace = mock.Mock(side_effect=OSError("injected replace failure"))

                with (
                    mock.patch.object(sf, "RECEIPT_PATH", receipt_path),
                    mock.patch.object(
                        sf,
                        "grow",
                        side_effect=sf.Refusal("reserve_too_small_for_baked_root"),
                    ),
                    mock.patch.object(sf.os, "geteuid", return_value=0),
                    mock.patch.object(sys, "argv", ["self-flash-v3-grow"]),
                    mock.patch.object(Path, "mkdir", maybe_fail_mkdir),
                    mock.patch.object(sf.os, "open", maybe_fail_open),
                    mock.patch.object(sf.os, "fdopen", maybe_fail_fdopen),
                    mock.patch.object(sf.os, "fsync", maybe_fail_fsync),
                    mock.patch.object(sf.os, "replace", replace),
                ):
                    self.assertEqual(sf.main(), 0)

                self.assertFalse(receipt_path.exists())
                self.assertNotEqual(
                    receipt_path.read_bytes() if receipt_path.exists() else None,
                    prior,
                )

    def test_every_invalidation_fault_rejects_stale_boot_receipt(self):
        for phase in ("open", "ftruncate", "write", "fsync", "unlink"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as directory:
                receipt_path = Path(directory) / "self-flash-v3-growth"
                write_eligible_receipt(receipt_path)
                self.assertTrue(receipt_is_eligible(receipt_path, PRIOR_BOOT_ID))
                real_open, real_ftruncate = sf.os.open, sf.os.ftruncate
                real_write, real_fsync, real_unlink = sf.os.write, sf.os.fsync, Path.unlink

                def fail_open(path, flags, *args, **kwargs):
                    if phase == "open" and Path(path) == receipt_path:
                        raise OSError("injected open failure")
                    return real_open(path, flags, *args, **kwargs)

                def fail_ftruncate(descriptor, length):
                    if phase == "ftruncate":
                        raise OSError("injected ftruncate failure")
                    return real_ftruncate(descriptor, length)

                def fail_write(descriptor, data):
                    if phase == "write":
                        raise OSError("injected write failure")
                    return real_write(descriptor, data)

                def fail_fsync(descriptor):
                    target = Path(f"/proc/self/fd/{descriptor}").resolve()
                    if phase == "fsync" and target == receipt_path:
                        raise OSError("injected fsync failure")
                    return real_fsync(descriptor)

                def fail_unlink(path, *args, **kwargs):
                    if phase == "unlink" and path == receipt_path:
                        raise OSError("injected unlink failure")
                    return real_unlink(path, *args, **kwargs)

                with (
                    mock.patch.object(sf, "RECEIPT_PATH", receipt_path),
                    mock.patch.object(sf, "grow") as grow,
                    mock.patch.object(sf.os, "geteuid", return_value=0),
                    mock.patch.object(sys, "argv", ["self-flash-v3-grow"]),
                    mock.patch.object(sf.os, "open", fail_open),
                    mock.patch.object(sf.os, "ftruncate", fail_ftruncate),
                    mock.patch.object(sf.os, "write", fail_write),
                    mock.patch.object(sf.os, "fsync", fail_fsync),
                    mock.patch.object(Path, "unlink", fail_unlink),
                ):
                    self.assertEqual(sf.main(), 2)
                grow.assert_not_called()
                self.assertFalse(receipt_is_eligible(receipt_path))

    def test_grow_rename_failure_rejects_stale_boot_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt_path = Path(directory) / "self-flash-v3-growth"
            write_eligible_receipt(receipt_path)

            def publish_current_pass():
                candidate = {
                    "Schema": "pocketforge.self-flash-growth/v3",
                    "BootID": CURRENT_BOOT_ID,
                    "GPTRelocation": "pass",
                    "PartitionGrowth": "pass",
                    "PartitionTableReread": "pass",
                    "Ext4Growth": "pass",
                }
                sf._write_receipt(candidate)
                return candidate

            with (
                mock.patch.object(sf, "RECEIPT_PATH", receipt_path),
                mock.patch.object(sf, "grow", side_effect=publish_current_pass),
                mock.patch.object(sf.os, "geteuid", return_value=0),
                mock.patch.object(sys, "argv", ["self-flash-v3-grow"]),
                mock.patch.object(sf.os, "replace", side_effect=OSError("injected rename failure")),
            ):
                self.assertEqual(sf.main(), 0)
            self.assertFalse(receipt_is_eligible(receipt_path))

    def test_pass_directory_sync_then_degraded_write_failure_leaves_no_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            receipt_path = Path(directory) / "self-flash-v3-growth"
            receipt_path.write_text('{"State":"pass","old":true}\n', encoding="ascii")
            temporary = receipt_path.with_name(receipt_path.name + ".new")
            real_open = sf.os.open
            real_fsync = sf.os.fsync
            temporary_opens = 0
            fsync_calls = 0

            def fail_second_temporary_open(path, flags, *args, **kwargs):
                nonlocal temporary_opens
                if Path(path) == temporary:
                    temporary_opens += 1
                    if temporary_opens == 2:
                        raise OSError("injected degraded temp creation failure")
                return real_open(path, flags, *args, **kwargs)

            def fail_pass_directory_sync(descriptor):
                nonlocal fsync_calls
                fsync_calls += 1
                # initial invalidation, pass temp file, then pass directory
                if fsync_calls == 3:
                    raise OSError("injected pass directory sync failure")
                return real_fsync(descriptor)

            def replace_pass_then_fail_sync():
                receipt = sf.build_degraded_receipt("fixture")
                receipt["State"] = "pass"
                sf._write_receipt(receipt)
                return receipt

            with (
                mock.patch.object(sf, "RECEIPT_PATH", receipt_path),
                mock.patch.object(sf, "grow", side_effect=replace_pass_then_fail_sync),
                mock.patch.object(sf.os, "geteuid", return_value=0),
                mock.patch.object(sys, "argv", ["self-flash-v3-grow"]),
                mock.patch.object(sf.os, "open", fail_second_temporary_open),
                mock.patch.object(sf.os, "fsync", fail_pass_directory_sync),
            ):
                self.assertEqual(sf.main(), 0)

            self.assertEqual(temporary_opens, 2)
            self.assertFalse(receipt_path.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
