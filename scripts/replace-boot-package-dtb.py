#!/usr/bin/env python3
"""Replace the DTB carried by the A133 boot_package.fex in an SD image.

The A133 SPL reads boot_package.fex from the raw boot-package partition; the
boot-resource FAT file named dtb.bin is not consulted by this boot path.  This
tool extracts the package components, repacks them with dragonsecboot (which
recomputes the TOC1 checksum), and writes the resulting package back at the
fixed offset documented by boards/tsp/genimage.cfg.

The input image is never modified.  The output is a complete image suitable
for a boot-open whole-image load.  The package and DTB are re-extracted and
hash-checked before the tool reports success.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


BOOT_PACKAGE_OFFSET = 16_793_600  # boards/tsp/genimage.cfg, 0x01004000
TOC_HEADER_SIZE = 0x40
TOC_ITEM_SIZE = 0x170
TOC_MAGIC = b"sunxi-package"
PACKAGE_LENGTH_OFFSET = 0x24
ITEM_COUNT_OFFSET = 0x20
ITEM_NAME_SIZE = 0x40
ITEM_OFFSET_OFFSET = 0x40
ITEM_LENGTH_OFFSET = 0x44


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_package(image: Path) -> tuple[bytes, int]:
    with image.open("rb") as stream:
        stream.seek(BOOT_PACKAGE_OFFSET)
        header = stream.read(TOC_HEADER_SIZE)
        if len(header) != TOC_HEADER_SIZE or not header.startswith(TOC_MAGIC):
            raise ValueError("boot package magic missing at 0x01004000")
        package_length = struct.unpack_from("<I", header, PACKAGE_LENGTH_OFFSET)[0]
        if package_length < TOC_HEADER_SIZE or package_length > 32 * 1024 * 1024:
            raise ValueError(f"invalid boot package length: {package_length}")
        stream.seek(BOOT_PACKAGE_OFFSET)
        package = stream.read(package_length)
    if len(package) != package_length:
        raise ValueError("image ended inside boot package")
    return package, package_length


def toc_items(package: bytes) -> dict[str, tuple[int, int]]:
    count = struct.unpack_from("<I", package, ITEM_COUNT_OFFSET)[0]
    table_end = TOC_HEADER_SIZE + count * TOC_ITEM_SIZE
    if table_end > len(package) or count == 0 or count > 32:
        raise ValueError(f"invalid boot package item count: {count}")
    items: dict[str, tuple[int, int]] = {}
    for index in range(count):
        base = TOC_HEADER_SIZE + index * TOC_ITEM_SIZE
        raw_name = package[base : base + ITEM_NAME_SIZE]
        name = raw_name.split(b"\0", 1)[0].decode("ascii")
        offset = struct.unpack_from("<I", package, base + ITEM_OFFSET_OFFSET)[0]
        length = struct.unpack_from("<I", package, base + ITEM_LENGTH_OFFSET)[0]
        if offset < table_end or offset + length > len(package):
            raise ValueError(f"invalid {name} payload range")
        if name in items:
            raise ValueError(f"duplicate boot package item: {name}")
        items[name] = (offset, length)
    return items


def write_cfg(directory: Path) -> None:
    (directory / "boot_package.cfg").write_text(
        "[package]\n"
        "item=u-boot,                 u-boot.bin\n"
        "item=monitor,                monitor.bin\n"
        "item=scp,                    scp.bin\n"
        "item=dtb,                    dtb.bin\n"
        "item=bootlogo,               bootlogo.bmp.lzma\n",
        encoding="ascii",
    )


def pack_components(directory: Path, dragonsecboot: Path) -> bytes:
    result = subprocess.run(
        [str(dragonsecboot), "-pack", "boot_package.cfg"],
        cwd=directory,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(
            f"dragonsecboot failed rc={result.returncode}: "
            f"{result.stdout.strip()} {result.stderr.strip()}"
        )
    package = directory / "boot_package.fex"
    if not package.is_file():
        raise RuntimeError("dragonsecboot did not produce boot_package.fex")
    return package.read_bytes()


def copy_image(source: Path, destination: Path) -> None:
    if source.resolve() == destination.resolve():
        raise ValueError("output image must differ from input image")
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["cp", "--reflink=auto", "--sparse=always", "--", str(source), str(destination)],
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--dtb", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--dragonsecboot",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "tools/dragonsecboot/dragonsecboot",
    )
    args = parser.parse_args()

    for path in (args.image, args.dtb, args.dragonsecboot):
        if not path.is_file():
            raise SystemExit(f"missing file: {path}")
    candidate_dtb = args.dtb.read_bytes()
    if not candidate_dtb.startswith(b"\xd0\x0d\xfe\xed"):
        raise SystemExit("candidate is not a flattened device tree")

    old_package, old_length = read_package(args.image)
    old_items = toc_items(old_package)
    expected = {"u-boot", "monitor", "scp", "dtb", "bootlogo"}
    if set(old_items) != expected:
        raise SystemExit(f"unexpected boot package items: {sorted(old_items)}")

    with tempfile.TemporaryDirectory(prefix="pf-boot-package-") as temp:
        work = Path(temp)
        for name, (offset, length) in old_items.items():
            output_name = {
                "u-boot": "u-boot.bin",
                "monitor": "monitor.bin",
                "scp": "scp.bin",
                "dtb": "dtb.bin",
                "bootlogo": "bootlogo.bmp.lzma",
            }[name]
            (work / output_name).write_bytes(old_package[offset : offset + length])
        (work / "dtb.bin").write_bytes(candidate_dtb)
        write_cfg(work)
        new_package = pack_components(work, args.dragonsecboot)

    new_items = toc_items(new_package)
    new_dtb_offset, new_dtb_length = new_items["dtb"]
    extracted_dtb = new_package[new_dtb_offset : new_dtb_offset + new_dtb_length]
    if extracted_dtb != candidate_dtb:
        raise SystemExit("repacked boot package DTB does not match candidate")
    new_length = len(new_package)
    if new_length > old_length:
        raise SystemExit(f"repacked package grew beyond image slot: {new_length} > {old_length}")

    copy_image(args.image, args.output)
    with args.output.open("r+b") as stream:
        stream.seek(BOOT_PACKAGE_OFFSET)
        stream.write(new_package)
        if new_length < old_length:
            stream.write(b"\0" * (old_length - new_length))
        stream.flush()
        os.fsync(stream.fileno())

    verified_package, verified_length = read_package(args.output)
    verified_items = toc_items(verified_package)
    verified_offset, verified_dtb_length = verified_items["dtb"]
    verified_dtb = verified_package[verified_offset : verified_offset + verified_dtb_length]
    if verified_dtb != candidate_dtb:
        raise SystemExit("output image verification failed: DTB mismatch")

    print(f"input_image_sha256={sha256(args.image.read_bytes())}")
    print(f"output_image_sha256={sha256(args.output.read_bytes())}")
    print(f"old_boot_package_length={old_length}")
    print(f"new_boot_package_length={verified_length}")
    print(f"boot_package_sha256={sha256(verified_package)}")
    print(f"dtb_sha256={sha256(verified_dtb)}")
    print(f"dtb_size={len(verified_dtb)}")
    print(f"dtb_offset=0x{verified_offset:x}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
