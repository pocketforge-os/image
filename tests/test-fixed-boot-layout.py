#!/usr/bin/env python3
"""The self-flash v3 marker binds the baked p5 (userdata) start sector.

genimage must therefore fix the boot partition size (not derive it from the
boot.img size, which crossed a 1 MiB boundary and moved p5 from 251904 to
253952, so pocketforge-self-flash-v3-grow refused root_partition_start_mismatch),
and the marker constant must equal the p5 start implied by that fixed layout.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MIB = 1 << 20
SECTOR = 512
BOOT_OFFSET = 36 * MIB
ENV_SLOTS = 2 * MIB           # env.img + env-redund, each padded to align = 1M
BOOT_RESOURCE = 64 * MIB      # make-reproducible-vfat.sh ... 64 POCKETFORGE


def size_bytes(text: str) -> int:
    m = re.fullmatch(r"(\d+)([MK])", text)
    assert m, text
    return int(m.group(1)) * (MIB if m.group(2) == "M" else 1024)


def main() -> int:
    genimage = (ROOT / "boards/tsp/genimage.cfg").read_text()
    block = re.search(r"partition boot \{(.*?)\n    \}", genimage, re.S)
    assert block, "partition boot block missing"
    size = re.search(r"^\s*size\s*=\s*(\d+[MK])\s*$", block.group(1), re.M)
    errors = []
    if size is None:
        errors.append("genimage partition boot has no explicit size: layout is derived from boot.img")
        boot_size = None
    else:
        boot_size = size_bytes(size.group(1))
    marker = re.search(r"^BakedRootPartitionStartSector=(\d+)$",
                       (ROOT / "scripts/build-rootfs.sh").read_text(), re.M)
    assert marker, "marker constant missing"
    if boot_size is not None:
        p5 = (BOOT_OFFSET + boot_size + ENV_SLOTS + BOOT_RESOURCE) // SECTOR
        if int(marker.group(1)) != p5:
            errors.append(f"marker BakedRootPartitionStartSector={marker.group(1)} != genimage-implied p5 start {p5}")
    sd = (ROOT / "scripts/build-sd-image.sh").read_text()
    if not re.search(r"boot\.img.*exceeds|BOOT_PARTITION_BYTES", sd):
        errors.append("build-sd-image.sh does not refuse a boot.img larger than the fixed boot partition")
    for e in errors:
        print("FAIL", e, file=sys.stderr)
    if not errors:
        print("PASS fixed boot layout matches self-flash v3 marker")
    return 1 if errors else 0


sys.exit(main())
