#!/usr/bin/env python3
# pf-elf-buildid.py — ELF build-id gate, image build-id manifest and debuginfo
# split for the PocketForge image build (cr-symbols; bd tsp-ihne1.33).
#
# Subcommands:
#   check    ROOT [--closed-paths DIR ...]         fail (exit 1) unless every ELF
#            outside the closed paths carries a GNU build-id (NT_GNU_BUILD_ID).
#   manifest ROOT [--closed-paths DIR ...]         print the image build-id
#            manifest — a TSV of lowercase-hex build-id and absolute in-image
#            path. Closed paths are omitted: vendored binaries carry no build-id
#            and are never nameable, so the on-device collector reports them as
#            "?" frames by construction. Fails (exit 1) if any non-closed ELF
#            lacks a build-id.
#   split    ROOT STORE [--closed-paths DIR ...]   split DWARF-carrying ELFs:
#            objcopy --only-keep-debug into the debuginfod-compatible store
#            (<STORE>/buildid/<aa>/<rest>/debuginfo) and strip the shipped copy.
#            Non-DWARF ELFs pass through unchanged but are still gated on
#            carrying a build-id.
#
# Exit status: 0 pass; 1 gate failure; 2 usage error.
#
# Implementation notes:
#   - Parses ELF program headers + PT_NOTE segments natively (struct, no
#     readelf subprocess per file), so a full rootfs scan is fast, and works
#     for both endiannesses and ELF32/ELF64. Files whose magic is not ELF are
#     skipped; a truncated ELF is a gate failure under check.
#   - DWARF detection reads the section-name string table; .debug_info and
#     .zdebug_info both count.
#   - Deterministic: manifest rows sorted by (build-id, path); store paths are
#     a pure function of the build-id.
#   - Walkers lstat every entry (never os.path.isfile): a symlink of any class
#     is skipped, so an in-image symlink can never resolve against, be recorded
#     for, or mutate anything outside ROOTFS (objcopy/strip only ever see
#     regular files physically inside the tree). Closed prefixes must likewise
#     be real directories; a symlinked prefix is not walked.
import argparse
import os
import shutil
import stat
import struct
import sys
from subprocess import run


ELF_MAGIC = b"\x7fELF"
NT_GNU_BUILD_ID = 3
PT_NOTE = 4


class ElfError(Exception):
    pass


def _read(fd, off, size):
    fd.seek(off)
    data = fd.read(size)
    if len(data) != size:
        raise ElfError("truncated")
    return data


def _endian(ei_data):
    if ei_data == 1:
        return "<"
    if ei_data == 2:
        return ">"
    raise ElfError("unrecognised EI_DATA")


def _parse_notes(blob, endian):
    """Yield (name, type, desc) tuples from a concatenated-notes blob."""
    pos = 0
    while pos + 12 <= len(blob):
        namesz, descsz, ntype = struct.unpack(endian + "III", blob[pos:pos + 12])
        pos += 12
        name = blob[pos:pos + namesz].rstrip(b"\x00")
        pos += (namesz + 3) & ~3
        desc = blob[pos:pos + descsz]
        if pos + descsz > len(blob):
            break
        yield name, ntype, desc
        pos += (descsz + 3) & ~3


def build_id_of(path):
    """Return the lowercase-hex GNU build-id of an ELF file, or None when the
    file is not ELF. Raise ElfError on a malformed/truncated ELF.

    Reads PT_NOTE program-headers segments AND SHT_NOTE sections: executables
    and DSOs carry the id in a loadable PT_NOTE segment, while relocatable
    objects (kernel .ko modules are linked with `ld -r`) carry it only in the
    .note.gnu.build-id section."""
    with open(path, "rb") as fd:
        if _read(fd, 0, 4) != ELF_MAGIC:
            return None
        ei_class = _read(fd, 4, 1)[0]
        endian = _endian(_read(fd, 5, 1)[0])
        if ei_class == 1:  # ELF32
            phoff = struct.unpack(endian + "I", _read(fd, 28, 4))[0]
            phentsize, phnum = struct.unpack(endian + "HH", _read(fd, 42, 4))
            shoff = struct.unpack(endian + "I", _read(fd, 32, 4))[0]
            shentsize, shnum = struct.unpack(endian + "HH", _read(fd, 46, 4))
            # phdr: p_offset@4, p_filesz@16; shdr: sh_offset@16, sh_size@20
            ph_off_field, ph_sz_field = 4, 16
            sh_off_field, sh_sz_field = 16, 20
        elif ei_class == 2:  # ELF64
            phoff = struct.unpack(endian + "Q", _read(fd, 32, 8))[0]
            phentsize, phnum = struct.unpack(endian + "HH", _read(fd, 54, 4))
            shoff = struct.unpack(endian + "Q", _read(fd, 40, 8))[0]
            shentsize, shnum = struct.unpack(endian + "HH", _read(fd, 58, 4))
            # phdr: p_offset@8, p_filesz@32; shdr: sh_offset@24, sh_size@32
            ph_off_field, ph_sz_field = 8, 32
            sh_off_field, sh_sz_field = 24, 32
        else:
            raise ElfError("unrecognised EI_CLASS")
        if shnum == 0xFFFF:  # extended section count needs SHN_XINDEX: refuse
            raise ElfError("extended section count unsupported")
        build_id = None
        for i in range(phnum):
            ph = _read(fd, phoff + i * phentsize, phentsize)
            p_type = struct.unpack(endian + "I", ph[0:4])[0]
            if p_type != PT_NOTE:
                continue
            if ei_class == 1:
                p_offset = struct.unpack(endian + "I", ph[ph_off_field:ph_off_field + 4])[0]
                p_filesz = struct.unpack(endian + "I", ph[ph_sz_field:ph_sz_field + 4])[0]
            else:
                p_offset = struct.unpack(endian + "Q", ph[ph_off_field:ph_off_field + 8])[0]
                p_filesz = struct.unpack(endian + "Q", ph[ph_sz_field:ph_sz_field + 8])[0]
            for name, ntype, desc in _parse_notes(_read(fd, p_offset, p_filesz), endian):
                if ntype == NT_GNU_BUILD_ID and name == b"GNU" and desc:
                    build_id = desc.hex()
        if build_id is None:
            for i in range(shnum):
                sh = _read(fd, shoff + i * shentsize, shentsize)
                sh_type = struct.unpack(endian + "I", sh[4:8])[0]
                if sh_type != 7:  # SHT_NOTE
                    continue
                if ei_class == 1:
                    sh_offset = struct.unpack(endian + "I", sh[sh_off_field:sh_off_field + 4])[0]
                    sh_size = struct.unpack(endian + "I", sh[sh_sz_field:sh_sz_field + 4])[0]
                else:
                    sh_offset = struct.unpack(endian + "Q", sh[sh_off_field:sh_off_field + 8])[0]
                    sh_size = struct.unpack(endian + "Q", sh[sh_sz_field:sh_sz_field + 8])[0]
                for name, ntype, desc in _parse_notes(_read(fd, sh_offset, sh_size), endian):
                    if ntype == NT_GNU_BUILD_ID and name == b"GNU" and desc:
                        build_id = desc.hex()
                        break
                if build_id is not None:
                    break
        return build_id


def has_debug_info(path):
    """True when the ELF keeps a DWARF section (.debug_info / .zdebug_info)."""
    try:
        with open(path, "rb") as fd:
            if _read(fd, 0, 4) != ELF_MAGIC:
                return False
            ei_class = _read(fd, 4, 1)[0]
            endian = _endian(_read(fd, 5, 1)[0])
            up = endian
            if ei_class == 1:
                shoff = struct.unpack(up + "I", _read(fd, 32, 4))[0]
                shentsize, shnum, shstrndx = struct.unpack(up + "HHH", _read(fd, 46, 6))
            elif ei_class == 2:
                shoff = struct.unpack(up + "Q", _read(fd, 40, 8))[0]
                shentsize, shnum, shstrndx = struct.unpack(up + "HHH", _read(fd, 58, 6))
            else:
                return False
            if not shoff or not shnum:
                return False
            shstr = _read(fd, shoff + shstrndx * shentsize, shentsize)
            if ei_class == 1:
                str_off = struct.unpack(up + "I", shstr[16:20])[0]
                str_sz = struct.unpack(up + "I", shstr[20:24])[0]
            else:
                str_off = struct.unpack(up + "Q", shstr[24:32])[0]
                str_sz = struct.unpack(up + "Q", shstr[32:40])[0]
            names = _read(fd, str_off, str_sz)
            for i in range(shnum):
                sh = _read(fd, shoff + i * shentsize, shentsize)
                name_idx = struct.unpack(up + "I", sh[0:4])[0]
                end = names.find(b"\x00", name_idx)
                name = names[name_idx:end if end != -1 else len(names)]
                if name in (b".debug_info", b".zdebug_info"):
                    return True
            return False
    except ElfError:
        return False


def _is_regular_file(path):
    """True only for a regular file per lstat: symlinks are never followed."""
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def iter_elves(root, closed_prefixes):
    """Yield (abs_path, in_image_path) for every regular ELF file under root
    that lies outside the closed prefixes (symlinks and non-ELFs skipped)."""
    norm_root = os.path.normpath(root)
    norm_closed = [os.path.normpath(os.path.abspath(p)) for p in closed_prefixes]
    for dirpath, dirnames, filenames in os.walk(norm_root):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if not _is_regular_file(path):
                continue
            try:
                with open(path, "rb") as fd:
                    if fd.read(4) != ELF_MAGIC:
                        continue
            except OSError:
                continue
            if any(path == p or path.startswith(p + os.sep) for p in norm_closed):
                continue
            yield path, "/" + os.path.relpath(path, norm_root)


def count_closed_elves(closed_prefixes):
    count = 0
    for prefix in closed_prefixes:
        prefix_abs = os.path.normpath(os.path.abspath(prefix))
        try:
            if not stat.S_ISDIR(os.lstat(prefix_abs).st_mode):
                continue
        except OSError:
            continue
        for dirpath, _dirnames, filenames in os.walk(prefix_abs):
            for name in filenames:
                p = os.path.join(dirpath, name)
                if not _is_regular_file(p):
                    continue
                try:
                    with open(p, "rb") as fd:
                        if fd.read(4) != ELF_MAGIC:
                            continue
                except OSError:
                    continue
                count += 1
    return count


def cmd_check(args):
    root = os.path.abspath(args.root)
    elfs = 0
    missing = []
    for path, rel in iter_elves(root, args.closed_paths or []):
        elfs += 1
        try:
            b_id = build_id_of(path)
        except ElfError:
            missing.append(rel + " (unreadable/malformed ELF)")
            continue
        if b_id is None:
            missing.append(rel)
    if elfs == 0:
        print(f"check: no ELF files found under {root} (wrong tree?)")
        return 1
    closed = count_closed_elves(args.closed_paths or [])
    if missing:
        print(f"check: {len(missing)} ELF file(s) without a GNU build-id (checked {elfs}"
              f" non-closed, {closed} closed-vendor):")
        for rel in sorted(set(missing)):
            print(f"check: no GNU build-id: {rel}")
        print("check: link with --build-id; vendored closed binaries belong under a "
              "--closed-paths directory (cr-symbols)")
        return 1
    print(f"check: checked={elfs} closed={closed} missing=0")
    return 0


def cmd_manifest(args):
    root = os.path.abspath(args.root)
    rows = []
    elfs = 0
    for path, rel in iter_elves(root, args.closed_paths or []):
        elfs += 1
        try:
            b_id = build_id_of(path)
        except ElfError:
            b_id = None
        if b_id is None:
            print(f"manifest: no GNU build-id: {rel}", file=sys.stderr)
            return 1
        rows.append((b_id, rel))
    if elfs == 0:
        print(f"manifest: no ELF files found under {root} (wrong tree?)", file=sys.stderr)
        return 1
    print("# pocketforge elf build-id manifest v1")
    print("# build-id <tab> absolute in-image path; sorted; vendored closed ELFs omitted")
    for b_id, rel in sorted(rows):
        print(f"{b_id}\t{rel}")
    return 0


def cmd_split(args):
    root = os.path.abspath(args.root)
    store = os.path.abspath(args.store)
    # The store exists even when the tree owns no DWARF-bearing ELF (a523 row);
    # callers rely on <store>/buildid as the canonical empty-store shape.
    os.makedirs(os.path.join(store, "buildid"), exist_ok=True)
    n_debug = 0
    n_scanned = 0
    n_missing = 0
    for path, rel in iter_elves(root, args.closed_paths or []):
        n_scanned += 1
        try:
            b_id = build_id_of(path)
        except ElfError:
            b_id = None
        if b_id is None:
            print(f"split: no GNU build-id: {rel}", file=sys.stderr)
            n_missing += 1
            continue
        if not has_debug_info(path):
            continue
        dest_dir = os.path.join(store, "buildid", b_id[:2], b_id[2:])
        os.makedirs(dest_dir, exist_ok=True)
        debug = os.path.join(dest_dir, "debuginfo")
        r = run([args.objcopy, "--only-keep-debug", path, debug],
                capture_output=True, text=True)
        if r.returncode != 0:
            print(f"split: objcopy --only-keep-debug failed for {rel}: "
                  f"{r.stderr.strip()}", file=sys.stderr)
            return 1
        r = run([args.strip, path], capture_output=True, text=True)
        if r.returncode != 0:
            print(f"split: strip failed for {rel}: {r.stderr.strip()}", file=sys.stderr)
            return 1
        n_debug += 1
    if n_missing:
        print(f"split: {n_missing} ELF(s) without a GNU build-id (build gate) => fail",
              file=sys.stderr)
        return 1
    if n_scanned == 0:
        print(f"split: no ELF files found under {root} (wrong tree?)", file=sys.stderr)
        return 1
    print(f"split: scanned={n_scanned} with-debug={n_debug} store={store}")
    return 0


def _resolve(tool, env_name):
    path = os.environ.get(env_name)
    if path:
        if not (os.path.isfile(path) and os.access(path, os.X_OK)):
            raise SystemExit(f"pf-elf-buildid: {env_name}={path} is not an executable file")
        return path
    # Prefer the pinned cross binutils when present (the build container ships
    # /opt/arm-10.3-2021.07/bin/aarch64-none-linux-gnu-{objcopy,strip}).
    cross = f"/opt/arm-10.3-2021.07/bin/aarch64-none-linux-gnu-{tool}"
    if os.path.isfile(cross) and os.access(cross, os.X_OK):
        return cross
    found = shutil.which(tool)
    if not found:
        raise SystemExit(f"pf-elf-buildid: no {tool} binary found on PATH")
    return found


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    parser = argparse.ArgumentParser(prog="pf-elf-buildid.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    for name, help_text, with_store in (
            ("check", "fail unless every ELF has a GNU build-id", False),
            ("manifest", "print the image build-id manifest", False),
            ("split", "split DWARF into the build-id store", True)):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("root")
        if with_store:
            p.add_argument("store")
        p.add_argument("--closed-paths", nargs="*", default=[],
                       help="directories of vendored closed binaries (exempt from "
                            "the gate, omitted from the manifest)")
        p.set_defaults(func={"check": cmd_check, "manifest": cmd_manifest,
                             "split": cmd_split}[name])

    args = parser.parse_args(argv)
    if args.cmd == "split":
        args.objcopy = _resolve("objcopy", "PF_OBJCOPY")
        args.strip = _resolve("strip", "PF_STRIP")
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())