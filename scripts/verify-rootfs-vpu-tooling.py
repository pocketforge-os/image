#!/usr/bin/env python3
"""Verify Cedrus strict-decode userspace directly from final ext4 bytes.

This gate is intentionally restricted to open-GPU development images. It uses
debugfs as a mountless reader and fails closed on unreadable filesystems,
missing paths, wrong modes, empty plugin files, or absent dpkg package records.
"""

import argparse
import os
import re
import shutil
import stat
import struct
import subprocess
import sys


COMMANDS = (
    "/usr/bin/v4l2-ctl",
    "/usr/bin/gst-launch-1.0",
    "/usr/bin/gst-inspect-1.0",
)
PLUGINS = (
    (
        "/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstcoreelements.so",
        "gst_plugin_coreelements_get_desc",
        (("filesrc", "filesrc", False), ("filesink", "filesink", False)),
    ),
    (
        "/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideoconvertscale.so",
        "gst_plugin_videoconvertscale_get_desc",
        (("videoconvert", "videoconvert", False),),
    ),
    (
        "/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideoparsersbad.so",
        "gst_plugin_videoparsersbad_get_desc",
        (("h264parse", "h264parse", False),),
    ),
    (
        "/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstv4l2codecs.so",
        "gst_plugin_v4l2codecs_get_desc",
        (("v4l2slh264dec", "v4l2sl%sh264dec", True),),
    ),
)
PACKAGES = (
    "v4l-utils",
    "gstreamer1.0-tools",
    "gstreamer1.0-plugins-base",
    "gstreamer1.0-plugins-bad",
)
DPKG_STATUS = "/var/lib/dpkg/status"
TAG = "Cedrus strict-decode ext4 gate"
ELF_DESCRIPTION = "ELF64-LE-AArch64-ET_DYN"
ELF_HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
SECTION_HEADER = struct.Struct("<IIQQQQIIQQ")
SYMBOL = struct.Struct("<IBBHQQ")
ET_DYN = 3
EM_AARCH64 = 183
SHT_PROGBITS = 1
SHT_STRTAB = 3
SHT_NOBITS = 8
SHT_DYNSYM = 11
SHF_WRITE = 0x1
SHF_ALLOC = 0x2
SHN_UNDEF = 0
STB_GLOBAL = 1
STB_WEAK = 2


class Failure(Exception):
    """A fail-closed verification result."""


def run_debugfs(image, request):
    try:
        result = subprocess.run(
            ["debugfs", "-R", request, image],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise Failure(f"debugfs unavailable: {exc.strerror}") from exc
    diagnostic = (result.stdout + result.stderr).decode("utf-8", "replace")
    if result.returncode != 0:
        raise Failure(f"debugfs rejected image while running {request!r}: {diagnostic.strip()}")
    return result.stdout, diagnostic


def verify_ext4(image):
    try:
        image_stat = os.stat(image)
    except OSError as exc:
        raise Failure(f"not a readable ext4 filesystem: {image}: {exc.strerror}") from exc
    if not stat.S_ISREG(image_stat.st_mode):
        raise Failure(f"not a readable ext4 filesystem: {image}: not a regular file")
    output, diagnostic = run_debugfs(image, "stats")
    text = output.decode("utf-8", "replace")
    features = re.search(r"^Filesystem features:\s+(.+)$", text, re.MULTILINE)
    if (
        "Filesystem magic number:  0xEF53" not in text
        or not features
        or "extent" not in features.group(1).split()
    ):
        detail = (
            diagnostic.strip().splitlines()[-1]
            if diagnostic.strip()
            else "missing ext4 magic or extents feature"
        )
        raise Failure(f"not a readable ext4 filesystem: {image}: {detail}")


def inode_stat(image, path):
    output, diagnostic = run_debugfs(image, f"stat {path}")
    text = output.decode("utf-8", "replace")
    basename = path.rsplit("/", 1)[-1]
    if "Inode:" not in text or "File not found" in diagnostic:
        raise Failure(f"missing {basename} ({path})")
    kind = re.search(r"\bType:\s+(\S+)", text)
    mode = re.search(r"\bMode:\s+0*([0-7]+)", text)
    size = re.search(r"\bSize:\s+(\d+)", text)
    if not kind or not mode or not size:
        raise Failure(f"unparseable inode metadata for {path}")
    if kind.group(1) != "regular":
        raise Failure(f"not a regular file {basename} ({path})")
    return int(mode.group(1), 8), int(size.group(1))


def inode_bytes(image, path, expected_size):
    output, diagnostic = run_debugfs(image, f"cat {path}")
    basename = path.rsplit("/", 1)[-1]
    if "File not found" in diagnostic:
        raise Failure(f"missing {basename} ({path})")
    if len(output) != expected_size:
        raise Failure(
            f"partial read {basename} ({path}): expected={expected_size} actual={len(output)}"
        )
    return output


def checked_slice(data, offset, size, label):
    if offset < 0 or size < 0 or offset > len(data) or size > len(data) - offset:
        raise Failure(f"truncated ELF {label}: offset={offset} size={size} bytes={len(data)}")
    return data[offset : offset + size]


def string_at(table, offset, label):
    if offset < 0 or offset >= len(table):
        raise Failure(f"invalid ELF string offset in {label}: {offset}")
    end = table.find(b"\0", offset)
    if end < 0:
        raise Failure(f"unterminated ELF string in {label}: offset={offset}")
    try:
        return table[offset:end].decode("ascii")
    except UnicodeDecodeError as exc:
        raise Failure(f"non-ASCII ELF string in {label}: offset={offset}") from exc


def parse_elf(data, label):
    if not data.startswith(b"\x7fELF"):
        raise Failure(f"not ELF {label}")
    if len(data) < ELF_HEADER.size:
        raise Failure(f"truncated ELF header {label}")
    header = ELF_HEADER.unpack_from(data)
    ident = header[0]
    if ident[4] != 2:
        raise Failure(f"wrong ELF class {label}: expected ELF64, got {ident[4]}")
    if ident[5] != 1:
        raise Failure(f"wrong ELF byte order {label}: expected little-endian, got {ident[5]}")
    if ident[6] != 1 or header[3] != 1:
        raise Failure(f"wrong ELF version {label}")
    if header[1] != ET_DYN:
        raise Failure(f"wrong ELF type {label}: expected ET_DYN, got {header[1]}")
    if header[2] != EM_AARCH64:
        raise Failure(
            f"wrong ELF machine {label}: expected AArch64({EM_AARCH64}), got {header[2]}"
        )
    section_offset = header[6]
    section_entry_size = header[11]
    section_count = header[12]
    section_names_index = header[13]
    if header[8] != ELF_HEADER.size:
        raise Failure(f"wrong ELF header size {label}: {header[8]}")
    if section_entry_size != SECTION_HEADER.size:
        raise Failure(f"wrong ELF section-header size {label}: {section_entry_size}")
    if section_count == 0:
        raise Failure(f"missing ELF section headers {label}")
    if section_names_index <= 0 or section_names_index >= section_count:
        raise Failure(f"invalid ELF section-name index {label}: {section_names_index}")
    table_size = section_count * section_entry_size
    checked_slice(data, section_offset, table_size, f"section table for {label}")
    sections = []
    for index in range(section_count):
        offset = section_offset + index * section_entry_size
        section = SECTION_HEADER.unpack_from(data, offset)
        if section[1] != SHT_NOBITS:
            checked_slice(data, section[4], section[5], f"section {index} in {label}")
        sections.append(section)

    section_names_header = sections[section_names_index]
    if section_names_header[1] != SHT_STRTAB:
        raise Failure(f"ELF section-name table is not STRTAB {label}")
    section_names = checked_slice(
        data,
        section_names_header[4],
        section_names_header[5],
        f"section-name table for {label}",
    )
    named_sections = []
    for index, section in enumerate(sections):
        name = string_at(section_names, section[0], f"section-name table for {label}")
        named_sections.append((index, name, section))
    return {"data": data, "label": label, "sections": named_sections}


def exported_dynamic_symbols(elf):
    exports = set()
    dynsym_sections = [
        (index, section)
        for index, name, section in elf["sections"]
        if name == ".dynsym" and section[1] == SHT_DYNSYM
    ]
    if len(dynsym_sections) != 1:
        raise Failure(
            f"expected one .dynsym in {elf['label']}, found {len(dynsym_sections)}"
        )
    _, dynsym = dynsym_sections[0]
    string_index = dynsym[6]
    sections = elf["sections"]
    if string_index <= 0 or string_index >= len(sections):
        raise Failure(f"invalid .dynsym string-table link in {elf['label']}: {string_index}")
    _, string_name, string_header = sections[string_index]
    if string_name != ".dynstr" or string_header[1] != SHT_STRTAB:
        raise Failure(f".dynsym does not link to .dynstr in {elf['label']}")
    strings = checked_slice(
        elf["data"],
        string_header[4],
        string_header[5],
        f".dynstr in {elf['label']}",
    )
    if dynsym[9] != SYMBOL.size or dynsym[5] % SYMBOL.size:
        raise Failure(f"invalid .dynsym entry size in {elf['label']}: {dynsym[9]}")
    symbols = checked_slice(
        elf["data"], dynsym[4], dynsym[5], f".dynsym in {elf['label']}"
    )
    for offset in range(0, len(symbols), SYMBOL.size):
        symbol = SYMBOL.unpack_from(symbols, offset)
        binding = symbol[1] >> 4
        if symbol[3] != SHN_UNDEF and binding in (STB_GLOBAL, STB_WEAK):
            exports.add(string_at(strings, symbol[0], f".dynstr in {elf['label']}"))
    return exports


def has_read_only_c_string(elf, value):
    needle = value.encode("ascii") + b"\0"
    for _, _, section in elf["sections"]:
        if (
            section[1] != SHT_PROGBITS
            or not section[2] & SHF_ALLOC
            or section[2] & SHF_WRITE
        ):
            continue
        contents = checked_slice(
            elf["data"], section[4], section[5], f"read-only data in {elf['label']}"
        )
        start = 0
        while True:
            position = contents.find(needle, start)
            if position < 0:
                break
            if position == 0 or contents[position - 1] == 0:
                return True
            start = position + 1
    return False


def installed_packages(image):
    output, diagnostic = run_debugfs(image, f"cat {DPKG_STATUS}")
    if "File not found" in diagnostic:
        raise Failure(f"missing status ({DPKG_STATUS})")
    try:
        text = output.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Failure(f"unparseable dpkg status: invalid UTF-8 at byte {exc.start}") from exc
    found = set()
    for stanza in re.split(r"\n[ \t]*\n", text):
        fields = {}
        for line in stanza.splitlines():
            if not line or line[0].isspace():
                continue
            key, separator, value = line.partition(":")
            if separator:
                fields[key] = value.strip()
        package = fields.get("Package")
        if package and fields.get("Status") == "install ok installed":
            found.add(package)
    return found


def verify(image):
    verify_ext4(image)
    passes = []
    for path in COMMANDS:
        mode, size = inode_stat(image, path)
        basename = path.rsplit("/", 1)[-1]
        if not mode & 0o111:
            raise Failure(f"not executable {basename} ({path}, mode={mode:#05o})")
        parse_elf(inode_bytes(image, path, size), path)
        passes.append(
            f"PASS: command {path} executable mode={mode:#05o} arch={ELF_DESCRIPTION}"
        )

    for path, descriptor, elements in PLUGINS:
        _, size = inode_stat(image, path)
        elf = parse_elf(inode_bytes(image, path, size), path)
        if descriptor not in exported_dynamic_symbols(elf):
            raise Failure(f"missing exported descriptor {descriptor} ({path})")
        for element, stored_value, runtime_template in elements:
            if not has_read_only_c_string(elf, stored_value):
                evidence = "runtime-name template" if runtime_template else "element string"
                raise Failure(f"missing read-only {evidence} {stored_value} ({path})")
            if runtime_template:
                proof = (
                    f"read_only_runtime_name_template={stored_value} NUL-terminated "
                    "literal_constructed_at_runtime=true"
                )
            else:
                proof = f"read_only_string={stored_value} NUL-terminated"
            passes.append(
                f"PASS: element {element} arch={ELF_DESCRIPTION} descriptor={descriptor} "
                f"exported {proof}; runtime registration remains the strict device probe's job"
            )

    found_packages = installed_packages(image)
    for package in PACKAGES:
        if package not in found_packages:
            raise Failure(f"missing package stanza {package} ({DPKG_STATUS})")
        passes.append(f"PASS: package stanza {package} Status=install ok installed")
    return passes


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--gpu-model", required=True, choices=("ddk", "open", "none"))
    parser.add_argument("--variant", required=True, choices=("dev", "release"))
    parser.add_argument("image")
    args = parser.parse_args()

    if args.gpu_model != "open" or args.variant != "dev":
        print(
            f"{TAG}: FAIL refusing excluded scope "
            f"gpu_model={args.gpu_model} variant={args.variant}",
            file=sys.stderr,
        )
        return 1
    if shutil.which("debugfs") is None:
        print(f"{TAG}: FAIL debugfs unavailable", file=sys.stderr)
        return 1
    try:
        passes = verify(args.image)
    except Failure as exc:
        print(f"{TAG}: FAIL {exc}", file=sys.stderr)
        return 1
    for passed in passes:
        print(passed)
    print(
        "PASS: Cedrus strict-decode userspace verified from final ext4 bytes "
        f"commands={len(COMMANDS)} plugins={len(PLUGINS)} packages={len(PACKAGES)} "
        "runtime registration remains the strict device probe's job"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
