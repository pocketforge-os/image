#!/usr/bin/env python3
"""Hermetic SD/card/arm/ready-state controls for the initrd v3 gate."""

from __future__ import annotations

import hashlib
import io
from importlib.machinery import SourceFileLoader
import importlib.util
import lzma
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "boards/tsp/initrd/self-flash-v3.sh"
INIT = ROOT / "boards/tsp/initrd/init"
STAGER = ROOT / "rootfs-overlay/usr/lib/pocketforge/self-flash-v3-stage"
GROWER = ROOT / "rootfs-overlay/usr/lib/pocketforge/self-flash-v3-grow"
CONTRACT = ROOT / "docs/SELF-FLASH-V3.md"

loader = SourceFileLoader("self_flash_v3_stage", str(STAGER))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec and spec.loader
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)

grow_loader = SourceFileLoader("self_flash_v3_grow_for_arm_test", str(GROWER))
grow_spec = importlib.util.spec_from_loader(grow_loader.name, grow_loader)
assert grow_spec and grow_spec.loader
grow = importlib.util.module_from_spec(grow_spec)
grow_spec.loader.exec_module(grow)


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
        self.primary_block = (self.sys / "card0").resolve()
        self.primary_partition = (self.sys / "card0p5").resolve()
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

    def _make_replacement_card(self) -> Path:
        physical = (
            self.root
            / "sys/devices/platform/soc/4020000.mmc/mmc_host/replacement/replacement:0001"
        )
        block = physical / "block/card0"
        block.mkdir(parents=True, exist_ok=True)
        if not (block / "device").exists():
            (block / "device").symlink_to(physical)
        (block / "queue").mkdir(exist_ok=True)
        (block / "queue/logical_block_size").write_text("512\n", encoding="ascii")
        (block / "size").write_text(f"{self.sectors}\n", encoding="ascii")
        (block / "dev").write_text("179:0\n", encoding="ascii")
        (physical / "type").write_text("SD\n", encoding="ascii")
        (physical / "serial").write_text("0x1234abcd\n", encoding="ascii")
        part = block / "card0p5"
        part.mkdir(exist_ok=True)
        (part / "partition").write_text("5\n", encoding="ascii")
        (part / "start").write_text(f"{self.root_start}\n", encoding="ascii")
        (part / "size").write_text(f"{self.root_sectors}\n", encoding="ascii")
        (part / "dev").write_text("179:5\n", encoding="ascii")
        return block

    def _restore_primary_card_links(self) -> None:
        for name, target in (
            ("card0", self.primary_block),
            ("card0p5", self.primary_partition),
        ):
            link = self.sys / name
            link.unlink(missing_ok=True)
            link.symlink_to(target)

    def _receipt(self, state_name: str, *, completed: bool = False) -> bytes:
        ready, _digest = stage._ready_receipt(self.request)
        payload = ready.rstrip(b"\0").decode("ascii").splitlines()
        pass_values = {
            "XzIntegrity": "pass",
            "RawStreamSHA256": self.request["TargetRawSHA256"],
            "RawStreamBytes": str(self.request["TargetRawBytes"]),
            "RawStreamHashMatch": "pass",
            "RawStreamCountMatch": "pass",
            "WriteMethod": "dd-fsync",
            "WriteResult": "pass",
            "SeedResult": "pass",
            "StampResult": "pass",
        }
        fields = []
        for line in payload[:-2]:
            key, value = line.split("=", 1)
            if key == "State":
                value = state_name
            elif completed:
                value = pass_values.get(key, value)
            fields.append((key, value))
        return stage._ordered_record(fields, "ReceiptRecordSHA256")[0]

    def write_records(
        self,
        *,
        state_name: str = "ready",
        bad_tail_start: bool = False,
        completed: bool = False,
    ) -> None:
        layout = dict(self.layout)
        if bad_tail_start:
            layout["tail_start"] += stage.ALIGNMENT_BYTES
        arm, _digest = stage._arm_record(self.request, self.selected, layout)
        with self.device.open("r+b", buffering=0) as card:
            card.seek(self.layout["arm_offset"])
            card.write(arm)
            card.seek(self.layout["receipt_offset"])
            card.write(self._receipt(state_name, completed=completed))

    def completed_stamp(self) -> dict[str, str]:
        receipt = self._receipt("pass", completed=True)
        return {
            "Schema": "pocketforge.self-flash-stamp/v3",
            "Generation": self.generation,
            "TargetDescriptorSHA256": self.request["TargetDescriptorSHA256"],
            "TargetRawSHA256": self.request["TargetRawSHA256"],
            "TargetRawBytes": str(self.request["TargetRawBytes"]),
            "TailReceiptSHA256": hashlib.sha256(receipt).hexdigest(),
        }

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
            'else rc=$?; printf "load=%s\\n" "${SF_V3_LOAD_STATE:-unknown}" >&2; '
            "exit $rc; fi"
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

    def run_pid1_gate(
        self, *, extra_mount: bool = False, invalidate_sd: str = ""
    ) -> subprocess.CompletedProcess[str]:
        """Execute the production v3 PID1 gate with hermetic boot primitives."""
        source = INIT.read_text(encoding="utf-8")
        start = source.index("# BEGIN POCKETFORGE SELF-FLASH V3 GATE")
        end = source.index("# END POCKETFORGE SELF-FLASH V3 GATE")
        gate = source[start:end]
        gate = gate.replace(
            "[ -f /lib/pocketforge-self-flash-v3.sh ]", "true"
        )
        gate_path = self.root / "pid1-v3-gate.sh"
        gate_path.write_text(gate, encoding="utf-8")

        mountinfo = self.root / "mountinfo"
        records = [
            "24 1 179:4 / /pflog rw - vfat /dev/card0p4 rw\n",
        ]
        if extra_mount:
            records.append(
                "25 1 179:5 / /selected-root rw - ext4 /dev/card0p5 rw\n"
            )
        mountinfo.write_text("".join(records), encoding="ascii")

        env = os.environ.copy()
        replacement = self._make_replacement_card()
        env.update(
            {
                "SF_V3_SYS_CLASS_BLOCK": str(self.sys),
                "SF_V3_DEV_ROOT": str(self.dev),
                "SF_V3_MARKER": str(self.marker),
                "SF_V3_EXPECTED_CONTRACT_SHA256": self.contract_sha,
                "SF_V3_ROOT_MAJOR_MINOR": "179:5",
                "SF_V3_WORK": str(self.work),
                "SF_MOUNTINFO_FILE": str(mountinfo),
                "PF_TEST_INVALIDATE_SD": invalidate_sd,
                "PF_TEST_REPLACEMENT_BLOCK": str(replacement),
            }
        )
        command = f'''
            . "{ENGINE}"
            eval "$(declare -f sf_v3_load_armed_transaction | sed \
                '1s/sf_v3_load_armed_transaction/sf_v3_load_armed_transaction_real/')"
            sf_v3_load_armed_transaction() {{
                sf_v3_load_armed_transaction_real || return
                case "$PF_TEST_INVALIDATE_SD" in
                    empty) SF_V3_SD= ;;
                    unresolved) SF_V3_SD="$SF_V3_DEV_ROOT/missing-card" ;;
                    swap)
                        rm "$SF_V3_SYS_CLASS_BLOCK/card0" \
                            "$SF_V3_SYS_CLASS_BLOCK/card0p5"
                        ln -s "$PF_TEST_REPLACEMENT_BLOCK" \
                            "$SF_V3_SYS_CLASS_BLOCK/card0"
                        ln -s "$PF_TEST_REPLACEMENT_BLOCK/card0p5" \
                            "$SF_V3_SYS_CLASS_BLOCK/card0p5"
                        ;;
                esac
            }}
            PF_ROOT_MODE=normal
            PFLOG=present
            log() {{ printf 'LOG:%s\\n' "$*"; }}
            watchdog_ping() {{ :; }}
            sf_wait_for_root() {{ return 0; }}
            pf_first_frame_reap() {{ :; }}
            watchdog_disarm_for_selfflash() {{ printf 'WATCHDOG_DISARMED\\n'; }}
            sf_v3_run_armed_transaction() {{ printf 'TRANSACTION_ENTERED\\n'; return 1; }}
            sync() {{ :; }}
            umount() {{
                [ "$1" = /pflog ] || return 1
                awk '$5 != "/pflog"' "$SF_MOUNTINFO_FILE" \
                    >"$SF_MOUNTINFO_FILE.next" || return 1
                mv "$SF_MOUNTINFO_FILE.next" "$SF_MOUNTINFO_FILE"
            }}
            . "{gate_path}"
        '''
        result = subprocess.run(
            ["/usr/bin/bash", "-c", command],
            env=env,
            text=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if invalidate_sd == "swap":
            self._restore_primary_card_links()
        return result

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

    def stage_candidate(self, raw: bytes, *, corrupt: bool = False) -> None:
        compressed = lzma.compress(raw, format=lzma.FORMAT_XZ)
        if corrupt:
            compressed = compressed[:-8]
        self.request["TargetRawBytes"] = len(raw)
        self.request["TargetRawSHA256"] = hashlib.sha256(raw).hexdigest()
        self.request["CompressedBytes"] = len(compressed)
        self.request["CompressedSHA256"] = hashlib.sha256(compressed).hexdigest()
        self.layout = stage.derive_layout(
            card_bytes=self.card_bytes,
            base_raw_bytes=self.request["BaseRawBytes"],
            target_raw_bytes=self.request["TargetRawBytes"],
            compressed_bytes=self.request["CompressedBytes"],
            seed_bytes=self.request["SeedBytes"],
        )
        self.write_records()
        with self.device.open("r+b", buffering=0) as card:
            card.seek(self.layout["stage_offset"])
            card.write(compressed)


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

    def test_initrd_uses_type_and_stable_identity_fallbacks(self) -> None:
        physical = next((self.fixture.root / "sys/devices").rglob("card0:0001"))

        (physical / "uevent").write_text(
            "DRIVER=mmcblk\nMMC_TYPE=SD\n", encoding="ascii"
        )
        (physical / "type").unlink()
        type_fallback = self.fixture.run_gate()
        self.assertEqual(
            type_fallback.returncode, 0, type_fallback.stdout + type_fallback.stderr
        )

        (physical / "type").write_text("SD\n", encoding="ascii")
        (physical / "serial").unlink()
        cid = "1b534d3030303030107f4f8d7a019f00"
        (physical / "cid").write_text(f"{cid}\n", encoding="ascii")
        self.fixture.request["CardSerial"] = f"cid:{cid}"
        self.fixture.selected["serial"] = f"cid:{cid}"
        self.fixture.write_records()
        identity_fallback = self.fixture.run_gate()
        self.assertEqual(
            identity_fallback.returncode,
            0,
            identity_fallback.stdout + identity_fallback.stderr,
        )

    def test_initrd_identity_fallbacks_remain_fail_closed(self) -> None:
        physical = next((self.fixture.root / "sys/devices").rglob("card0:0001"))
        (physical / "uevent").write_text(
            "DRIVER=mmcblk\nMMC_TYPE=MMC\n", encoding="ascii"
        )
        self.assert_refused()

        (physical / "uevent").write_text(
            "DRIVER=mmcblk\nMMC_TYPE=SD\n", encoding="ascii"
        )
        (physical / "serial").unlink()
        (physical / "cid").write_text("not-a-cid\n", encoding="ascii")
        self.assert_refused()

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
                result = self.fixture.run_gate()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("load=stale\n", result.stderr)

    def test_non_transaction_returns_release_pinned_card(self) -> None:
        body = r'''
            if sf_v3_load_armed_transaction; then
                exit 90
            fi
            [ ! -e /proc/$$/fd/9 ] || {
                printf 'pinned_fd=open\n' >&2
                exit 91
            }
            [ -z "${SF_V3_SD_IO:-}" ] || {
                printf 'pinned_path=%s\n' "$SF_V3_SD_IO" >&2
                exit 92
            }
            printf 'load=%s pinned_fd=closed\n' "$SF_V3_LOAD_STATE"
        '''

        for state_name, expected_state in ((None, "absent"), ("started", "stale")):
            with self.subTest(state=expected_state):
                if state_name is None:
                    with self.fixture.device.open("r+b", buffering=0) as card:
                        card.seek(self.fixture.layout["arm_offset"])
                        card.write(b"\0" * stage.SLOT_BYTES)
                        card.seek(self.fixture.layout["receipt_offset"])
                        card.write(b"\0" * stage.SLOT_BYTES)
                else:
                    self.fixture.write_records(state_name=state_name)
                result = self.fixture.run_shell(body)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(
                    f"load={expected_state} pinned_fd=closed\n", result.stdout
                )

    def test_zero_control_slots_report_absent(self) -> None:
        with self.fixture.device.open("r+b", buffering=0) as card:
            card.seek(self.fixture.layout["arm_offset"])
            card.write(b"\0" * stage.SLOT_BYTES)
            card.seek(self.fixture.layout["receipt_offset"])
            card.write(b"\0" * stage.SLOT_BYTES)
        result = self.fixture.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("load=absent\n", result.stderr)

    def test_fresh_image_layout_boots_but_near_capped_drift_refuses(self) -> None:
        size_file = self.fixture.sys / "card0p5/size"
        with self.fixture.device.open("r+b", buffering=0) as card:
            card.seek(self.fixture.layout["arm_offset"])
            card.write(b"\0" * stage.SLOT_BYTES)
            card.seek(self.fixture.layout["receipt_offset"])
            card.write(b"\0" * stage.SLOT_BYTES)

        # A raw-image write leaves partition 5 at its baked size. On the QEMU
        # acceptance disk this end is well beyond the card-relative tail start;
        # on the physical 62.5 GB card it is far below it. Neither layout can
        # have been armed by the typed v3 staging operation, so first boot must
        # reach the normal root where the capped-growth unit initializes it.
        size_file.write_text("2611200\n", encoding="ascii")
        card_size_file = self.fixture.sys / "card0/size"
        for card_sectors in (self.fixture.sectors, self.fixture.sectors * 2):
            with self.subTest(card_sectors=card_sectors):
                card_size_file.write_text(f"{card_sectors}\n", encoding="ascii")
                fresh = self.fixture.run_gate()
                self.assertNotEqual(
                    fresh.returncode, 0, fresh.stdout + fresh.stderr
                )
                self.assertIn("load=uninitialized\n", fresh.stderr)

        # Negative control: a sub-alignment change to an otherwise capped live
        # layout is damage or stale state, not a recognizable fresh image.
        card_size_file.write_text(f"{self.fixture.sectors}\n", encoding="ascii")
        size_file.write_text(f"{self.fixture.root_sectors - 1}\n", encoding="ascii")
        drifted = self.fixture.run_gate()
        self.assertNotEqual(drifted.returncode, 0, drifted.stdout + drifted.stderr)
        self.assertIn("load=refused\n", drifted.stderr)

        gate = INIT.read_text(encoding="utf-8")
        self.assertIn("uninitialized)", gate)

    def test_fresh_layout_rewrite_clears_every_stale_receipt_before_next_boot(self) -> None:
        size_file = self.fixture.sys / "card0p5/size"
        for state_name in ("ready", "started", "failed", "pass"):
            with self.subTest(state=state_name):
                self.fixture.write_records(state_name=state_name)
                size_file.write_text("2611200\n", encoding="ascii")
                fresh = self.fixture.run_gate()
                self.assertNotEqual(fresh.returncode, 0, fresh.stdout + fresh.stderr)
                self.assertIn("load=uninitialized\n", fresh.stderr)

                with self.fixture.device.open("r+b", buffering=0) as card:
                    disposition = grow.initialize_control_slots(
                        card,
                        arm_offset=self.fixture.layout["arm_offset"],
                        receipt_offset=self.fixture.layout["receipt_offset"],
                        sync=lambda: None,
                    )
                self.assertEqual(disposition, "zeroed-and-read-back")

                size_file.write_text(f"{self.fixture.root_sectors}\n", encoding="ascii")
                next_boot = self.fixture.run_gate()
                self.assertNotEqual(
                    next_boot.returncode, 0, next_boot.stdout + next_boot.stderr
                )
                self.assertIn("load=absent\n", next_boot.stderr)

    def test_completed_fresh_handoff_is_consumed_before_second_boot(self) -> None:
        size_file = self.fixture.sys / "card0p5/size"
        self.fixture.write_records(state_name="pass", completed=True)
        size_file.write_text("2611200\n", encoding="ascii")
        first_boot = self.fixture.run_gate()
        self.assertNotEqual(first_boot.returncode, 0, first_boot.stdout + first_boot.stderr)
        self.assertIn("load=uninitialized\n", first_boot.stderr)

        with self.fixture.device.open("r+b", buffering=0) as card:
            disposition = grow.initialize_control_slots(
                card,
                arm_offset=self.fixture.layout["arm_offset"],
                receipt_offset=self.fixture.layout["receipt_offset"],
                sync=lambda: None,
                success_stamp=self.fixture.completed_stamp(),
            )
        self.assertEqual(disposition, "consumed-completed-handoff")

        size_file.write_text(f"{self.fixture.root_sectors}\n", encoding="ascii")
        second_boot = self.fixture.run_gate()
        self.assertNotEqual(second_boot.returncode, 0, second_boot.stdout + second_boot.stderr)
        self.assertIn("load=absent\n", second_boot.stderr)

        self.fixture.write_records(state_name="pass", completed=True)
        mismatched_stamp = self.fixture.completed_stamp()
        mismatched_stamp["TailReceiptSHA256"] = "0" * 64
        with self.fixture.device.open("r+b", buffering=0) as card:
            disposition = grow.initialize_control_slots(
                card,
                arm_offset=self.fixture.layout["arm_offset"],
                receipt_offset=self.fixture.layout["receipt_offset"],
                sync=lambda: None,
                success_stamp=mismatched_stamp,
            )
        self.assertEqual(disposition, "zeroed-and-read-back")

    def test_pid1_gate_is_fail_closed_and_watchdog_ordered(self) -> None:
        source = INIT.read_text(encoding="utf-8")
        start = source.index("# BEGIN POCKETFORGE SELF-FLASH V3 GATE")
        end = source.index("# END POCKETFORGE SELF-FLASH V3 GATE")
        gate = source[start:end]
        self.assertIn("sf_v3_load_armed_transaction", gate)
        self.assertIn("SF_V3_LOAD_STATE", gate)
        self.assertIn("sf_v3_terminal_recovery", gate)
        self.assertIn("watchdog_disarm_for_selfflash\n", gate)
        disarm = gate.index("watchdog_disarm_for_selfflash\n")
        execute = gate.index("sf_v3_run_armed_transaction", disarm)
        self.assertLess(disarm, execute)
        self.assertNotIn("return 1", gate[execute:])

    def test_pid1_v3_gate_uses_v3_card_identity_and_mount_state(self) -> None:
        admitted = self.fixture.run_pid1_gate()
        self.assertIn("selfflash-v3: admitted", admitted.stdout)
        self.assertIn("WATCHDOG_DISARMED\n", admitted.stdout)
        self.assertIn("TRANSACTION_ENTERED\n", admitted.stdout)
        self.assertNotIn("selected SD remains mounted", admitted.stdout)

        mounted = self.fixture.run_pid1_gate(extra_mount=True)
        self.assertNotIn("WATCHDOG_DISARMED\n", mounted.stdout)
        self.assertIn(
            "selected SD remains mounted dev=179:5 mnt=/selected-root",
            mounted.stdout,
        )

        for invalid in ("empty", "unresolved"):
            with self.subTest(invalid=invalid):
                no_identity = self.fixture.run_pid1_gate(invalidate_sd=invalid)
                self.assertNotIn("WATCHDOG_DISARMED\n", no_identity.stdout)
                self.assertIn("selected SD has no card identity", no_identity.stdout)

        swapped = self.fixture.run_pid1_gate(invalidate_sd="swap")
        self.assertNotIn("WATCHDOG_DISARMED\n", swapped.stdout)
        self.assertIn("selected SD card identity changed", swapped.stdout)

        v3_partition = self.fixture.run_shell(
            "sf_v3_load_armed_transaction && "
            "SF_SD_SYS=$SF_V3_SYS_CLASS_BLOCK/not-the-v3-card && "
            "sf_v3_partition_on_selected_card $SF_V3_DEV_ROOT/card0p5"
        )
        self.assertEqual(
            v3_partition.returncode,
            0,
            v3_partition.stdout + v3_partition.stderr,
        )

        replacement = self.fixture._make_replacement_card()
        try:
            stale_boundaries = self.fixture.run_shell(
                "sf_v3_load_armed_transaction && "
                "rm $SF_V3_SYS_CLASS_BLOCK/card0 "
                "$SF_V3_SYS_CLASS_BLOCK/card0p5 && "
                f"ln -s {replacement} $SF_V3_SYS_CLASS_BLOCK/card0 && "
                f"ln -s {replacement / 'card0p5'} "
                "$SF_V3_SYS_CLASS_BLOCK/card0p5 && "
                "! sf_v3_partition_on_selected_card "
                "$SF_V3_DEV_ROOT/card0p5"
            )
        finally:
            self.fixture._restore_primary_card_links()
        self.assertEqual(
            stale_boundaries.returncode,
            0,
            stale_boundaries.stdout + stale_boundaries.stderr,
        )

        # The v2 gate retains its existing SF_SD_SYS-based behavior.
        v2 = self.fixture.run_shell(
            f'''awk '/^# BEGIN POCKETFORGE SELF-FLASH V2 FUNCTIONS$/ {{copy=1; next}}
                /^# END POCKETFORGE SELF-FLASH V2 FUNCTIONS$/ {{copy=0}}
                copy {{print}}' "{INIT}" >"$SF_V3_WORK/v2-functions" &&
                . "$SF_V3_WORK/v2-functions" &&
                SF_SYS_CLASS_BLOCK="$SF_V3_SYS_CLASS_BLOCK" &&
                SF_SD_SYS="$SF_V3_SYS_CLASS_BLOCK/card0" &&
                SF_MOUNTINFO_FILE="{self.fixture.root / 'v2-mountinfo'}" &&
                : >"$SF_MOUNTINFO_FILE" &&
                sf_v2_selected_card_unmounted'''
        )
        self.assertEqual(v2.returncode, 0, v2.stdout + v2.stderr)

    def test_transaction_io_stays_bound_after_device_path_replacement(self) -> None:
        admitted = self.fixture.dev / "card0.admitted"
        replacement = self.fixture.device
        result = self.fixture.run_shell(
            "sf_v3_load_armed_transaction && "
            "sf_v3_selected_card_unmounted && "
            f'mv "$SF_V3_SD" "{admitted}" && '
            'truncate -s "$SF_V3_CARD_BYTES" "$SF_V3_SD" && '
            "printf REPLACED | dd of=\"$SF_V3_SD\" bs=1 conv=notrunc status=none && "
            "SF_V3_TARGET_RAW_BYTES=8 && "
            "printf ORIGINAL | sf_v3_write_sink && "
            "sf_v3_receipt_defaults && "
            "sf_v3_write_receipt started none none"
        )
        try:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            with admitted.open("rb", buffering=0) as card:
                self.assertEqual(card.read(8), b"ORIGINAL")
                card.seek(self.fixture.layout["receipt_offset"])
                admitted_receipt = card.read(stage.SLOT_BYTES)
            with replacement.open("rb", buffering=0) as card:
                self.assertEqual(card.read(8), b"REPLACED")
                card.seek(self.fixture.layout["receipt_offset"])
                replacement_receipt = card.read(stage.SLOT_BYTES)
            self.assertIn(b"State=started\n", admitted_receipt.rstrip(b"\0"))
            self.assertEqual(replacement_receipt, b"\0" * stage.SLOT_BYTES)
        finally:
            replacement.unlink(missing_ok=True)
            if admitted.exists():
                admitted.rename(replacement)

    def test_target_fat_mount_stays_bound_after_partition_path_replacement(self) -> None:
        partition = self.fixture.dev / "card0p5"
        admitted = self.fixture.dev / "card0p5.admitted"
        partition.write_bytes(b"ADMITTED")
        result = self.fixture.run_shell(
            "sf_v3_load_armed_transaction && "
            "blockdev() { :; }; "
            "sf_drop_cache() { :; }; "
            f'findfs() {{ printf "%s\\n" "{partition}"; }}; '
            "mkdir() { :; }; "
            "mount() { "
            f'mv "$SF_V3_FAT_DEVICE" "{admitted}" && '
            'printf REPLACED >"$SF_V3_FAT_DEVICE" && '
            'dd if="$5" bs=8 count=1 status=none; '
            "}; "
            "sf_v3_mount_target_fat"
        )
        try:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, "ADMITTED")
            self.assertEqual(partition.read_bytes(), b"REPLACED")
        finally:
            partition.unlink(missing_ok=True)
            admitted.unlink(missing_ok=True)

    def test_pid1_initializes_v3_work_before_source_and_gate(self) -> None:
        source = INIT.read_text(encoding="utf-8")
        assignment = 'SF_V3_WORK=/run/pocketforge-self-flash-v3'
        initialization = 'mkdir -p "$SF_V3_WORK"'
        export = 'export SF_V3_WORK'
        engine_source = '. /lib/pocketforge-self-flash-v3.sh'
        gate = '# BEGIN POCKETFORGE SELF-FLASH V3 GATE'

        for token in (assignment, initialization, export, engine_source, gate):
            self.assertIn(token, source)
        self.assertLess(source.index(assignment), source.index(initialization))
        self.assertLess(source.index(initialization), source.index(export))
        self.assertLess(source.index(export), source.index(engine_source))
        self.assertLess(source.index(engine_source), source.index(gate))

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

    def test_two_generations_replace_stamp_without_full_readback(self) -> None:
        members = self.fixture.stage_seed()
        raw = (b"PocketForge-v3-target\n" * 128) + b"end\n"
        self.fixture.stage_candidate(raw)
        fat = self.fixture.root / "fat"
        fat.mkdir()
        transaction = (
            f'SF_V3_TEST_FAT="{fat}"; '
            'sf_v3_mount_target_fat() { SF_V3_FAT="$SF_V3_TEST_FAT"; }; '
            "sf_v3_unmount_target_fat() { :; }; "
            "sf_v3_load_armed_transaction && sf_v3_run_armed_transaction"
        )
        result = self.fixture.run_shell(transaction)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with self.fixture.device.open("rb", buffering=0) as card:
            self.assertEqual(card.read(len(raw)), raw)
        receipt = self.fixture.read_receipt().rstrip(b"\0")
        self.assertIn(b"State=pass\n", receipt)
        self.assertIn(b"FullDeviceReadback=not-performed\n", receipt)
        self.assertEqual(
            {path.name: path.read_bytes() for path in fat.iterdir() if path.name != "pocketforge-self-flash-v3"},
            members,
        )
        self.assertTrue((fat / "pocketforge-self-flash-v3").is_file())

        stamp_path = fat / "pocketforge-self-flash-v3"
        first_stamp = dict(line.split("=", 1) for line in stamp_path.read_text().splitlines())
        with self.fixture.device.open("r+b", buffering=0) as card:
            disposition = grow.initialize_control_slots(
                card, arm_offset=self.fixture.layout["arm_offset"],
                receipt_offset=self.fixture.layout["receipt_offset"],
                sync=lambda: None, success_stamp=first_stamp)
        self.assertEqual(disposition, "consumed-completed-handoff")
        next_generation = "123456789abcdef0123456789abcdef0"
        self.fixture.request["Generation"] = next_generation
        self.fixture.stage_candidate(b"PocketForge-v3-next-target\n" * 128)
        result = self.fixture.run_shell(transaction)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"Generation={next_generation}\n", stamp_path.read_text())

    def test_corrupt_xz_records_failed_and_omits_stamp(self) -> None:
        self.fixture.stage_seed()
        self.fixture.stage_candidate(b"target bytes\n" * 64, corrupt=True)
        fat = self.fixture.root / "fat"
        fat.mkdir()
        result = self.fixture.run_shell(
            f'SF_V3_TEST_FAT="{fat}"; '
            'sf_v3_mount_target_fat() { SF_V3_FAT="$SF_V3_TEST_FAT"; }; '
            "sf_v3_unmount_target_fat() { :; }; "
            "sf_v3_load_armed_transaction && sf_v3_run_armed_transaction"
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        receipt = self.fixture.read_receipt().rstrip(b"\0")
        self.assertIn(b"State=failed\n", receipt)
        self.assertNotIn(b"State=ready\n", receipt)
        self.assertFalse((fat / "pocketforge-self-flash-v3").exists())


if __name__ == "__main__":
    unittest.main()
