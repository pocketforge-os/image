#!/usr/bin/env python3
"""Apply a minimal execute-only Landlock rule and probe one executable."""

import argparse
import ctypes
import os
from pathlib import Path
import subprocess


SYS_LANDLOCK_CREATE_RULESET = 444
SYS_LANDLOCK_ADD_RULE = 445
SYS_LANDLOCK_RESTRICT_SELF = 446
LANDLOCK_CREATE_RULESET_VERSION = 1
LANDLOCK_RULE_PATH_BENEATH = 1
LANDLOCK_ACCESS_FS_EXECUTE = 1 << 0
PR_SET_NO_NEW_PRIVS = 38


class RulesetAttr(ctypes.Structure):
    _fields_ = [("handled_access_fs", ctypes.c_uint64)]


class PathBeneathAttr(ctypes.Structure):
    _pack_ = 1
    _fields_ = [
        ("allowed_access", ctypes.c_uint64),
        ("parent_fd", ctypes.c_int32),
    ]


def syscall(libc: ctypes.CDLL, number: int, *args: object) -> int:
    result = libc.syscall(number, *args)
    if result < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    return result


def restrict_execute(grants: list[Path]) -> int:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    abi = syscall(
        libc,
        SYS_LANDLOCK_CREATE_RULESET,
        0,
        0,
        LANDLOCK_CREATE_RULESET_VERSION,
    )
    if abi < 1:
        raise RuntimeError(f"Landlock ABI {abi} lacks filesystem execute rules")
    ruleset_attr = RulesetAttr(LANDLOCK_ACCESS_FS_EXECUTE)
    ruleset = syscall(
        libc,
        SYS_LANDLOCK_CREATE_RULESET,
        ctypes.byref(ruleset_attr),
        ctypes.sizeof(ruleset_attr),
        0,
    )
    try:
        for grant in grants:
            parent = os.open(grant, os.O_PATH | os.O_CLOEXEC)
            try:
                rule = PathBeneathAttr(LANDLOCK_ACCESS_FS_EXECUTE, parent)
                syscall(
                    libc,
                    SYS_LANDLOCK_ADD_RULE,
                    ruleset,
                    LANDLOCK_RULE_PATH_BENEATH,
                    ctypes.byref(rule),
                    0,
                )
            finally:
                os.close(parent)
        if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        syscall(libc, SYS_LANDLOCK_RESTRICT_SELF, ruleset, 0)
    finally:
        os.close(ruleset)
    return abi


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--grant", action="append", type=Path, default=[])
    parser.add_argument("--expect", choices=("eacces", "success"), required=True)
    parser.add_argument("executable", type=Path)
    args = parser.parse_args()

    abi = restrict_execute(args.grant)
    try:
        result = subprocess.run(
            [args.executable],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except PermissionError as error:
        if args.expect != "eacces" or error.errno != 13:
            raise
        print(f"landlock-exec=EACCES errno=13 abi={abi} target={args.executable}")
        return 0
    if args.expect != "success" or result.returncode != 0:
        raise AssertionError(
            f"unexpected exec result: expected={args.expect} result={result}"
        )
    print(f"landlock-exec=PASS abi={abi} target={args.executable}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
