#!/usr/bin/env python3
"""Closed-DDK image -> owned SPL + owned U-Boot boot chain (bead tsp-e9830c0f6d28eaaa3977; gap sheet GFX7 Rows 4-5).

  build  --ddk-image F --ddk-sha256 H --spl-fit F --spl-fit-sha256 H --out F
  verify --ddk-image F --spl-fit F --image F [--ddk-sha256 H] [--spl-fit-sha256 H] [--allow-missing-tools]

The output is the input DDK image (default pin 31271d56...) with exactly these changes:
  1. [0x20000, 0xF8400): overwritten by the owned SPL+FIT (default pin 24ef47d4..., the interim extract of owned
     image ea99624d...). The vendor BOOT0 there is destroyed; the rest of that range was zero.
  2. FAT32 p4 (boot-resource) gains, in this order, `Image` (p1 boot.img kernel), `initrd.gz` (p1 boot.img ramdisk)
     and `dtb.bin` (the boot_package `dtb` item plus /reserved-memory { bl31@40000000 no-map; linux,cma 64 MiB
     linux,cma-default }). The filesystem is edited in place, not reformatted: the bytes that change are both FAT
     copies, the FSInfo sector, the root directory (and a zeroed root-directory cluster if the chain must grow) and
     the newly allocated data clusters (first-fit from cluster 2; the last cluster of each file zero-padded). The
     boot sector, its backup, the serial 52A7C97E, the label and every pre-existing file keep their bytes. New
     directory entries carry the fixed DOS timestamp 1980-01-01 00:00:00 so the output does not depend on the clock.
  3. Nothing else: GPT (both copies), p1, p2, p3, p5 and the boot_package at 16 MiB + 16 KiB are byte-identical.

The DTB edit is a minimal libfdt-style insertion (new node appended at the end of the root node, new property names
appended to the strings block, header sizes updated); there is no dtc round-trip and no dependency on the host's
fdtput/libfdt version, so the bytes are the same on every host. `verify` cross-checks it with fdtget and dtc.

`verify` is gap sheet Row 5 checks 1-7 and fails closed (exit 1) on any FAIL line:
  1 range compare against the DDK image outside [0x20000,0xF8400) and p4
  2 owned-region sha + eGON.BT0 checksum
  3 GPT (CRCs, same table as the DDK; sfdisk -d diff) and FAT p4 (python consistency walk; fsck.vfat -n)
  4 read-back sha of Image / initrd.gz / dtb.bin and of every pre-existing p4 file (python; mtype)
  5 dtb.bin content (python FDT parse; fdtget; dtc -I dtb decompiles)
  6 address map of the owned U-Boot booti flow
  7 two independent rebuilds from the inputs give the same bytes, equal to --image
A missing cross-check tool is a FAIL (tool_missing=...) unless --allow-missing-tools turns it into a SKIP line.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from dataclasses import dataclass, field
from pathlib import Path

PINNED_DDK_SHA256 = "31271d568c20269e30628a3ea98199fd40d52fb627e1e59864b8ebe7fe2049e6"
PINNED_SPL_FIT_SHA256 = "24ef47d4501d265d5a8048c2079169bc069cc474433555c1ab5bbc97cdff230b"
PINNED_SPL_FIT_PROVENANCE = {
    "kind": "interim-extract",
    "source_image_raw_sha256": "ea99624dc438f601dfa9357ceca75048e546269a3557b435f13b4f404f461a38",
    "source_image": "gpu16/gfx6-owned-image-42771084831/Image.img (POWER8 r22g base)",
    "range": "[0x20000,0xF8400)",
    "spl": "U-Boot SPL 2025.10-g1c04d7f5c98b",
    "bl31": "TF-A v2.15.0(debug):g2737a2a84d80",
}
# Byte facts of the pinned DDK input (gap sheet Row 1); asserted on top of the derived values when it is the input.
PINNED_DDK_PARTS = {
    "kernel_sha256": "3204742ba3ba52a96956421872d9f9711b9f8e1d3a18e410cf8d873964a4bcb4",
    "ramdisk_sha256": "9aef21ba73162e850b87399f35d047043ebb69b20a35024a83a15dffcbc0c737",
    "vendor_dtb_sha256": "aa79c650586589274b9f8c0e6b46d73507e466520d3436feb1c5ccd826986db5",
}

SPL_START, SPL_END = 0x20000, 0xF8400
BOOT_PACKAGE_OFFSET = 0x1004000
EGON_STAMP = 0x5F0A6C39
SECTOR = 512
MIB = 1024 * 1024
FS_SERIAL = 0x52A7C97E
DOS_DATE, DOS_TIME = 0x0021, 0x0000  # 1980-01-01 00:00:00
NEW_FILES = ("Image", "initrd.gz", "dtb.bin")

# Owned U-Boot 2025.10-g1c04d7f5 default env (gap sheet Row 2) and the address facts the check 6 model uses.
DRAM_BASE, DRAM_END = 0x40000000, 0x80000000
BL31_BASE, BL31_SIZE = 0x40000000, 0x40000
KERNEL_LOAD, DTB_LOAD, INITRD_LOAD = 0x44000000, 0x49000000, 0x4B000000
BOOTM_SIZE = 0xA000000
FDT_PAD = 0x3000
VENDOR_RSV_BASE, VENDOR_RSV_END = 0x48000000, 0x49000000
CMA_SIZE, CMA_ALIGN = 0x4000000, 0x400000
CROSSCHECK_TOOLS = ("sfdisk", "fsck.vfat", "mtype", "fdtget", "dtc")


class TransformError(Exception):
    pass


def need(cond: bool, msg: str) -> None:
    if not cond:
        raise TransformError(msg)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 * MIB), b""):
            h.update(chunk)
    return h.hexdigest()


class Disk:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.fd = os.open(path, os.O_RDONLY)
        self.size = os.fstat(self.fd).st_size

    def read(self, off: int, n: int) -> bytes:
        need(0 <= off and off + n <= self.size, f"read [{off:#x},+{n:#x}) beyond the {self.size:#x}-byte image")
        out = bytearray()
        while len(out) < n:
            chunk = os.pread(self.fd, n - len(out), off + len(out))
            need(len(chunk) > 0, "short read")
            out += chunk
        return bytes(out)

    def close(self) -> None:
        os.close(self.fd)


# ---------------------------------------------------------------------------------------------------------- GPT
@dataclass(frozen=True)
class Part:
    index: int
    type_guid: bytes
    uuid: bytes
    first: int
    last: int
    attrs: int
    name: str

    @property
    def start(self) -> int:
        return self.first * SECTOR

    @property
    def end(self) -> int:
        return (self.last + 1) * SECTOR


def gpt_header(disk: Disk, lba: int) -> dict:
    raw = disk.read(lba * SECTOR, SECTOR)
    need(raw[:8] == b"EFI PART", f"no GPT header at LBA {lba}")
    hsize = struct.unpack_from("<I", raw, 12)[0]
    need(92 <= hsize <= SECTOR, "bad GPT header size")
    crc = struct.unpack_from("<I", raw, 16)[0]
    zeroed = raw[:16] + b"\0\0\0\0" + raw[20:hsize]
    need(zlib.crc32(zeroed) & 0xFFFFFFFF == crc, f"GPT header CRC mismatch at LBA {lba}")
    cur, bak, first_use, last_use = struct.unpack_from("<QQQQ", raw, 24)
    ent_lba, n_ent, ent_size, ent_crc = struct.unpack_from("<QIII", raw, 72)
    need(cur == lba, "GPT header current-LBA mismatch")
    need(ent_size == 128 and 0 < n_ent <= 1024, "unsupported GPT entry array")
    entries = disk.read(ent_lba * SECTOR, n_ent * ent_size)
    need(zlib.crc32(entries) & 0xFFFFFFFF == ent_crc, f"GPT entry array CRC mismatch (header LBA {lba})")
    parts = []
    for i in range(n_ent):
        e = entries[i * 128:(i + 1) * 128]
        if e[:16] == b"\0" * 16:
            continue
        first, last, attrs = struct.unpack_from("<QQQ", e, 32)
        name = e[56:128].decode("utf-16-le").split("\0")[0]
        parts.append(Part(i + 1, e[:16], e[16:32], first, last, attrs, name))
    return {"backup_lba": bak, "first_usable": first_use, "last_usable": last_use, "entries_lba": ent_lba,
            "entries_bytes": n_ent * ent_size, "disk_guid": raw[56:72], "parts": tuple(parts)}


def read_gpt(disk: Disk) -> dict:
    primary = gpt_header(disk, 1)
    need(primary["backup_lba"] == disk.size // SECTOR - 1, "GPT backup header is not at the last LBA")
    backup = gpt_header(disk, primary["backup_lba"])
    need(backup["parts"] == primary["parts"] and backup["disk_guid"] == primary["disk_guid"],
         "primary and backup GPT disagree")
    return primary


def part_by_name(gpt: dict, name: str) -> Part:
    hits = [p for p in gpt["parts"] if p.name == name]
    need(len(hits) == 1, f"expected exactly one GPT partition named {name!r}, found {len(hits)}")
    return hits[0]


# ---------------------------------------------------------------------------------------------------------- eGON
def egon_check(blob: bytes) -> tuple[bool, str]:
    if len(blob) < 32 or blob[4:12] != b"eGON.BT0":
        return False, "no eGON.BT0 magic"
    stored, length = struct.unpack_from("<II", blob, 12)
    if length % 4 or not 32 <= length <= len(blob):
        return False, f"eGON length {length:#x} out of range"
    words = list(struct.unpack_from(f"<{length // 4}I", blob, 0))
    words[3] = EGON_STAMP
    calc = sum(words) & 0xFFFFFFFF
    if calc != stored:
        return False, f"eGON checksum stored={stored:#010x} computed={calc:#010x}"
    return True, f"eGON length={length:#x} checksum={stored:#010x}"


# ---------------------------------------------------------------------------------------------------------- FDT
FDT_BEGIN, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


@dataclass
class Node:
    name: str
    props: dict[str, bytes] = field(default_factory=dict)
    children: dict[str, "Node"] = field(default_factory=dict)


def fdt_header(blob: bytes) -> dict:
    need(len(blob) >= 40 and struct.unpack_from(">I", blob, 0)[0] == 0xD00DFEED, "not an FDT blob")
    keys = ("magic", "totalsize", "off_struct", "off_strings", "off_rsv", "version", "last_comp", "boot_cpu",
            "size_strings", "size_struct")
    h = dict(zip(keys, struct.unpack_from(">10I", blob, 0)))
    need(h["totalsize"] == len(blob), "FDT totalsize does not match the blob length")
    need(h["version"] >= 17 and h["last_comp"] <= 16, "unsupported FDT version")
    need(h["off_struct"] + h["size_struct"] <= len(blob) and h["off_strings"] + h["size_strings"] <= len(blob),
         "FDT blocks out of range")
    return h


def fdt_memreserve(blob: bytes) -> list[tuple[int, int]]:
    h = fdt_header(blob)
    out, off = [], h["off_rsv"]
    while True:
        a, s = struct.unpack_from(">QQ", blob, off)
        if a == 0 and s == 0:
            return out
        out.append((a, s))
        off += 16


def fdt_parse(blob: bytes) -> tuple[Node, int]:
    """Returns (root, struct-relative offset of the root node's FDT_END_NODE token)."""
    h = fdt_header(blob)
    st = blob[h["off_struct"]:h["off_struct"] + h["size_struct"]]
    strings = blob[h["off_strings"]:h["off_strings"] + h["size_strings"]]
    pos, stack, root, root_end = 0, [], None, -1

    def align(p: int) -> int:
        return (p + 3) & ~3

    while True:
        need(pos + 4 <= len(st), "FDT struct block truncated")
        tok = struct.unpack_from(">I", st, pos)[0]
        if tok == FDT_BEGIN:
            end = st.index(b"\0", pos + 4)
            node = Node(st[pos + 4:end].decode())
            if stack:
                need(node.name not in stack[-1].children, f"duplicate FDT node {node.name}")
                stack[-1].children[node.name] = node
            else:
                need(root is None, "FDT has two root nodes")
                root = node
            stack.append(node)
            pos = align(end + 1)
        elif tok == FDT_END_NODE:
            need(bool(stack), "FDT END_NODE without node")
            stack.pop()
            if not stack:
                root_end = pos
            pos += 4
        elif tok == FDT_PROP:
            need(bool(stack), "FDT property outside a node")
            ln, nameoff = struct.unpack_from(">II", st, pos + 4)
            need(nameoff < len(strings), "FDT property name offset out of range")
            name = strings[nameoff:strings.index(b"\0", nameoff)].decode()
            stack[-1].props[name] = st[pos + 12:pos + 12 + ln]
            pos = align(pos + 12 + ln)
        elif tok == FDT_NOP:
            pos += 4
        elif tok == FDT_END:
            need(not stack and root is not None, "FDT ended inside a node")
            return root, root_end
        else:
            raise TransformError(f"bad FDT token {tok:#x}")


def fdt_lookup(root: Node, path: str) -> Node | None:
    node = root
    for comp in [c for c in path.split("/") if c]:
        node = node.children.get(comp)
        if node is None:
            return None
    return node


def u32s(*vals: int) -> bytes:
    return struct.pack(f">{len(vals)}I", *vals)


RESERVED_MEMORY = ("reserved-memory", [
    ("#address-cells", u32s(2)), ("#size-cells", u32s(2)), ("ranges", b""),
], [
    ("bl31@40000000", [("reg", u32s(0, BL31_BASE, 0, BL31_SIZE)), ("no-map", b"")]),
    ("linux,cma", [("compatible", b"shared-dma-pool\0"), ("reusable", b""), ("size", u32s(0, CMA_SIZE)),
                   ("alignment", u32s(0, CMA_ALIGN)), ("linux,cma-default", b"")]),
])


def patch_dtb(blob: bytes) -> bytes:
    """Append /reserved-memory (G1 bl31 no-map + G2 64 MiB default CMA) to the vendor DTB, libfdt-style."""
    h = fdt_header(blob)
    need(h["off_rsv"] >= 40 and h["off_rsv"] <= h["off_struct"], "FDT memreserve block is not before the struct")
    need(h["off_strings"] == h["off_struct"] + h["size_struct"] and h["totalsize"] == h["off_strings"] +
         h["size_strings"], "FDT layout is not header|memreserve|struct|strings without padding")
    root, root_end = fdt_parse(blob)
    need(root.props.get("#address-cells") == u32s(2) and root.props.get("#size-cells") == u32s(2),
         "root #address-cells/#size-cells must be 2/2 for the reserved-memory reg encoding")
    need("reserved-memory" not in root.children, "vendor DTB already has /reserved-memory; refusing to merge")
    strings = bytearray(blob[h["off_strings"]:h["off_strings"] + h["size_strings"]])
    known: dict[str, int] = {}
    off = 0
    while off < len(strings):
        end = strings.index(b"\0", off)
        known.setdefault(strings[off:end].decode(), off)
        off = end + 1

    def nameoff(name: str) -> int:
        if name not in known:
            known[name] = len(strings)
            strings.extend(name.encode() + b"\0")
        return known[name]

    def pad(b: bytes) -> bytes:
        return b + b"\0" * (-len(b) % 4)

    def node(name: str, props: list[tuple[str, bytes]], children: list) -> bytes:
        out = struct.pack(">I", FDT_BEGIN) + pad(name.encode() + b"\0")
        for pname, val in props:
            out += struct.pack(">III", FDT_PROP, len(val), nameoff(pname)) + pad(val)
        for cname, cprops in children:
            out += node(cname, cprops, [])
        return out + struct.pack(">I", FDT_END_NODE)

    name, props, children = RESERVED_MEMORY
    insert = node(name, props, children)
    old_struct = blob[h["off_struct"]:h["off_struct"] + h["size_struct"]]
    new_struct = old_struct[:root_end] + insert + old_struct[root_end:]
    off_strings = h["off_struct"] + len(new_struct)
    total = off_strings + len(strings)
    hdr = bytearray(blob[:40])
    struct.pack_into(">II", hdr, 4, total, h["off_struct"])
    struct.pack_into(">I", hdr, 12, off_strings)
    struct.pack_into(">II", hdr, 32, len(strings), len(new_struct))
    out = bytes(hdr) + blob[40:h["off_struct"]] + new_struct + bytes(strings)
    fdt_parse(out)
    return out


def check_dtb_content(blob: bytes, vendor: bytes) -> list[tuple[str, bool, str]]:
    res = []
    root, _ = fdt_parse(blob)
    rm = fdt_lookup(root, "/reserved-memory")
    res.append(("reserved_memory_node", rm is not None and rm.props.get("#address-cells") == u32s(2) and
                rm.props.get("#size-cells") == u32s(2) and rm.props.get("ranges") == b"",
                "/reserved-memory #address-cells=2 #size-cells=2 ranges"))
    bl31 = fdt_lookup(root, "/reserved-memory/bl31@40000000")
    res.append(("bl31_reg_nomap", bl31 is not None and bl31.props.get("reg") == u32s(0, BL31_BASE, 0, BL31_SIZE)
                and bl31.props.get("no-map") == b"", f"bl31@40000000 reg=<0 {BL31_BASE:#x} 0 {BL31_SIZE:#x}> no-map"))
    cma = fdt_lookup(root, "/reserved-memory/linux,cma")
    ok = cma is not None and cma.props.get("compatible") == b"shared-dma-pool\0" and \
        cma.props.get("reusable") == b"" and cma.props.get("size") == u32s(0, CMA_SIZE) and \
        cma.props.get("alignment") == u32s(0, CMA_ALIGN) and cma.props.get("linux,cma-default") == b""
    res.append(("linux_cma", ok, f"linux,cma shared-dma-pool reusable size={CMA_SIZE:#x} align={CMA_ALIGN:#x} "
                                 "linux,cma-default"))
    vroot, _ = fdt_parse(vendor)
    same = {k: v for k, v in root.children.items() if k != "reserved-memory"} == vroot.children and \
        root.props == vroot.props and fdt_memreserve(blob) == fdt_memreserve(vendor)
    res.append(("vendor_tree_preserved", same, f"memreserve={[(hex(a), hex(s)) for a, s in fdt_memreserve(blob)]}"))
    return res


# ---------------------------------------------------------------------------------------------------------- FAT32
@dataclass
class Entry:
    name: str
    attr: int
    cluster: int
    size: int
    slot_first: int  # index of the first 32-byte slot (LFN or short) in the directory stream
    slot_short: int


class Fat32:
    def __init__(self, disk: Disk, part: Part) -> None:
        self.disk, self.base, self.part = disk, part.start, part
        bs = disk.read(self.base, SECTOR)
        self.bs = bs
        need(bs[510:512] == b"\x55\xaa", "p4 boot sector signature missing")
        bps, self.spc, self.rsv, self.nfats = struct.unpack_from("<HBHB", bs, 11)
        need(bps == SECTOR, "p4 bytes/sector must be 512")
        need(self.spc in (1, 2, 4, 8, 16, 32, 64, 128), "bad sectors/cluster")
        need(struct.unpack_from("<H", bs, 22)[0] == 0 and bs[82:90] == b"FAT32   ", "p4 is not FAT32")
        self.total = struct.unpack_from("<I", bs, 32)[0]
        self.fatsz, = struct.unpack_from("<I", bs, 36)
        self.root, self.fsinfo, self.bkboot = struct.unpack_from("<IHH", bs, 44)
        self.serial = struct.unpack_from("<I", bs, 67)[0]
        self.label = bs[71:82].decode("ascii", "replace").rstrip()
        need(self.nfats == 2, "p4 must carry two FAT copies")
        need(self.total * SECTOR <= part.end - part.start, "FAT32 is larger than p4")
        self.csize = self.spc * SECTOR
        self.data = self.rsv + self.nfats * self.fatsz
        self.count = (self.total - self.data) // self.spc
        need(self.count >= 65525, "cluster count too small for FAT32")
        need((self.count + 2) * 4 <= self.fatsz * SECTOR, "FAT too small for the cluster count")
        self.fat_raw = [disk.read(self.base + (self.rsv + i * self.fatsz) * SECTOR, self.fatsz * SECTOR)
                        for i in range(self.nfats)]
        self.fat = list(struct.unpack_from(f"<{self.count + 2}I", self.fat_raw[0], 0))

    def nxt(self, c: int) -> int:
        return self.fat[c] & 0x0FFFFFFF

    def coff(self, c: int) -> int:
        return self.base + (self.data + (c - 2) * self.spc) * SECTOR

    def chain(self, first: int) -> list[int]:
        out, seen, c = [], set(), first
        while True:
            need(2 <= c < self.count + 2, f"cluster {c} out of range in chain from {first}")
            need(c not in seen, f"cluster chain loop at {c}")
            v = self.nxt(c)
            need(v != 0, f"chain from {first} runs into free cluster {c}")
            need(v != 0x0FFFFFF7, f"chain from {first} hits bad cluster {c}")
            seen.add(c)
            out.append(c)
            if v >= 0x0FFFFFF8:
                return out
            c = v

    def read_chain(self, first: int) -> bytes:
        return b"".join(self.disk.read(self.coff(c), self.csize) for c in self.chain(first))

    def read_file(self, e: Entry) -> bytes:
        if e.size == 0:
            need(e.cluster == 0, f"{e.name}: empty file with a cluster")
            return b""
        clusters = self.chain(e.cluster)
        need(len(clusters) == -(-e.size // self.csize), f"{e.name}: chain length does not match size {e.size}")
        return b"".join(self.disk.read(self.coff(c), self.csize) for c in clusters)[:e.size]

    @staticmethod
    def lfn_sum(short: bytes) -> int:
        s = 0
        for b in short:
            s = (((s & 1) << 7) + (s >> 1) + b) & 0xFF
        return s

    def entries(self, data: bytes) -> list[Entry]:
        out, lfn, lfn_first, lfn_sum = [], {}, -1, -1
        for i in range(len(data) // 32):
            e = data[i * 32:(i + 1) * 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn = {}
                continue
            attr = e[11]
            if attr == 0x0F:
                seq = e[0] & 0x1F
                if e[0] & 0x40:
                    lfn, lfn_first, lfn_sum = {}, i, e[13]
                need(e[13] == lfn_sum, f"LFN checksum inconsistency at slot {i}")
                lfn[seq] = (e[1:11] + e[14:26] + e[28:32])
                continue
            if attr & 0x08:
                lfn = {}
                continue
            short = e[0:11]
            base, ext = short[:8].decode("ascii", "replace").rstrip(), short[8:].decode("ascii", "replace").rstrip()
            if e[12] & 0x08:
                base = base.lower()
            if e[12] & 0x10:
                ext = ext.lower()
            name = base + ("." + ext if ext else "")
            first = i
            if lfn:
                need(lfn_sum == self.lfn_sum(short), f"LFN checksum mismatch for {name}")
                need(sorted(lfn) == list(range(1, len(lfn) + 1)), f"LFN sequence gap for {name}")
                raw = b"".join(lfn[k] for k in sorted(lfn))
                chars = raw.decode("utf-16-le")
                name = chars.split("\0")[0]
                first = lfn_first
            cl = struct.unpack_from("<H", e, 20)[0] << 16 | struct.unpack_from("<H", e, 26)[0]
            out.append(Entry(name, attr, cl, struct.unpack_from("<I", e, 28)[0], first, i))
            lfn = {}
        return out

    def walk(self) -> dict[str, Entry]:
        """Every file and directory below root: {'/path': Entry}; directories end with '/'."""
        out: dict[str, Entry] = {}
        todo = [("/", self.root)]
        while todo:
            path, cl = todo.pop(0)
            for e in self.entries(self.read_chain(cl)):
                if e.name in (".", ".."):
                    continue
                if e.attr & 0x10:
                    out[path + e.name + "/"] = e
                    todo.append((path + e.name + "/", e.cluster))
                else:
                    out[path + e.name] = e
        return out

    def fsinfo_counts(self) -> tuple[int, int]:
        raw = self.disk.read(self.base + self.fsinfo * SECTOR, SECTOR)
        need(raw[0:4] == b"RRaA" and raw[484:488] == b"rrAa" and raw[508:512] == b"\0\0\x55\xaa",
             "FSInfo signatures missing")
        return struct.unpack_from("<II", raw, 488)

    def consistency(self) -> list[tuple[str, bool, str]]:
        """A dosfsck -n style walk: FAT copies, chains, cross-links, lost clusters, FSInfo, backup boot sector."""
        res = []
        res.append(("copies_equal", self.fat_raw[0] == self.fat_raw[1], f"{self.nfats} copies x {self.fatsz} "
                                                                             "sectors"))
        res.append(("boot_backup_equal", self.disk.read(self.base + self.bkboot * SECTOR, SECTOR) == self.bs,
                    f"backup boot sector {self.bkboot}"))
        owner: dict[int, str] = {}
        problems = []
        try:
            tree = self.walk()
            for c in self.chain(self.root):
                owner[c] = "/"
            for path, e in tree.items():
                if e.attr & 0x10:
                    chain = self.chain(e.cluster)
                else:
                    if e.size == 0:
                        continue
                    chain = self.chain(e.cluster)
                    if len(chain) != -(-e.size // self.csize):
                        problems.append(f"{path} size/chain mismatch")
                for c in chain:
                    if c in owner:
                        problems.append(f"cross-link cluster {c} {owner[c]} {path}")
                    owner[c] = path
        except TransformError as exc:
            problems.append(str(exc))
            tree = {}
        used = {c for c in range(2, self.count + 2) if self.nxt(c) != 0 and self.nxt(c) != 0x0FFFFFF7}
        lost = used - set(owner)
        if lost:
            problems.append(f"{len(lost)} lost clusters (first {min(lost)})")
        res.append(("chains", not problems, "; ".join(problems[:3]) or f"{len(tree)} entries, {len(owner)} "
                                                                       "clusters referenced, 0 lost, 0 cross-linked"))
        free_actual = sum(1 for c in range(2, self.count + 2) if self.fat[c] & 0x0FFFFFFF == 0)
        free_info, _ = self.fsinfo_counts()
        res.append(("fsinfo_free", free_info in (free_actual, 0xFFFFFFFF), f"fsinfo={free_info} actual={free_actual}"))
        res.append(("serial_label", self.serial == FS_SERIAL and self.label == "POCKETFORGE",
                    f"serial={self.serial:08X} label={self.label}"))
        return res


def short_name(name: str) -> tuple[bytes, int, bool]:
    """(11-byte short name, NTRes case flags, needs_lfn) for a plain 8.3-capable ASCII name."""
    base, _, ext = name.partition(".")
    ok = "".join(ch for ch in base + ext if ch.isalnum() or ch in "_-")
    need(ok == base + ext and 0 < len(base) <= 8 and len(ext) <= 3 and name.count(".") <= 1,
         f"{name}: not an 8.3-capable name")
    flags, lfn = 0, False
    for part, bit in ((base, 0x08), (ext, 0x10)):
        if part == part.lower() and part != part.upper():
            flags |= bit
        elif part != part.upper():
            lfn = True
    if lfn:
        flags = 0
    return (base.upper().ljust(8) + ext.upper().ljust(3)).encode("ascii"), flags, lfn


def dir_slots(name: str, cluster: int, size: int) -> bytes:
    short, flags, lfn = short_name(name)
    out = b""
    if lfn:
        chars = name.encode("utf-16-le") + b"\0\0"
        chars += b"\xff" * (-len(chars) % 26)
        n = len(chars) // 26
        s = Fat32.lfn_sum(short)
        for seq in range(n, 0, -1):
            c = chars[(seq - 1) * 26:seq * 26]
            e = bytes([seq | (0x40 if seq == n else 0)]) + c[0:10] + bytes([0x0F, 0, s]) + c[10:22] + b"\0\0" + c[22:26]
            out += e
    e = bytearray(32)
    e[0:11] = short
    e[11] = 0x20
    e[12] = flags
    struct.pack_into("<BHHHHHHHI", e, 13, 0, DOS_TIME, DOS_DATE, DOS_DATE, cluster >> 16, DOS_TIME, DOS_DATE,
                     cluster & 0xFFFF, size)
    return out + bytes(e)


def fat_add_files(fs: Fat32, files: list[tuple[str, bytes]]) -> list[tuple[int, bytes]]:
    """In-place FAT32 edit: returns the (absolute offset, bytes) writes that add `files` to the root directory.

    Order is fixed: root-directory growth clusters (if any), then each file's data clusters, first-fit from 2."""
    tree = fs.walk()
    taken = {p.lower() for p in tree}
    root_entries = fs.entries(fs.read_chain(fs.root))
    shorts = set()
    root_raw = fs.read_chain(fs.root)
    for e in root_entries:
        shorts.add(root_raw[e.slot_short * 32:e.slot_short * 32 + 11])
    for name, _ in files:
        need("/" + name.lower() not in taken and "/" + name.lower() + "/" not in taken, f"p4 already has {name}")
        need(short_name(name)[0] not in shorts, f"p4 short-name collision for {name}")
    fat = list(fs.fat)
    free = (c for c in range(2, fs.count + 2) if fat[c] & 0x0FFFFFFF == 0)
    allocated: list[int] = []

    def alloc(n: int) -> list[int]:
        got = []
        for _ in range(n):
            c = next(free, None)
            need(c is not None, "p4 is full")
            got.append(c)
        allocated.extend(got)
        return got

    def link(chain: list[int]) -> None:
        for a, b in zip(chain, chain[1:] + [None]):
            fat[a] = (fat[a] & 0xF0000000) | (0x0FFFFFFF if b is None else b)

    writes: list[tuple[int, bytes]] = []
    # 1) directory slots (grow the root chain with zeroed clusters if needed)
    root_chain = fs.chain(fs.root)
    end_slot = len(root_raw) // 32
    for i in range(len(root_raw) // 32):
        if root_raw[i * 32] == 0:
            end_slot = i
            break
    slot_bytes_len = sum(len(dir_slots(n, 2, len(d))) for n, d in files)
    need_bytes = end_slot * 32 + slot_bytes_len
    have = len(root_chain) * fs.csize
    root_new = bytearray(root_raw)
    if need_bytes > have:
        extra = alloc(-(-(need_bytes - have) // fs.csize))
        link(root_chain + extra)
        root_chain = root_chain + extra
        root_new += b"\0" * (len(extra) * fs.csize)
    # 2) data clusters, in file order
    slots = b""
    data_writes = []
    for name, data in files:
        need(len(data) > 0, f"{name} is empty")
        chain = alloc(-(-len(data) // fs.csize))
        link(chain)
        padded = data + b"\0" * (-len(data) % fs.csize)
        for k, c in enumerate(chain):
            data_writes.append((fs.coff(c), padded[k * fs.csize:(k + 1) * fs.csize]))
        slots += dir_slots(name, chain[0], len(data))
    root_new[end_slot * 32:end_slot * 32 + len(slots)] = slots
    for k, c in enumerate(root_chain):
        chunk = bytes(root_new[k * fs.csize:(k + 1) * fs.csize])
        if k >= len(root_raw) // fs.csize or chunk != root_raw[k * fs.csize:(k + 1) * fs.csize]:
            writes.append((fs.coff(c), chunk))
    writes += data_writes
    # 3) both FAT copies (changed sectors only) and FSInfo
    new_fat = bytearray(fs.fat_raw[0])
    struct.pack_into(f"<{fs.count + 2}I", new_fat, 0, *fat)
    for copy in range(fs.nfats):
        fat_base = fs.base + (fs.rsv + copy * fs.fatsz) * SECTOR
        for s in range(fs.fatsz):
            new = bytes(new_fat[s * SECTOR:(s + 1) * SECTOR])
            if new != fs.fat_raw[copy][s * SECTOR:(s + 1) * SECTOR]:
                writes.append((fat_base + s * SECTOR, new))
    free_info, _ = fs.fsinfo_counts()
    free_actual = sum(1 for c in range(2, fs.count + 2) if fs.fat[c] & 0x0FFFFFFF == 0)
    need(free_info in (free_actual, 0xFFFFFFFF), f"input FSInfo free count {free_info} != actual {free_actual}")
    fsinfo = bytearray(fs.disk.read(fs.base + fs.fsinfo * SECTOR, SECTOR))
    struct.pack_into("<II", fsinfo, 488, free_actual - len(allocated), allocated[-1])
    writes.append((fs.base + fs.fsinfo * SECTOR, bytes(fsinfo)))
    return writes


# ---------------------------------------------------------------------------------------------------------- inputs
def android_boot_parts(disk: Disk, p1: Part) -> tuple[bytes, bytes]:
    hdr = disk.read(p1.start, 2048)
    need(hdr[:8] == b"ANDROID!", "p1 is not an Android boot image")
    ksz, _, rsz, _, ssz, _, _, page, hver = struct.unpack_from("<9I", hdr, 8)
    need(hver == 0 and ssz == 0, "only Android boot image v0 without a second stage is supported")
    need(page in (2048, 4096) and ksz > 64 and rsz > 0, "bad Android boot image sizes")
    koff = p1.start + page
    roff = koff + -(-ksz // page) * page
    need(roff + rsz <= p1.end, "Android boot image runs past p1")
    kernel, ramdisk = disk.read(koff, ksz), disk.read(roff, rsz)
    need(kernel[56:60] == b"ARM\x64", "boot.img kernel is not an arm64 Image")
    need(ramdisk[:2] == b"\x1f\x8b", "boot.img ramdisk is not gzip")
    return kernel, ramdisk


def boot_package_dtb(disk: Disk) -> bytes:
    hdr = disk.read(BOOT_PACKAGE_OFFSET, 64)
    need(hdr[:16].rstrip(b"\0") == b"sunxi-package", "no sunxi-package at 16 MiB + 16 KiB")
    n, valid = struct.unpack_from("<II", hdr, 32)
    need(0 < n <= 32, "bad boot_package item count")
    table = disk.read(BOOT_PACKAGE_OFFSET + 64, n * 368)
    hits = []
    for i in range(n):
        e = table[i * 368:(i + 1) * 368]
        if e[:64].split(b"\0")[0] == b"dtb":
            off, ln = struct.unpack_from("<II", e, 64)
            need(off + ln <= valid, "boot_package dtb item runs past valid_len")
            hits.append(disk.read(BOOT_PACKAGE_OFFSET + off, ln))
    need(len(hits) == 1, "expected exactly one boot_package `dtb` item")
    fdt_header(hits[0])
    return hits[0]


@dataclass
class Plan:
    writes: list[tuple[int, bytes]]
    files: dict[str, bytes]
    vendor_dtb: bytes
    p4: Part


def make_plan(ddk_path: Path, spl: bytes) -> Plan:
    need(len(spl) == SPL_END - SPL_START, f"SPL+FIT must be exactly {SPL_END - SPL_START:#x} bytes, got {len(spl):#x}")
    ok, detail = egon_check(spl)
    need(ok, f"owned SPL+FIT: {detail}")
    disk = Disk(ddk_path)
    try:
        gpt = read_gpt(disk)
        for p in gpt["parts"]:
            need(p.end <= SPL_START or p.start >= SPL_END, f"partition {p.name} overlaps the SPL region")
        ent = (gpt["entries_lba"] * SECTOR, gpt["entries_lba"] * SECTOR + gpt["entries_bytes"])
        need(ent[1] <= SPL_START or ent[0] >= SPL_END, "GPT entries overlap the SPL region")
        need(gpt["first_usable"] * SECTOR >= BOOT_PACKAGE_OFFSET, "first usable LBA below the boot_package")
        old = disk.read(SPL_START, SPL_END - SPL_START)
        vend_ok, vend = egon_check(old)
        need(vend_ok, f"DDK region at 0x20000 is not a valid vendor BOOT0: {vend}")
        boot0_len = struct.unpack_from("<I", old, 16)[0]
        need(old[boot0_len:] == b"\0" * (len(old) - boot0_len), "DDK bytes after the vendor BOOT0 are not zero")
        p1, p4 = part_by_name(gpt, "boot"), part_by_name(gpt, "boot-resource")
        need(p4.start >= SPL_END and p4.start > BOOT_PACKAGE_OFFSET, "p4 overlaps a fixed region")
        kernel, ramdisk = android_boot_parts(disk, p1)
        vendor_dtb = boot_package_dtb(disk)
        dtb = patch_dtb(vendor_dtb)
        files = {"Image": kernel, "initrd.gz": ramdisk, "dtb.bin": dtb}
        fs = Fat32(disk, p4)
        need(fs.serial == FS_SERIAL, f"p4 FS serial {fs.serial:08X} != {FS_SERIAL:08X}")
        writes = [(SPL_START, spl)] + fat_add_files(fs, [(n, files[n]) for n in NEW_FILES])
        for off, data in writes[1:]:
            need(p4.start <= off and off + len(data) <= p4.end, "FAT write escaped p4")
        writes.sort()
        for (a, da), (b, _) in zip(writes, writes[1:]):
            need(a + len(da) <= b, "overlapping writes")
        return Plan(writes, files, vendor_dtb, p4)
    finally:
        disk.close()


def virtual_sha(ddk_path: Path, writes: list[tuple[int, bytes]]) -> str:
    h = hashlib.sha256()
    size = os.path.getsize(ddk_path)
    with open(ddk_path, "rb") as f:
        pos = 0
        for off, data in writes + [(size, b"")]:
            f.seek(pos)
            left = off - pos
            while left:
                chunk = f.read(min(8 * MIB, left))
                need(bool(chunk), "short read")
                h.update(chunk)
                left -= len(chunk)
            h.update(data)
            pos = off + len(data)
    return h.hexdigest()


# ---------------------------------------------------------------------------------------------------------- build
def cmd_build(a: argparse.Namespace) -> int:
    out = Path(a.out)
    tmp = out.with_name(out.name + ".partial")
    try:
        need(out.resolve() != Path(a.ddk_image).resolve(), "--out must not be the DDK image")
        ddk_sha = sha256_file(Path(a.ddk_image))
        need(ddk_sha == a.ddk_sha256, f"DDK image sha256 {ddk_sha} != pinned {a.ddk_sha256}")
        spl = Path(a.spl_fit).read_bytes()
        need(sha256(spl) == a.spl_fit_sha256, f"SPL+FIT sha256 {sha256(spl)} != pinned {a.spl_fit_sha256}")
        plan = make_plan(Path(a.ddk_image), spl)
        shutil.copyfile(a.ddk_image, tmp)
        with open(tmp, "r+b") as f:
            for off, data in plan.writes:
                f.seek(off)
                f.write(data)
            f.flush()
            os.fsync(f.fileno())
        out_sha = sha256_file(tmp)
        need(out_sha == virtual_sha(Path(a.ddk_image), plan.writes), "written image differs from the plan")
        os.replace(tmp, out)
    except (TransformError, OSError) as exc:
        tmp.unlink(missing_ok=True)
        print(f"BUILD result=FAIL reason={exc}", file=sys.stderr)
        return 1
    spans = {"spl_fit": 0, "p4": 0}
    for off, data in plan.writes:
        spans["spl_fit" if off == SPL_START else "p4"] += len(data)
    print(f"BUILD writes={len(plan.writes)} spl_fit_bytes={spans['spl_fit']} p4_bytes_written={spans['p4']}")
    for name in NEW_FILES:
        print(f"BUILD p4_file {name} bytes={len(plan.files[name])} sha256={sha256(plan.files[name])}")
    print(f"OUTPUT_RAW_SHA256 {out_sha}")
    print("BUILD result=PASS")
    return 0


# ---------------------------------------------------------------------------------------------------------- verify
class Report:
    """Per-check lines plus one `CHECK <n> gate PASS|FAIL` verdict per check.

    A gate PASSes only if at least one built-in (pure-python) line for that check passed and no line for it failed.
    External cross-checks (sfdisk, fsck.vfat, mtype, fdtget, dtc) add lines when the tool exists; a missing tool is a
    FAIL line, or with --allow-missing-tools a SKIP line that is neutral for the gate. A gate line is never SKIP.
    """

    def __init__(self, allow_missing: bool) -> None:
        self.allow_missing = allow_missing
        self.builtin_pass: dict[int, int] = {n: 0 for n in range(1, 8)}
        self.fails: dict[int, int] = {n: 0 for n in range(1, 8)}

    def line(self, n: int, name: str, ok: bool, detail: str, *, builtin: bool = True) -> None:
        if not ok:
            self.fails[n] += 1
        elif builtin:
            self.builtin_pass[n] += 1
        print(f"CHECK {n} {name} {'PASS' if ok else 'FAIL'} {detail}".rstrip(), flush=True)

    def xline(self, n: int, name: str, ok: bool, detail: str) -> None:
        self.line(n, name, ok, detail, builtin=False)

    def tool(self, n: int, name: str, tool: str) -> str | None:
        path = shutil.which(tool)
        if path is None:
            if self.allow_missing:
                print(f"CHECK {n} {name} SKIP tool_missing={tool} (--allow-missing-tools; cross-check only)",
                      flush=True)
            else:
                self.xline(n, name, False, f"tool_missing={tool}")
        return path

    def gates(self) -> bool:
        ok_all = True
        for n in range(1, 8):
            ok = self.fails[n] == 0 and self.builtin_pass[n] > 0
            ok_all &= ok
            print(f"CHECK {n} gate {'PASS' if ok else 'FAIL'} builtin_pass={self.builtin_pass[n]} "
                  f"fail={self.fails[n]}", flush=True)
        return ok_all

    @property
    def failed(self) -> bool:
        return any(self.fails.values())


def run_tool(argv: list[str], env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, timeout=300, env=env)


def address_map(kernel: bytes, initrd_len: int, dtb_len: int) -> list[tuple[str, bool, str]]:
    text_offset, image_size, flags = struct.unpack_from("<QQQ", kernel, 8)
    base = KERNEL_LOAD if flags & 0x8 else DRAM_BASE
    kstart = ((base + 0x1FFFFF) & ~0x1FFFFF) + text_offset
    kend = kstart + image_size
    top = DRAM_BASE + BOOTM_SIZE
    rd = (top - initrd_len) & ~0xFFF
    fdt = (rd - (dtb_len + FDT_PAD)) & ~0xFFF
    bl31_end = BL31_BASE + BL31_SIZE
    # Calibration against the r22g owned console: 1386444 B initrd, 31328 B dtb -> 49ead000 / 49ea2000.
    cal_rd = (top - 1386444) & ~0xFFF
    cal = cal_rd == 0x49EAD000 and ((cal_rd - (31328 + FDT_PAD)) & ~0xFFF) == 0x49EA2000
    return [
        ("model_calibration", cal, "r22g console Ramdisk 49ead000 / Device Tree 49ea2000 reproduced"),
        ("kernel_placement", bool(flags & 0x8) and kend < DTB_LOAD and kend <= VENDOR_RSV_BASE,
         f"booti {kstart:#x}+{image_size:#x}={kend:#x} < dtb load {DTB_LOAD:#x}, <= memreserve {VENDOR_RSV_BASE:#x}"),
        ("image_load_buffer", KERNEL_LOAD + len(kernel) <= DTB_LOAD,
         f"Image file {KERNEL_LOAD:#x}+{len(kernel):#x} <= {DTB_LOAD:#x}"),
        ("initrd_load_buffer", INITRD_LOAD + initrd_len <= DRAM_END, f"{INITRD_LOAD:#x}+{initrd_len:#x}"),
        ("fdt_initrd_relocation", fdt >= VENDOR_RSV_END + dtb_len and rd + initrd_len <= top and fdt >= kend,
         f"fdt {fdt:#x} ramdisk {rd:#x}..{rd + initrd_len:#x} within [{VENDOR_RSV_END + dtb_len:#x},{top:#x})"),
        ("bl31_untouched", kstart >= bl31_end and fdt >= bl31_end and KERNEL_LOAD >= bl31_end,
         f"nothing in [{BL31_BASE:#x},{bl31_end:#x})"),
    ]


def cmd_verify(a: argparse.Namespace) -> int:
    rep = Report(a.allow_missing_tools)
    image, ddk, splp = Path(a.image), Path(a.ddk_image), Path(a.spl_fit)
    try:
        ddk_sha, spl_sha = sha256_file(ddk), sha256_file(splp)
        img_sha = sha256_file(image)
    except OSError as exc:
        print(f"INPUT read FAIL {exc}\nVERIFY result=FAIL")
        return 1
    print(f"INPUT ddk_image sha256={ddk_sha} {'PASS' if ddk_sha == a.ddk_sha256 else 'FAIL pinned=' + a.ddk_sha256}")
    print(f"INPUT spl_fit sha256={spl_sha} {'PASS' if spl_sha == a.spl_fit_sha256 else 'FAIL pinned=' + a.spl_fit_sha256}")
    print(f"OUTPUT_RAW_SHA256 {img_sha}")
    if ddk_sha != a.ddk_sha256 or spl_sha != a.spl_fit_sha256:
        print("VERIFY result=FAIL reason=input_not_pinned")
        return 1
    spl = splp.read_bytes()
    try:
        plan = make_plan(ddk, spl)
    except TransformError as exc:
        plan = None
        print(f"PLAN FAIL {exc}")
    try:
        return _verify(rep, a, image, ddk, spl, plan, img_sha, ddk_sha, spl_sha)
    except TransformError as exc:
        print(f"VERIFY result=FAIL reason={exc}")
        return 1


def _verify(rep: Report, a, image: Path, ddk: Path, spl: bytes, plan: Plan | None, img_sha: str, ddk_sha: str,
            spl_sha: str) -> int:
    din, dout = Disk(ddk), Disk(image)
    pinned = ddk_sha == PINNED_DDK_SHA256
    try:
        # 1 range compare --------------------------------------------------------------------------------------
        try:
            p4 = part_by_name(read_gpt(din), "boot-resource")
            same_size = din.size == dout.size
            diffs = []
            if same_size:
                for lo, hi in ((0, SPL_START), (SPL_END, p4.start), (p4.end, din.size)):
                    pos = lo
                    while pos < hi:
                        n = min(8 * MIB, hi - pos)
                        if din.read(pos, n) != dout.read(pos, n):
                            x, y = din.read(pos, n), dout.read(pos, n)
                            k = next(i for i in range(n) if x[i] != y[i])
                            diffs.append(pos + k)
                            break
                        pos += n
            rep.line(1, "range_compare", same_size and not diffs,
                     f"size={dout.size} outside [{SPL_START:#x},{SPL_END:#x}) and p4 [{p4.start:#x},{p4.end:#x})"
                     + (f" first_diff={diffs[0]:#x}" if diffs else "") + ("" if same_size else " SIZE_DIFFERS"))
        except TransformError as exc:
            p4 = None
            rep.line(1, "range_compare", False, str(exc))
        # 2 owned region --------------------------------------------------------------------------------------
        region = dout.read(SPL_START, SPL_END - SPL_START) if dout.size >= SPL_END else b""
        rep.line(2, "region_sha256", sha256(region) == spl_sha, f"[{SPL_START:#x},{SPL_END:#x}) sha256={sha256(region)}")
        ok, detail = egon_check(region)
        rep.line(2, "egon_checksum", ok, detail)
        ok, detail = egon_check(spl)
        rep.line(2, "spl_fit_input_egon", ok, detail)
        # 3 GPT + FAT ------------------------------------------------------------------------------------------
        try:
            gin, gout = read_gpt(din), read_gpt(dout)
            same = gin == gout
            names = [p.name for p in gout["parts"]]
            rep.line(3, "gpt_python", same, f"crc ok, primary==backup, {len(names)} parts {names} == DDK table")
        except TransformError as exc:
            rep.line(3, "gpt_python", False, str(exc))
        if rep.tool(3, "sfdisk_dump", "sfdisk"):
            def dump(p: Path) -> list[str]:
                r = run_tool(["sfdisk", "-d", str(p)])
                txt = r.stdout.decode(errors="replace") if r.returncode == 0 else ""
                return [ln.replace(str(p), "IMG") for ln in txt.splitlines() if not ln.startswith("device:")]
            dd, di = dump(ddk), dump(image)
            rep.xline(3, "sfdisk_dump", bool(dd) and dd == di, f"{len(di)} lines identical to the DDK table")
        fs = None
        if p4 is not None:
            try:
                fs = Fat32(dout, p4)
                for name, ok, detail in fs.consistency():
                    rep.line(3, f"fat_{name}", ok, detail)
            except TransformError as exc:
                rep.line(3, "fat_python", False, str(exc))
        tmpdir = Path(tempfile.mkdtemp(prefix="ddk-owned-spl-verify-"))
        try:
            if p4 is not None and rep.tool(3, "fsck_vfat", "fsck.vfat"):
                part = tmpdir / "p4.vfat"
                part.write_bytes(dout.read(p4.start, p4.end - p4.start))
                r = run_tool(["fsck.vfat", "-n", str(part)])
                tail = (r.stdout + r.stderr).decode(errors="replace").strip().splitlines()
                rep.xline(3, "fsck_vfat", r.returncode == 0, f"rc={r.returncode} {tail[-1] if tail else ''}")
                part.unlink()
            # 4 read-back ---------------------------------------------------------------------------------------
            got: dict[str, bytes] = {}
            if fs is not None and plan is not None:
                try:
                    tree = fs.walk()
                    for name in NEW_FILES:
                        e = tree.get("/" + name)
                        got[name] = fs.read_file(e) if e else b""
                        want = plan.files[name]
                        rep.line(4, f"readback_{name}", got[name] == want,
                                 f"sha256={sha256(got[name])} want={sha256(want)} bytes={len(got[name])}")
                    old = Fat32(din, p4)
                    old_tree = old.walk()
                    bad = [p for p, e in old_tree.items() if not p.endswith("/") and
                           (p not in tree or fs.read_file(tree[p]) != old.read_file(e))]
                    extra = sorted(set(tree) - set(old_tree) - {"/" + n for n in NEW_FILES})
                    rep.line(4, "preexisting_files", not bad and not extra,
                             f"{len(old_tree)} DDK entries unchanged" + (f" changed={bad[:3]}" if bad else "") +
                             (f" unexpected={extra[:3]}" if extra else ""))
                except TransformError as exc:
                    rep.line(4, "readback_python", False, str(exc))
            else:
                rep.line(4, "readback_python", False, "no FAT p4 or no plan")
            if pinned and plan is not None:
                for key, blob in (("kernel_sha256", plan.files["Image"]), ("ramdisk_sha256", plan.files["initrd.gz"]),
                                  ("vendor_dtb_sha256", plan.vendor_dtb)):
                    rep.line(4, f"pinned_{key}", sha256(blob) == PINNED_DDK_PARTS[key],
                             f"{sha256(blob)} == pinned DDK fact")
            if p4 is not None and plan is not None and rep.tool(4, "mtype_readback", "mtype"):
                env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
                for name in NEW_FILES:
                    r = run_tool(["mtype", "-i", f"{image}@@{p4.start}", f"::/{name}"], env=env)
                    rep.xline(4, f"mtype_{name}", r.returncode == 0 and r.stdout == plan.files[name],
                             f"rc={r.returncode} sha256={sha256(r.stdout)}")
            # 5 dtb ---------------------------------------------------------------------------------------------
            dtb = got.get("dtb.bin", b"")
            if dtb and plan is not None:
                try:
                    fdt_parse(dtb)
                    rep.line(5, "fdt_parse", True, f"built-in parser: {len(dtb)} B, header/struct/strings valid")
                    for name, ok, detail in check_dtb_content(dtb, plan.vendor_dtb):
                        rep.line(5, name, ok, detail)
                except TransformError as exc:
                    rep.line(5, "fdt_parse", False, str(exc))
                dtbf = tmpdir / "dtb.bin"
                dtbf.write_bytes(dtb)
                if rep.tool(5, "fdtget", "fdtget"):
                    q = [(["-t", "x", str(dtbf), "/reserved-memory/bl31@40000000", "reg"], "0 40000000 0 40000"),
                         (["-t", "x", str(dtbf), "/reserved-memory/linux,cma", "size"], "0 4000000"),
                         (["-t", "x", str(dtbf), "/reserved-memory/linux,cma", "alignment"], "0 400000"),
                         (["-t", "s", str(dtbf), "/reserved-memory/linux,cma", "compatible"], "shared-dma-pool")]
                    for args, want in q:
                        r = run_tool(["fdtget", *args])
                        val = r.stdout.decode(errors="replace").strip()
                        rep.xline(5, "fdtget", r.returncode == 0 and val == want, f"{args[3]} {args[4]} = {val!r}")
                    r = run_tool(["fdtget", "-p", str(dtbf), "/reserved-memory/bl31@40000000"])
                    rep.xline(5, "fdtget", "no-map" in r.stdout.decode(errors="replace").split(), "bl31 has no-map")
                    r = run_tool(["fdtget", "-p", str(dtbf), "/reserved-memory/linux,cma"])
                    props = r.stdout.decode(errors="replace").split()
                    rep.xline(5, "fdtget", "linux,cma-default" in props and "reusable" in props,
                             "linux,cma has reusable + linux,cma-default")
                if rep.tool(5, "dtc_decompile", "dtc"):
                    r = run_tool(["dtc", "-q", "-I", "dtb", "-O", "dts", "-o", os.devnull, str(dtbf)])
                    rep.xline(5, "dtc_decompile", r.returncode == 0, f"rc={r.returncode}")
            else:
                rep.line(5, "fdt_parse", False, "no dtb.bin read back")
            # 6 address map ------------------------------------------------------------------------------------
            if got.get("Image") and got.get("initrd.gz") and dtb:
                for name, ok, detail in address_map(got["Image"], len(got["initrd.gz"]), len(dtb)):
                    rep.line(6, name, ok, detail)
            else:
                rep.line(6, "address_map", False, "Image/initrd.gz/dtb.bin not all read back")
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)
        # 7 reproducible rebuild ---------------------------------------------------------------------------------
        try:
            p1 = make_plan(ddk, spl)
            p2 = make_plan(ddk, spl)
            s1, s2 = virtual_sha(ddk, p1.writes), virtual_sha(ddk, p2.writes)
            rep.line(7, "rebuild_twice", p1.writes == p2.writes and s1 == s2, f"rebuild1={s1} rebuild2={s2}")
            rep.line(7, "rebuild_equals_image", s1 == img_sha, f"image={img_sha}")
        except TransformError as exc:
            rep.line(7, "rebuild_twice", False, str(exc))
    finally:
        din.close()
        dout.close()
    gates_ok = rep.gates() and plan is not None
    if gates_ok:
        desc = {
            "Schema": "pocketforge.ddk-owned-spl-image/v1",
            "ImageRawSHA256": img_sha,
            "ImageSizeBytes": os.path.getsize(image),
            "SourceDDKImageSHA256": ddk_sha,
            "OwnedSPLFITSHA256": spl_sha,
            "OwnedSPLFITRange": f"[{SPL_START:#x},{SPL_END:#x})",
            "OwnedSPLFITProvenance": PINNED_SPL_FIT_PROVENANCE if spl_sha == PINNED_SPL_FIT_SHA256 else
            {"kind": "caller-supplied"},
            "BootSource": "owned_SPL",
            "BootP4Files": {n: {"bytes": len(plan.files[n]), "sha256": sha256(plan.files[n])} for n in NEW_FILES},
            "VendorDTBSHA256": sha256(plan.vendor_dtb),
            "DTBPatch": ["/reserved-memory/bl31@40000000 reg=<0 0x40000000 0 0x40000> no-map",
                         "/reserved-memory/linux,cma shared-dma-pool reusable size=<0 0x4000000> "
                         "alignment=<0 0x400000> linux,cma-default"],
            "TransformScriptSHA256": sha256_file(Path(__file__)),
        }
        text = json.dumps(desc, sort_keys=True, separators=(",", ":"))
        print(f"DESCRIPTOR_JSON {text}")
        if a.descriptor_out:
            Path(a.descriptor_out).write_text(json.dumps(desc, sort_keys=True, indent=2) + "\n")
    print(f"VERIFY result={'PASS' if gates_ok else 'FAIL'}")
    return 0 if gates_ok else 1


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    b = sub.add_parser("build", help="write the transformed image")
    b.add_argument("--ddk-image", required=True)
    b.add_argument("--ddk-sha256", required=True)
    b.add_argument("--spl-fit", required=True)
    b.add_argument("--spl-fit-sha256", required=True)
    b.add_argument("--out", required=True)
    v = sub.add_parser("verify", help="gap sheet Row 5 checks 1-7; nonzero on any failure")
    v.add_argument("--ddk-image", required=True)
    v.add_argument("--spl-fit", required=True)
    v.add_argument("--image", required=True)
    v.add_argument("--ddk-sha256", default=PINNED_DDK_SHA256)
    v.add_argument("--spl-fit-sha256", default=PINNED_SPL_FIT_SHA256)
    v.add_argument("--allow-missing-tools", action="store_true",
                   help="report a missing cross-check tool as SKIP instead of FAIL")
    v.add_argument("--descriptor-out", help="also write the descriptor JSON here (only on PASS)")
    a = ap.parse_args(argv)
    return cmd_build(a) if a.mode == "build" else cmd_verify(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
