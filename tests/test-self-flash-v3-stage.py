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


class DeviceDiscoveryTests(unittest.TestCase):
    @staticmethod
    def _sysfs_card(
        directory: str,
        *,
        card_type: str | None,
        uevent_type: str | None,
        serial: str | None,
        cid: str | None,
    ) -> tuple[Path, Path]:
        root = Path(directory)
        sys_block = root / "sys/class/block"
        card_device = root / "devices/platform/soc/4020000.mmc/mmc0/mmc0:0001"
        card_block = root / "devices/virtual/block/mmcblk0"
        partition = card_block / "mmcblk0p5"
        for path in (sys_block, card_device, card_block / "queue", partition):
            path.mkdir(parents=True, exist_ok=True)
        (sys_block / "mmcblk0").symlink_to(card_block)
        (sys_block / "mmcblk0p5").symlink_to(partition)
        (card_block / "device").symlink_to(card_device)
        (card_block / "size").write_text("122138624\n", encoding="ascii")
        (card_block / "queue/logical_block_size").write_text("512\n", encoding="ascii")
        (partition / "partition").write_text("5\n", encoding="ascii")
        (partition / "start").write_text("251904\n", encoding="ascii")
        (partition / "size").write_text("2613248\n", encoding="ascii")
        (partition / "dev").write_text("179:5\n", encoding="ascii")
        if card_type is not None:
            (card_device / "type").write_text(f"{card_type}\n", encoding="ascii")
        if uevent_type is not None:
            (card_device / "uevent").write_text(
                f"DRIVER=mmcblk\nMMC_TYPE={uevent_type}\n", encoding="ascii"
            )
        if serial is not None:
            (card_device / "serial").write_text(f"{serial}\n", encoding="ascii")
        if cid is not None:
            (card_device / "cid").write_text(f"{cid}\n", encoding="ascii")
        return sys_block, root / "dev"

    def test_discovery_uses_same_card_uevent_and_cid_fallbacks(self):
        with tempfile.TemporaryDirectory(prefix="pf-sf3-discovery-") as directory:
            sys_block, dev_root = self._sysfs_card(
                directory,
                card_type=None,
                uevent_type="SD",
                serial=None,
                cid="1b534d3030303030107f4f8d7a019f00",
            )
            with mock.patch.object(sf, "SYS_BLOCK", sys_block), mock.patch.object(
                sf, "DEV_ROOT", dev_root
            ):
                cards = sf._discover_cards()
            selected = sf.select_sd(cards, root_major_minor="179:5")
            self.assertEqual(selected["card_type"], "SD")
            self.assertEqual(selected["serial"], "cid:1b534d3030303030107f4f8d7a019f00")
            self.assertEqual(selected["partition5_major_minor"], "179:5")

    def test_discovery_fallbacks_remain_fail_closed(self):
        scenarios = (
            ("emmc", None, "MMC", None, "1b534d3030303030107f4f8d7a019f00", "sd_selection_not_unique"),
            ("type-conflict", "SD", "MMC", "0x1234abcd", None, "card_type_mismatch"),
            ("malformed-cid", None, "SD", None, "not-a-cid", "card_serial_unreadable"),
            ("identity-missing", None, None, None, None, "card_type_unreadable"),
        )
        for name, card_type, uevent_type, serial, cid, refusal in scenarios:
            with self.subTest(name=name), tempfile.TemporaryDirectory(
                prefix=f"pf-sf3-discovery-{name}-"
            ) as directory:
                sys_block, dev_root = self._sysfs_card(
                    directory,
                    card_type=card_type,
                    uevent_type=uevent_type,
                    serial=serial,
                    cid=cid,
                )
                with mock.patch.object(sf, "SYS_BLOCK", sys_block), mock.patch.object(
                    sf, "DEV_ROOT", dev_root
                ), self.assertRaisesRegex(sf.Refusal, f"^{refusal}$"):
                    cards = sf._discover_cards()
                    sf.select_sd(cards, root_major_minor="179:5")


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
            for invocation_id, result, active_state, refusal in (
                ("1" * 32, "success", "inactive", None),
                ("2" * 32, "success", "inactive", "growth_receipt_invocation_mismatch"),
                ("1" * 32, "failed", "inactive", "growth_unit_not_successful"),
                ("1" * 32, "success", "activating", "growth_pending"),
                ("", "success", "inactive", "growth_pending"),
            ):
                with self.subTest(
                    invocation_id=invocation_id,
                    result=result,
                    active_state=active_state,
                ):
                    self._fake_systemctl(systemctl_path, invocation_id, result, active_state)
                    patches = (
                        mock.patch.object(sf, "GROWTH_RECEIPT_PATH", receipt_path, create=True),
                        mock.patch.object(sf, "BOOT_ID_PATH", boot_id_path, create=True),
                        mock.patch.object(sf, "SYSTEMCTL_PATH", systemctl_path, create=True),
                    )
                    with patches[0], patches[1], patches[2]:
                        if refusal is None:
                            sf._require_current_growth_receipt()
                        else:
                            with self.assertRaisesRegex(sf.Refusal, f"^{refusal}$"):
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
