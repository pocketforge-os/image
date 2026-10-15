#!/usr/bin/env python3
"""Write a stable, full metadata/content inventory of a payload tree."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys


def digest_file(path: str) -> str:
    value = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def inventory(root: str):
    pending = [""]
    while pending:
        rel = pending.pop()
        path = os.path.join(root, rel) if rel else root
        for entry in sorted(os.scandir(path), key=lambda item: os.fsencode(item.name)):
            child = os.path.join(rel, entry.name) if rel else entry.name
            info = entry.stat(follow_symlinks=False)
            mode = f"{stat.S_IMODE(info.st_mode):04o}"
            if stat.S_ISREG(info.st_mode):
                kind = "file"
                digest = digest_file(entry.path)
            elif stat.S_ISLNK(info.st_mode):
                kind = "symlink"
                digest = hashlib.sha256(os.fsencode(os.readlink(entry.path))).hexdigest()
            elif stat.S_ISDIR(info.st_mode):
                kind = "dir"
                digest = "-"
                pending.append(child)
            else:
                kind = "other"
                digest = "-"
            yield child, kind, mode, info.st_uid, info.st_gid, digest


def main() -> int:
    if len(sys.argv) != 3 or not os.path.isdir(sys.argv[1]):
        print("usage: inventory-guest-payload.py ROOT OUTPUT", file=sys.stderr)
        return 64
    rows = sorted(inventory(os.path.realpath(sys.argv[1])), key=lambda row: os.fsencode(row[0]))
    with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as output:
        output.write("path\ttype\tmode\tuid\tgid\tsha256\n")
        for path, kind, mode, uid, gid, digest in rows:
            output.write(
                f"{json.dumps(path, ensure_ascii=True)}\t{kind}\t{mode}\t{uid}\t{gid}\t{digest}\n"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
