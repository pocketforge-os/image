#!/usr/bin/env python3
"""Hermetic SD/card/arm/ready-state controls for the initrd v3 gate."""

from __future__ import annotations

import hashlib
import io
from importlib.machinery import SourceFileLoader
import importlib.util
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "boards/tsp/initrd/self-flash-v3.sh"
STAGER = ROOT / "rootfs-overlay/usr/lib/pocketforge/self-flash-v3-stage"
CONTRACT = ROOT / "docs/SELF-FLASH-V3.md"

loader = SourceFileLoader("self_flash_v3_stage", str(STAGER))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec and spec.loader
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class ArmFixture:
    card_bytes = 2_147_483_648
    sectors = card_bytes // 512
    root_start = 251_904
    generation = "0123456789abcdef0123456789abcdef"

    def __init__(self, root: Path) -> None:
        self.root = root
        self.sys = root / "sys/class/block"
        self.dev = root / "dev"
        self.work = root / "work"
        self.marker = root / "pocketforge-selfflash-v3"
        self.sys.mkdir(parents=True)
        self.dev.mkdir()
        self.work.mkdir()
        self._make_card("card0", "4020000", "SD", "0x1234abcd")
        self.device = self.dev / "card0"
        with self.device.open("wb") as handle:
            handle.truncate(self.card_bytes)

        self.root_sectors = self.card_bytes // 2 // 512
        tail_start = stage._align_down(
            self.card_bytes - stage.RESERVE_BYTES, stage.ALIGNMENT_BYTES
        )
        self.root_sectors = tail_start // 512 - self.root_start
        self._make_partition("card0", 5, self.root_start, self.root_sectors, "179:5")
        self.partition_sha = hashlib.sha256(
            f"5:{self.root_start}:{self.root_sectors}\n".encode("ascii")
        ).hexdigest()
        self.contract_sha = hashlib.sha256(CONTRACT.read_bytes()).hexdigest()
        self.marker.write_text(
            "\n".join(
                (
                    "Schema=pocketforge.self-flash-initrd-capability/v3",
                    f"ContractSHA256={self.contract_sha}",
                    "CardController=04020000",
                    "AlignmentBytes=4194304",
                    "ReserveBytes=1073741824",
                    "GuardBytes=4194304",
                    "ControlBytes=4194304",
                    "SeedMaxBytes=16777216",
                    "SlotBytes=65536",
                    "",
                )
            ),
            encoding="ascii",
        )
        self.request = {
            "Schema": stage.REQUEST_SCHEMA,
            "Generation": self.generation,
            "ContractSHA256": self.contract_sha,
            "BaseDescriptorSHA256": "a" * 64,
            "BaseRawSHA256": "b" * 64,
            "BaseRawBytes": 536_870_912,
            "TargetDescriptorSHA256": "c" * 64,
            "TargetRawSHA256": "d" * 64,
            "TargetRawBytes": 629_145_600,
            "CompressedSHA256": "e" * 64,
            "CompressedBytes": 4096,
            "SeedSHA256": "f" * 64,
            "SeedBytes": 10240,
            "CardSerial": "0x1234abcd",
            "CardBytes": self.card_bytes,
            "RootPartitionStartSector": self.root_start,
            "PartitionLayoutSHA256": self.partition_sha,
        }
        self.selected = {
            "serial": "0x1234abcd",
            "bytes": self.card_bytes,
            "partitions": [
                {
                    "number": 5,
                    "start": self.root_start * 512,
                    "end": (self.root_start + self.root_sectors) * 512,
                    "start_sector": self.root_start,
                    "sectors": self.root_sectors,
                }
            ],
        }
        self.layout = stage.derive_layout(
            card_bytes=self.card_bytes,
            base_raw_bytes=self.request["BaseRawBytes"],
            target_raw_bytes=self.request["TargetRawBytes"],
            compressed_bytes=self.request["CompressedBytes"],
            seed_bytes=self.request["SeedBytes"],
        )
        self.write_records()

    def _make_card(self, name: str, controller: str, card_type: str, serial: str) -> None:
        physical = (
            self.root
            / f"sys/devices/platform/soc/{controller}.mmc/mmc_host/{name}/{name}:0001"
        )
        block = physical / "block" / name
        block.mkdir(parents=True)
        (self.sys / name).symlink_to(block)
        (block / "device").symlink_to(physical)
        (block / "queue").mkdir()
        (block / "queue/logical_block_size").write_text("512\n", encoding="ascii")
        (block / "size").write_text(f"{self.sectors}\n", encoding="ascii")
        (block / "dev").write_text("179:0\n", encoding="ascii")
        (physical / "type").write_text(f"{card_type}\n", encoding="ascii")
        (physical / "serial").write_text(f"{serial}\n", encoding="ascii")

    def _make_partition(
        self, card: str, number: int, start: int, sectors: int, major_minor: str
    ) -> None:
        block = (self.sys / card).resolve()
        part = block / f"{card}p{number}"
        part.mkdir()
        (self.sys / part.name).symlink_to(part)
        (part / "partition").write_text(f"{number}\n", encoding="ascii")
        (part / "start").write_text(f"{start}\n", encoding="ascii")
        (part / "size").write_text(f"{sectors}\n", encoding="ascii")
        (part / "dev").write_text(f"{major_minor}\n", encoding="ascii")

    def _receipt(self, state_name: str) -> bytes:
        ready, _digest = stage._ready_receipt(self.request)
        payload = ready.rstrip(b"\0").decode("ascii").splitlines()
        fields = []
        for line in payload[:-2]:
            key, value = line.split("=", 1)
            if key == "State":
                value = state_name
            fields.append((key, value))
        return stage._ordered_record(fields, "ReceiptRecordSHA256")[0]

    def write_records(self, *, state_name: str = "ready", bad_tail_start: bool = False) -> None:
        layout = dict(self.layout)
        if bad_tail_start:
            layout["tail_start"] += stage.ALIGNMENT_BYTES
        arm, _digest = stage._arm_record(self.request, self.selected, layout)
        with self.device.open("r+b", buffering=0) as card:
            card.seek(self.layout["arm_offset"])
            card.write(arm)
            card.seek(self.layout["receipt_offset"])
            card.write(self._receipt(state_name))

    def run_gate(self) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "SF_V3_SYS_CLASS_BLOCK": str(self.sys),
                "SF_V3_DEV_ROOT": str(self.dev),
                "SF_V3_MARKER": str(self.marker),
                "SF_V3_EXPECTED_CONTRACT_SHA256": self.contract_sha,
                "SF_V3_ROOT_MAJOR_MINOR": "179:5",
                "SF_V3_WORK": str(self.work),
            }
        )
        command = (
            f'. "{ENGINE}"; '
            "if sf_v3_load_armed_transaction; then "
            'printf "generation=%s\\nsd=%s\\nreceipt=%s\\n" '
            '"$SF_V3_GENERATION" "$SF_V3_SD" "$SF_V3_RECEIPT_STATE"; '
            "else exit $?; fi"
        )
        return subprocess.run(
            ["/usr/bin/bash", "-c", command],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def run_shell(self, body: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "SF_V3_SYS_CLASS_BLOCK": str(self.sys),
                "SF_V3_DEV_ROOT": str(self.dev),
                "SF_V3_MARKER": str(self.marker),
                "SF_V3_EXPECTED_CONTRACT_SHA256": self.contract_sha,
                "SF_V3_ROOT_MAJOR_MINOR": "179:5",
                "SF_V3_WORK": str(self.work),
                "SF_V3_UPTIME": str(self.root / "uptime"),
            }
        )
        (self.root / "uptime").write_text("12.345 98.000\n", encoding="ascii")
        return subprocess.run(
            ["/usr/bin/bash", "-c", f'. "{ENGINE}"; {body}'],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def read_receipt(self) -> bytes:
        with self.device.open("rb", buffering=0) as card:
            card.seek(self.layout["receipt_offset"])
            return card.read(stage.SLOT_BYTES)

    def stage_seed(self, *, extra_member: bool = False) -> dict[str, bytes]:
        members = {
            "meta-data": b"instance-id: pf-v3\n",
            "network-config": b"version: 2\n",
            "user-data": b"#cloud-config\n",
        }
        if extra_member:
            members["unexpected"] = b"refuse me\n"
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name, content in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(content)
                info.mode = 0o600
                info.uid = 0
                info.gid = 0
                info.uname = ""
                info.gname = ""
                info.mtime = 0
                archive.addfile(info, io.BytesIO(content))
        payload = stream.getvalue()
        self.request["SeedBytes"] = len(payload)
        self.request["SeedSHA256"] = hashlib.sha256(payload).hexdigest()
        self.layout = stage.derive_layout(
            card_bytes=self.card_bytes,
            base_raw_bytes=self.request["BaseRawBytes"],
            target_raw_bytes=self.request["TargetRawBytes"],
            compressed_bytes=self.request["CompressedBytes"],
            seed_bytes=self.request["SeedBytes"],
        )
        self.write_records()
        with self.device.open("r+b", buffering=0) as card:
            card.seek(self.layout["seed_offset"])
            card.write(payload)
        return members


class InitrdArmTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="pf-sfv3-arm-")
        self.fixture = ArmFixture(Path(self.temporary.name))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def assert_refused(self) -> None:
        result = self.fixture.run_gate()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_valid_sd_arm_and_ready_receipt(self) -> None:
        result = self.fixture.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"generation={self.fixture.generation}\n", result.stdout)
        self.assertIn(f"sd={self.fixture.device}\n", result.stdout)
        self.assertIn("receipt=ready\n", result.stdout)

    def test_wrong_card_type_refused(self) -> None:
        type_file = next((self.fixture.root / "sys/devices").rglob("type"))
        type_file.write_text("MMC\n", encoding="ascii")
        self.assert_refused()

    def test_arm_self_hash_corruption_refused(self) -> None:
        with self.fixture.device.open("r+b", buffering=0) as card:
            card.seek(self.fixture.layout["arm_offset"] + 20)
            card.write(b"X")
        self.assert_refused()

    def test_self_hashed_wrong_layout_refused(self) -> None:
        self.fixture.write_records(bad_tail_start=True)
        self.assert_refused()

    def test_live_partition_digest_change_refused(self) -> None:
        size_file = self.fixture.sys / "card0p5/size"
        size_file.write_text(f"{self.fixture.root_sectors - 1}\n", encoding="ascii")
        self.assert_refused()

    def test_wrong_marker_contract_refused(self) -> None:
        content = self.fixture.marker.read_text(encoding="ascii")
        self.fixture.marker.write_text(
            content.replace(self.fixture.contract_sha, "0" * 64), encoding="ascii"
        )
        self.assert_refused()

    def test_non_ready_receipts_refused(self) -> None:
        for state_name in ("started", "failed", "pass"):
            with self.subTest(state=state_name):
                self.fixture.write_records(state_name=state_name)
                self.assert_refused()

    def test_started_receipt_is_durable_and_self_hashed(self) -> None:
        result = self.fixture.run_shell(
            "sf_v3_load_armed_transaction && "
            "sf_v3_receipt_defaults && "
            "SF_V3_INITRD_START_MS=$(sf_v3_now_ms) && "
            "SF_V3_WRITE_START_MS=$(sf_v3_now_ms) && "
            "sf_v3_write_receipt started none none"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        slot = self.fixture.read_receipt()
        record = slot.rstrip(b"\0")
        self.assertEqual(len(slot), stage.SLOT_BYTES)
        self.assertIn(b"State=started\n", record)
        self.assertIn(b"InitrdStartMonotonicMs=12345\n", record)
        self.assertIn(b"WriteStartMonotonicMs=12345\n", record)
        self.assertTrue(record.endswith(b"\n\n"))
        lines = record.decode("ascii").splitlines()
        stored = lines[-2].split("=", 1)[1]
        prefix = "\n".join(lines[:-2]).encode("ascii") + b"\n"
        self.assertEqual(stored, hashlib.sha256(prefix).hexdigest())

    def test_invalid_receipt_state_cannot_mutate_slot(self) -> None:
        before = self.fixture.read_receipt()
        result = self.fixture.run_shell(
            "sf_v3_load_armed_transaction && "
            "sf_v3_receipt_defaults && "
            "sf_v3_write_receipt ready none none"
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.fixture.read_receipt(), before)

    def test_seed_stream_installs_exact_three_members_on_fat(self) -> None:
        members = self.fixture.stage_seed()
        fat = self.fixture.root / "fat"
        fat.mkdir()
        result = self.fixture.run_shell(
            f'sf_v3_load_armed_transaction && sf_v3_install_seed "{fat}" && '
            'printf "seed=%s bytes=%s sha=%s\\n" "$SF_V3_SEED_RESULT" '
            '"$SF_V3_SEED_STREAM_BYTES" "$SF_V3_SEED_STREAM_SHA256"'
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("seed=pass", result.stdout)
        self.assertIn(f"bytes={self.fixture.request['SeedBytes']}", result.stdout)
        self.assertIn(f"sha={self.fixture.request['SeedSHA256']}", result.stdout)
        self.assertEqual(
            {path.name: path.read_bytes() for path in fat.iterdir()}, members
        )

    def test_seed_stream_rejects_extra_member_without_installing(self) -> None:
        self.fixture.stage_seed(extra_member=True)
        fat = self.fixture.root / "fat"
        fat.mkdir()
        result = self.fixture.run_shell(
            f'sf_v3_load_armed_transaction && sf_v3_install_seed "{fat}"'
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(
            any(
                path.name in ("meta-data", "network-config", "user-data")
                for path in fat.iterdir()
            )
        )

    def test_stamp_binds_read_back_padded_pass_receipt(self) -> None:
        fat = self.fixture.root / "fat"
        fat.mkdir()
        result = self.fixture.run_shell(
            "sf_v3_load_armed_transaction && sf_v3_receipt_defaults && "
            "SF_V3_XZ_RESULT=pass && SF_V3_RAW_STREAM_SHA256=$SF_V3_TARGET_RAW_SHA256 && "
            "SF_V3_RAW_STREAM_BYTES=$SF_V3_TARGET_RAW_BYTES && "
            "SF_V3_RAW_STREAM_HASH_MATCH=pass && SF_V3_RAW_STREAM_COUNT_MATCH=pass && "
            "SF_V3_WRITE_METHOD=dd-fsync && SF_V3_WRITE_RESULT=pass && "
            "SF_V3_SEED_RESULT=pass && SF_V3_STAMP_RESULT=pass && "
            "sf_v3_write_receipt pass none none && "
            f'sf_v3_install_stamp "{fat}"'
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt_sha = hashlib.sha256(self.fixture.read_receipt()).hexdigest()
        expected = (
            "Schema=pocketforge.self-flash-stamp/v3\n"
            f"Generation={self.fixture.generation}\n"
            f"TargetDescriptorSHA256={self.fixture.request['TargetDescriptorSHA256']}\n"
            f"TargetRawSHA256={self.fixture.request['TargetRawSHA256']}\n"
            f"TargetRawBytes={self.fixture.request['TargetRawBytes']}\n"
            f"TailReceiptSHA256={receipt_sha}\n"
        ).encode("ascii")
        self.assertEqual((fat / "pocketforge-self-flash-v3").read_bytes(), expected)

    def test_stamp_refuses_receipt_changed_after_readback(self) -> None:
        fat = self.fixture.root / "fat"
        fat.mkdir()
        command = (
            "sf_v3_load_armed_transaction && sf_v3_receipt_defaults && "
            "SF_V3_XZ_RESULT=pass && SF_V3_RAW_STREAM_SHA256=$SF_V3_TARGET_RAW_SHA256 && "
            "SF_V3_RAW_STREAM_BYTES=$SF_V3_TARGET_RAW_BYTES && "
            "SF_V3_RAW_STREAM_HASH_MATCH=pass && SF_V3_RAW_STREAM_COUNT_MATCH=pass && "
            "SF_V3_WRITE_METHOD=dd-fsync && SF_V3_WRITE_RESULT=pass && "
            "SF_V3_SEED_RESULT=pass && SF_V3_STAMP_RESULT=pass && "
            "sf_v3_write_receipt pass none none && "
            'printf X | dd of="$SF_V3_SD" bs=1 seek="$SF_V3_RECEIPT_OFFSET" '
            "conv=notrunc status=none && "
            f'sf_v3_install_stamp "{fat}"'
        )
        result = self.fixture.run_shell(command)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((fat / "pocketforge-self-flash-v3").exists())


if __name__ == "__main__":
    unittest.main()
