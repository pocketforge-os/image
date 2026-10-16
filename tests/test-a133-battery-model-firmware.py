#!/usr/bin/env python3
"""Hermetic red/green checks for the A133 battery-model extractor."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
EXTRACTOR = ROOT / "scripts" / "extract-a133-battery-model.py"
MODEL = bytes(range(128))


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_fdtget(path: Path, words: str, returncode: int = 0) -> None:
    path.write_text(
        "#!/bin/sh\n"
        "set -eu\n"
        "[ \"$1\" = -t ] && [ \"$2\" = bx ]\n"
        "[ \"$4\" = /axp2202-parameter/battery-model ]\n"
        "[ \"$5\" = parameter ]\n"
        f"printf '%s\\n' '{words}'\n"
        f"exit {returncode}\n",
        encoding="utf-8",
    )
    path.chmod(0o755)


def invoke(source: Path, output: Path, fdtget: Path, source_sha: str,
           model_sha: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(EXTRACTOR),
            "--source", str(source),
            "--output", str(output),
            "--fdtget", str(fdtget),
            "--expected-source-sha256", source_sha,
            "--expected-model-sha256", model_sha,
        ],
        check=False,
        text=True,
        capture_output=True,
    )


def require_failure(result: subprocess.CompletedProcess[str], output: Path,
                    message: str) -> None:
    if result.returncode == 0:
        raise AssertionError(message)
    if output.exists():
        raise AssertionError(f"{message}: failure left output behind")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="a133-battery-model-") as tmp:
        work = Path(tmp)
        source = work / "vendor-dtb.bin"
        source.write_bytes(b"synthetic vendor dtb fixture\n")
        source_sha = digest(source.read_bytes())
        model_sha = digest(MODEL)
        fdtget = work / "fdtget"
        output = work / "axp717-tsp-battery-model.bin"
        words = " ".join(f"{byte:02x}" for byte in MODEL)

        write_fdtget(fdtget, words)
        result = invoke(source, output, fdtget, source_sha, model_sha)
        if result.returncode != 0:
            raise AssertionError(f"positive extraction failed: {result.stderr}")
        if output.read_bytes() != MODEL:
            raise AssertionError("positive extraction changed the model bytes")
        if output.stat().st_mode & 0o777 != 0o644:
            raise AssertionError("model output mode is not 0644")
        output.unlink()

        output.write_bytes(b"stale model")
        result = invoke(source, output, fdtget, "0" * 64, model_sha)
        require_failure(result, output, "wrong source digest was accepted")

        write_fdtget(fdtget, " ".join(words.split()[:-1]))
        result = invoke(source, output, fdtget, source_sha, model_sha)
        require_failure(result, output, "127-byte model was accepted")

        malformed_words = words.split()
        malformed_words[64] = "100"
        write_fdtget(fdtget, " ".join(malformed_words))
        result = invoke(source, output, fdtget, source_sha, model_sha)
        require_failure(result, output, "out-of-range model byte was accepted")

        write_fdtget(fdtget, words)
        result = invoke(source, output, fdtget, source_sha, "f" * 64)
        require_failure(result, output, "wrong model digest was accepted")

        write_fdtget(fdtget, words, returncode=9)
        result = invoke(source, output, fdtget, source_sha, model_sha)
        require_failure(result, output, "fdtget failure was accepted")

    print("a133-battery-model-firmware-test=PASS")


if __name__ == "__main__":
    main()
