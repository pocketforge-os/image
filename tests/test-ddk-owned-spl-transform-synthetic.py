#!/usr/bin/env python3
"""Behaviour gate for scripts/ddk-owned-spl-transform.py on a hermetic synthetic mini-image (tsp-e9830c0f6d28eaaa3977).

The real input is the 1.1 GB closed-DDK image 31271d56; CI cannot carry it, so this test builds a ~60 MiB image with
the same shape: GPT (boot, env, env-redund, boot-resource FAT32 serial 52A7C97E, userdata), a vendor eGON BOOT0 at
128 KiB, a sunxi-package boot_package at 16 MiB + 16 KiB whose `dtb` item is a small FDT, and an Android v0 boot.img
on p1 carrying an arm64 Image header + ramdisk. The owned SPL+FIT stand-in is an eGON.BT0 blob of exactly
0xF8400 - 0x20000 bytes.

Gap sheet Row 5 checks 1-7 are the transform's own `verify`. For every check this test mutates one byte (or one
input) that only that check is meant to catch and asserts verify fails closed with that check named FAIL:
  1 range compare vs the DDK image        -> a byte in p5 / the boot_package / the 8 KiB area
  2 owned region sha + eGON checksum      -> a byte inside [0x20000, 0xF8400); an SPL with a bad eGON checksum
  3 GPT table + FAT p4 consistency        -> the second FAT copy disagrees with the first
  4 read-back sha of Image/initrd/dtb     -> a byte inside the Image data clusters
  5 dtb reserved-memory content           -> the bl31 reg size cell changes
  6 address map                           -> a DDK whose kernel image_size reaches the 0x48000000 memreserve
  7 reproducible rebuild == image         -> a byte in a free FAT p4 cluster (inside the allowed p4 range)

Fixture tools: mkfs.vfat + mcopy (dosfstools/mtools, present on the pf-builder-vm runner) and sfdisk. The verify
cross-checks also call sfdisk, fsck.vfat, mtype, fdtget and dtc; when one of those is absent the test passes
--allow-missing-tools (reported on stderr) and separately proves verify fails closed without that flag.
"""
from __future__ import annotations

import gzip
import hashlib
import json
import os
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts" / "ddk-owned-spl-transform.py"

MIB = 1024 * 1024
SPL_START, SPL_END = 0x20000, 0xF8400
BOOT_PACKAGE = 0x1004000
P1_LBA, P1_SECTORS = 36864, 2048          # 18 MiB, 1 MiB
P2_LBA, P3_LBA, PENV_SECTORS = 38912, 39168, 256
P4_LBA, P4_SECTORS = 40960, 73728          # 20 MiB, 36 MiB (FAT32 at 512 B clusters needs >= 65525 clusters)
P5_LBA, P5_SECTORS = 114688, 4096          # 56 MiB, 2 MiB
DISK_BYTES = 60 * MIB
VERIFY_TOOLS = ("sfdisk", "fsck.vfat", "mtype", "fdtget", "dtc")
FIXTURE_TOOLS = ("mkfs.vfat", "mcopy", "mmd", "sfdisk")


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(MIB), b""):
            h.update(chunk)
    return h.hexdigest()


def egon(body_len: int, hdr_len: int, rng: random.Random, *, valid: bool = True) -> bytes:
    """eGON.BT0 blob: header length field `hdr_len`, checksum over hdr_len bytes, padded with random to body_len."""
    blob = bytearray(rng.randbytes(body_len))
    blob[0:4] = b"\x00\x00\x00\xea"
    blob[4:12] = b"eGON.BT0"
    struct.pack_into("<II", blob, 12, 0x5F0A6C39, hdr_len)
    s = sum(struct.unpack_from(f"<{hdr_len // 4}I", blob, 0)) & 0xFFFFFFFF
    struct.pack_into("<I", blob, 12, s if valid else (s ^ 1))
    return bytes(blob)


class Fdt:
    """Tiny FDT writer for the fixture (independent from the script's own FDT code)."""

    def __init__(self) -> None:
        self.struct = bytearray()
        self.strings = bytearray()
        self.offsets: dict[str, int] = {}

    def _pad(self) -> None:
        while len(self.struct) % 4:
            self.struct.append(0)

    def begin(self, name: str) -> None:
        self.struct += struct.pack(">I", 1) + name.encode() + b"\0"
        self._pad()

    def end(self) -> None:
        self.struct += struct.pack(">I", 2)

    def prop(self, name: str, value: bytes) -> None:
        if name not in self.offsets:
            self.offsets[name] = len(self.strings)
            self.strings += name.encode() + b"\0"
        self.struct += struct.pack(">III", 3, len(value), self.offsets[name]) + value
        self._pad()

    def blob(self, memreserve: list[tuple[int, int]]) -> bytes:
        rsv = b"".join(struct.pack(">QQ", a, s) for a, s in memreserve) + struct.pack(">QQ", 0, 0)
        st = bytes(self.struct) + struct.pack(">I", 9)
        off_rsv = 40
        off_struct = off_rsv + len(rsv)
        off_strings = off_struct + len(st)
        total = off_strings + len(self.strings)
        hdr = struct.pack(">10I", 0xD00DFEED, total, off_struct, off_strings, off_rsv, 17, 16, 0,
                          len(self.strings), len(st))
        return hdr + rsv + st + bytes(self.strings)


def vendor_dtb() -> bytes:
    f = Fdt()
    f.begin("")
    f.prop("#address-cells", struct.pack(">I", 2))
    f.prop("#size-cells", struct.pack(">I", 2))
    f.prop("model", b"sun50iw10\0")
    f.prop("compatible", b"allwinner,a133\0arm,sun50iw10p1\0")
    f.begin("memory@40000000")
    f.prop("device_type", b"memory\0")
    f.prop("reg", struct.pack(">IIII", 0, 0x40000000, 0, 0x20000000))
    f.end()
    f.begin("soc")
    f.prop("compatible", b"simple-bus\0")
    f.end()
    f.end()
    return f.blob([(0x48000000, 0x1000000), (0x48100000, 0x100000)])


def arm64_image(rng: random.Random, file_len: int, image_size: int) -> bytes:
    img = bytearray(rng.randbytes(file_len))
    struct.pack_into("<IIQQQQQQ", img, 0, 0x14000000, 0, 0x80000, image_size, 0xA, 0, 0, 0)
    img[56:60] = b"ARM\x64"
    struct.pack_into("<I", img, 60, 0)
    return bytes(img)


def android_boot(kernel: bytes, ramdisk: bytes) -> bytes:
    page = 2048
    hdr = bytearray(page)
    hdr[0:8] = b"ANDROID!"
    struct.pack_into("<10I", hdr, 8, len(kernel), 0x40080000, len(ramdisk), 0x42000000, 0, 0, 0x40000100, page, 0, 0)
    hdr[64:64 + 32] = b"console=ttyS0,115200 cma=64M".ljust(32, b"\0")

    def padded(b: bytes) -> bytes:
        return b + b"\0" * (-len(b) % page)

    return bytes(hdr) + padded(kernel) + padded(ramdisk)


def boot_package(dtb: bytes, rng: random.Random) -> bytes:
    items = [("u-boot", rng.randbytes(0x3000), 0x4A000000), ("monitor", rng.randbytes(0x1000), 0x48000000),
             ("dtb", dtb, 0), ("bootlogo", rng.randbytes(0x800), 0)]
    off = 0x800
    table = bytearray()
    payload = bytearray()
    for name, data, run in items:
        e = bytearray(368)
        e[0:len(name)] = name.encode()
        struct.pack_into("<6I", e, 64, off, len(data), 0, 3, run, 0)
        e[364:368] = b"IIE;"
        table += e
        chunk = data + b"\0" * (-len(data) % 0x400)
        payload += chunk
        off += len(chunk)
    hdr = bytearray(64)
    hdr[0:16] = b"sunxi-package".ljust(16, b"\0")
    struct.pack_into("<12I", hdr, 16, 0x89119800, 0, 0, 0, len(items), off, 0, 0, 0, 0, 0, 0x3B454949)
    head = bytes(hdr) + bytes(table)
    return head.ljust(0x800, b"\0") + bytes(payload)


def build_fixture(tmp: Path, *, kernel_image_size: int = 0x40000, seed: int = 1) -> dict:
    rng = random.Random(seed)
    tmp = tmp / f"fixture-{seed}-{kernel_image_size:x}"
    tmp.mkdir()
    img = tmp / "ddk.img"
    with open(img, "wb") as f:
        f.truncate(DISK_BYTES)
    layout = (
        "label: gpt\nlabel-id: 0394742D-5609-5DCA-9CC6-C86BE0BEBE96\nfirst-lba: 36864\n"
        f"start={P1_LBA}, size={P1_SECTORS}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=boot\n"
        f"start={P2_LBA}, size={PENV_SECTORS}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=env\n"
        f"start={P3_LBA}, size={PENV_SECTORS}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=env-redund\n"
        f"start={P4_LBA}, size={P4_SECTORS}, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=boot-resource, "
        "attrs=LegacyBIOSBootable\n"
        f"start={P5_LBA}, size={P5_SECTORS}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=userdata\n"
    )
    subprocess.run(["sfdisk", "--no-reread", "--no-tell-kernel", "-q", str(img)], input=layout, text=True,
                   check=True, capture_output=True)

    fat = tmp / f"p4-{seed}.vfat"
    with open(fat, "wb") as f:
        f.truncate(P4_SECTORS * 512)
    subprocess.run(["mkfs.vfat", "-F", "32", "-s", "1", "-S", "512", "-i", "52A7C97E", "-n", "POCKETFORGE",
                    str(fat)], check=True, capture_output=True)
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1", SOURCE_DATE_EPOCH="1700000000")
    files = tmp / f"files-{seed}"
    files.mkdir()
    (files / "user-data.example").write_bytes(rng.randbytes(201))
    (files / "fastbootlogo.bmp").write_bytes(rng.randbytes(70000))
    (files / "bat0.bmp").write_bytes(rng.randbytes(9000))
    subprocess.run(["mcopy", "-i", str(fat), str(files / "user-data.example"), str(files / "fastbootlogo.bmp"),
                    "::/"], check=True, capture_output=True, env=env)
    subprocess.run(["mmd", "-i", str(fat), "::/bat"], check=True, capture_output=True, env=env)
    subprocess.run(["mcopy", "-i", str(fat), str(files / "bat0.bmp"), "::/bat/"], check=True, capture_output=True,
                   env=env)

    kernel = arm64_image(rng, 40000, kernel_image_size)
    ramdisk = gzip.compress(rng.randbytes(9000), mtime=0)
    dtb = vendor_dtb()
    with open(img, "r+b") as f:
        f.seek(SPL_START)
        f.write(egon(0x10000, 0x10000, rng))
        f.seek(BOOT_PACKAGE)
        f.write(boot_package(dtb, rng))
        f.seek(P1_LBA * 512)
        f.write(android_boot(kernel, ramdisk))
        f.seek(P2_LBA * 512)
        f.write(rng.randbytes(PENV_SECTORS * 512))
        f.seek(P3_LBA * 512)
        f.write(rng.randbytes(1254))
        f.seek(P4_LBA * 512)
        f.write(fat.read_bytes())
        f.seek(P5_LBA * 512)
        f.write(rng.randbytes(P5_SECTORS * 512))
    return {"image": img, "sha": sha_file(img), "kernel": kernel, "ramdisk": ramdisk, "dtb": dtb}


def run(*args: str, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(SCRIPT), *args], capture_output=True, text=True, timeout=600,
                          env=env)


def missing_verify_tools() -> list[str]:
    return [t for t in VERIFY_TOOLS if shutil.which(t) is None]


def check_lines(out: str) -> dict[int, str]:
    """`CHECK <n> gate PASS|FAIL ...` -> {n: status}.

    The gate line is the verdict of check n, decided by the script's built-in (pure-python) checks plus any external
    cross-check that ran. Cross-check lines may say SKIP (tool missing, --allow-missing-tools); a gate line never may.
    """
    res: dict[int, str] = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] == "CHECK" and parts[1].isdigit() and parts[2] == "gate":
            n = int(parts[1])
            if n in res:
                raise AssertionError(f"two gate lines for check {n}")
            res[n] = parts[3]
    return res


def path_without(tools: tuple[str, ...], work: Path) -> str:
    """A PATH dir holding symlinks to every cross-check/fixture tool except `tools` (reproduces a runner without them)."""
    d = work / ("bin-without-" + "-".join(tools))
    d.mkdir(exist_ok=True)
    for t in (*VERIFY_TOOLS, *FIXTURE_TOOLS):
        src = shutil.which(t)
        if t not in tools and src and not (d / t).exists():
            (d / t).symlink_to(src)
    return str(d)


class Synthetic(unittest.TestCase):
    tmp: tempfile.TemporaryDirectory
    work: Path

    @classmethod
    def setUpClass(cls) -> None:
        missing = [t for t in FIXTURE_TOOLS if shutil.which(t) is None]
        if missing:
            raise AssertionError(f"missing fixture tools (container/IaC must provide them): {missing}")
        cls.tmp = tempfile.TemporaryDirectory(prefix="ddk-owned-spl-")
        cls.work = Path(cls.tmp.name)
        cls.extra = ["--allow-missing-tools"] if missing_verify_tools() else []
        if cls.extra:
            print(f"NOTE verify cross-check tools missing on this host: {missing_verify_tools()}", file=sys.stderr)
        cls.fx = build_fixture(cls.work)
        rng = random.Random(7)
        cls.spl = cls.work / "spl-fit.bin"
        cls.spl.write_bytes(egon(SPL_END - SPL_START, 0xA000, rng))
        cls.spl_sha = sha_file(cls.spl)
        cls.out = cls.work / "out.img"
        r = cls.build(cls.fx, cls.spl, cls.spl_sha, cls.out)
        if r.returncode != 0:
            raise AssertionError(f"build failed rc={r.returncode}\n{r.stdout}\n{r.stderr}")

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tmp.cleanup()

    @classmethod
    def build(cls, fx: dict, spl: Path, spl_sha: str, out: Path) -> subprocess.CompletedProcess:
        return run("build", "--ddk-image", str(fx["image"]), "--ddk-sha256", fx["sha"], "--spl-fit", str(spl),
                   "--spl-fit-sha256", spl_sha, "--out", str(out))

    def verify(self, image: Path, *, fx: dict | None = None, spl: Path | None = None, pin: bool = True,
               env: dict | None = None, extra: list[str] | None = None) -> subprocess.CompletedProcess:
        fx = fx or self.fx
        spl = spl or self.spl
        args = ["verify", "--ddk-image", str(fx["image"]), "--spl-fit", str(spl), "--image", str(image)]
        if pin:
            args += ["--ddk-sha256", fx["sha"], "--spl-fit-sha256", sha_file(spl)]
        return run(*args, *(self.extra if extra is None else extra), env=env)

    def mutated(self, name: str, offset: int, *, xor: int = 0x01, src: Path | None = None) -> Path:
        dst = self.work / name
        shutil.copyfile(src or self.out, dst)
        with open(dst, "r+b") as f:
            f.seek(offset)
            b = f.read(1)
            f.seek(offset)
            f.write(bytes([b[0] ^ xor]))
        return dst

    def assert_fails(self, r: subprocess.CompletedProcess, check: int) -> None:
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(check_lines(r.stdout).get(check), "FAIL", f"check {check} not FAIL:\n{r.stdout}\n{r.stderr}")
        self.assertIn("VERIFY result=FAIL", r.stdout)

    def p4_find(self, needle: bytes) -> int:
        data = self.out.read_bytes()
        pos = data.find(needle, P4_LBA * 512, (P4_LBA + P4_SECTORS) * 512)
        self.assertGreater(pos, 0, "needle not found in p4")
        return pos

    # -- positive ---------------------------------------------------------------------------------------------
    def test_verify_passes_all_seven_and_prints_descriptor(self):
        r = self.verify(self.out)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(check_lines(r.stdout), {n: "PASS" for n in range(1, 8)}, r.stdout)
        self.assertIn("VERIFY result=PASS", r.stdout)
        self.assertIn(f"OUTPUT_RAW_SHA256 {sha_file(self.out)}", r.stdout)
        desc = [ln for ln in r.stdout.splitlines() if ln.startswith("DESCRIPTOR_JSON ")]
        self.assertEqual(len(desc), 1, r.stdout)
        d = json.loads(desc[0].split(" ", 1)[1])
        self.assertEqual(d["ImageRawSHA256"], sha_file(self.out))
        self.assertEqual(d["SourceDDKImageSHA256"], self.fx["sha"])
        self.assertEqual(d["OwnedSPLFITSHA256"], self.spl_sha)
        self.assertNotIn("VendorBoot0ImageSHA256", d)
        self.assertNotIn("ExemptSignatures", d)

    def test_two_builds_are_byte_identical(self):
        out2 = self.work / "out2.img"
        r = self.build(self.fx, self.spl, self.spl_sha, out2)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(sha_file(out2), sha_file(self.out))
        out2.unlink()

    def test_only_declared_ranges_change_and_files_read_back(self):
        a = self.fx["image"].read_bytes()
        b = self.out.read_bytes()
        self.assertEqual(len(a), len(b))
        p4 = (P4_LBA * 512, (P4_LBA + P4_SECTORS) * 512)
        self.assertEqual(a[:SPL_START], b[:SPL_START])
        self.assertEqual(a[SPL_END:p4[0]], b[SPL_END:p4[0]])
        self.assertEqual(a[p4[1]:], b[p4[1]:])
        self.assertEqual(b[SPL_START:SPL_END], self.spl.read_bytes())
        env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
        spec = f"{self.out}@@{p4[0]}"
        for name, want in (("Image", self.fx["kernel"]), ("initrd.gz", self.fx["ramdisk"])):
            got = subprocess.run(["mtype", "-i", spec, f"::/{name}"], capture_output=True, env=env, check=True).stdout
            self.assertEqual(got, want, name)
        dtb = subprocess.run(["mtype", "-i", spec, "::/dtb.bin"], capture_output=True, env=env, check=True).stdout
        self.assertEqual(dtb[:4], b"\xd0\x0d\xfe\xed")
        # pre-existing files untouched
        old = subprocess.run(["mtype", "-i", f"{self.fx['image']}@@{p4[0]}", "::/bat/bat0.bmp"], capture_output=True,
                             env=env, check=True).stdout
        new = subprocess.run(["mtype", "-i", spec, "::/bat/bat0.bmp"], capture_output=True, env=env,
                             check=True).stdout
        self.assertEqual(old, new)

    # -- build refusals ---------------------------------------------------------------------------------------
    def test_build_refuses_wrong_spl_sha_and_writes_nothing(self):
        out = self.work / "refused.img"
        r = self.build(self.fx, self.spl, "0" * 64, out)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(out.exists())

    def test_build_refuses_spl_with_bad_egon_checksum(self):
        bad = self.work / "spl-bad.bin"
        bad.write_bytes(egon(SPL_END - SPL_START, 0xA000, random.Random(7), valid=False))
        out = self.work / "refused2.img"
        r = self.build(self.fx, bad, sha_file(bad), out)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(out.exists())
        self.assert_fails(self.verify(self.out, spl=bad), 2)

    def test_build_refuses_spl_of_wrong_length(self):
        short = self.work / "spl-short.bin"
        short.write_bytes(self.spl.read_bytes()[:-512])
        out = self.work / "refused3.img"
        r = self.build(self.fx, short, sha_file(short), out)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(out.exists())

    # -- negative controls, one per Row 5 check ---------------------------------------------------------------
    def test_check1_byte_outside_allowed_ranges(self):
        for name, off in (("c1-p5.img", P5_LBA * 512 + 4097), ("c1-bootpkg.img", BOOT_PACKAGE + 0x900),
                          ("c1-8k.img", 0x2000), ("c1-p1.img", P1_LBA * 512 + 3000)):
            with self.subTest(name=name):
                img = self.mutated(name, off)
                self.assert_fails(self.verify(img), 1)
                img.unlink()

    def test_check2_byte_inside_owned_region(self):
        img = self.mutated("c2.img", SPL_START + 0x5000)
        self.assert_fails(self.verify(img), 2)
        img.unlink()

    def test_check3_fat_copies_disagree(self):
        data = self.out.read_bytes()
        base = P4_LBA * 512
        rsv, nf = struct.unpack_from("<HB", data, base + 14)
        fatsz = struct.unpack_from("<I", data, base + 36)[0]
        self.assertEqual(nf, 2)
        fat2_cluster3 = base + (rsv + fatsz) * 512 + 3 * 4
        img = self.mutated("c3.img", fat2_cluster3, xor=0x40)
        r = self.verify(img)
        self.assert_fails(r, 3)
        self.assertEqual(check_lines(r.stdout).get(1), "PASS", r.stdout)
        img.unlink()

    def test_check3_gpt_entry_changed(self):
        img = self.mutated("c3-gpt.img", 2 * 512 + 56 + 2)  # first entry's name, CRC now wrong
        self.assert_fails(self.verify(img), 3)
        img.unlink()

    def test_check4_byte_inside_image_data(self):
        pos = self.p4_find(self.fx["kernel"][20000:20064])
        img = self.mutated("c4.img", pos + 10)
        r = self.verify(img)
        self.assert_fails(r, 4)
        self.assertEqual(check_lines(r.stdout).get(3), "PASS", r.stdout)
        img.unlink()

    def test_check5_bl31_reservation_changed(self):
        pos = self.p4_find(struct.pack(">IIII", 0, 0x40000000, 0, 0x40000))
        img = self.mutated("c5.img", pos + 13, xor=0x01)  # size 0x40000 -> 0x50000... (byte 13 of the 16)
        self.assert_fails(self.verify(img), 5)
        img.unlink()

    def test_check6_kernel_reaches_vendor_memreserve(self):
        fx = build_fixture(self.work, kernel_image_size=0x3F80000 + 0x1000, seed=1)
        out = self.work / "c6.img"
        r = self.build(fx, self.spl, self.spl_sha, out)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r = self.verify(out, fx=fx)
        self.assert_fails(r, 6)
        for n in (1, 2, 3, 4, 5, 7):
            self.assertEqual(check_lines(r.stdout).get(n), "PASS", f"{n}\n{r.stdout}")
        out.unlink()
        shutil.rmtree(fx["image"].parent)

    def test_check7_byte_in_free_p4_cluster(self):
        last_sector = (P4_LBA + P4_SECTORS) * 512 - 512 * 3 + 7
        img = self.mutated("c7.img", last_sector)
        r = self.verify(img)
        self.assert_fails(r, 7)
        for n in (1, 2, 3, 4, 5, 6):
            self.assertEqual(check_lines(r.stdout).get(n), "PASS", f"{n}\n{r.stdout}")
        img.unlink()

    # -- fail-closed posture ----------------------------------------------------------------------------------
    def test_verify_refuses_unpinned_ddk(self):
        r = self.verify(self.out, pin=False)  # default pins are the real 31271d56 / 24ef47d4
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("VERIFY result=FAIL", r.stdout)

    def test_gates_pass_without_fdtget_and_dtc(self):
        """The CI runner has no fdtget/dtc: check 5/6 must still be decided (PASS) by the built-in FDT parser."""
        env = dict(os.environ, PATH=path_without(("fdtget", "dtc"), self.work))
        r = self.verify(self.out, env=env, extra=["--allow-missing-tools"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(check_lines(r.stdout), {n: "PASS" for n in range(1, 8)}, r.stdout)
        self.assertIn("tool_missing=fdtget", r.stdout)
        self.assertIn("tool_missing=dtc", r.stdout)
        for name in ("bl31_reg_nomap", "linux_cma", "fdt_parse"):
            self.assertRegex(r.stdout, rf"CHECK 5 {name} PASS", name)

    def test_without_fdt_tools_and_without_allow_flag_fails_closed(self):
        env = dict(os.environ, PATH=path_without(("fdtget", "dtc"), self.work))
        r = self.verify(self.out, env=env, extra=[])
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertEqual(check_lines(r.stdout).get(5), "FAIL", r.stdout)

    def test_check5_malformed_fdt_without_fdt_tools(self):
        """Built-in parser negative control: a dtb.bin with a broken struct block fails gate 5 even with no dtc."""
        d = self.out.read_bytes()
        p4 = (P4_LBA * 512, (P4_LBA + P4_SECTORS) * 512)
        pos = d.find(b"\xd0\x0d\xfe\xed", p4[0], p4[1])
        self.assertGreater(pos, 0)
        off_struct = struct.unpack_from(">I", d, pos + 8)[0]
        img = self.mutated("c5-malformed.img", pos + off_struct + 3, xor=0x0E)  # FDT_BEGIN_NODE(1) -> token 0xF
        env = dict(os.environ, PATH=path_without(("fdtget", "dtc"), self.work))
        r = self.verify(img, env=env, extra=["--allow-missing-tools"])
        self.assert_fails(r, 5)
        self.assertIn("CHECK 5 fdt_parse FAIL", r.stdout)
        img.unlink()

    def test_verify_fails_closed_when_crosscheck_tools_missing(self):
        empty = self.work / "emptybin"
        empty.mkdir(exist_ok=True)
        r = self.verify(self.out, env={"PATH": str(empty)}, extra=[])
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("VERIFY result=FAIL", r.stdout)
        self.assertIn("tool_missing", r.stdout)


if __name__ == "__main__":
    unittest.main()
