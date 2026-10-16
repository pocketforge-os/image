#!/usr/bin/env python3
"""Extract the TSP AXP717 fuel-gauge model from its preserved vendor DTB.

The source DTB remains under the non-redistributable sunxi-a133-boot-chain
vendor-manifest group.  This reproduces the extraction described by the
clean-room PMIC-RUNTIME-USBC.md R-A1 contract without publishing the model
bytes in an owned source repository.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


SOURCE_SHA256 = "f6486899b53e005f0df54bbac4b1183710f73e90efd94cd7cbde58cdfba792ac"
MODEL_SHA256 = "b44940da920519986192f758eb4eb65eea5728179ebdd28393671be4c5557c5a"
MODEL_SIZE = 128
MODEL_NODE = "/axp2202-parameter/battery-model"
MODEL_PROPERTY = "parameter"
HEX_BYTE = re.compile(r"[0-9a-fA-F]{1,2}\Z")


class ExtractionError(RuntimeError):
    """A validation failure that must stop image assembly."""


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_model(stdout: str) -> bytes:
    words = stdout.split()
    if len(words) != MODEL_SIZE:
        raise ExtractionError(
            f"battery model has {len(words)} bytes; expected {MODEL_SIZE}"
        )
    if any(HEX_BYTE.fullmatch(word) is None for word in words):
        raise ExtractionError("battery model contains a malformed byte")
    return bytes(int(word, 16) for word in words)


def extract(args: argparse.Namespace) -> None:
    source = Path(args.source)
    output = Path(args.output)

    # Never allow an earlier build's artifact to survive a failed extraction.
    output.unlink(missing_ok=True)
    if file_sha256(source) != args.expected_source_sha256:
        raise ExtractionError("vendor DTB SHA-256 does not match the custody pin")

    result = subprocess.run(
        [
            args.fdtget,
            "-t",
            "bx",
            str(source),
            MODEL_NODE,
            MODEL_PROPERTY,
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise ExtractionError(f"fdtget failed with rc={result.returncode}")

    model = parse_model(result.stdout)
    if hashlib.sha256(model).hexdigest() != args.expected_model_sha256:
        raise ExtractionError("extracted battery-model SHA-256 does not match the pin")

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=f".{output.name}.", dir=output.parent, delete=False
        ) as stream:
            temporary = Path(stream.name)
            stream.write(model)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(0o644)
        os.replace(temporary, output)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--fdtget", default="fdtget")
    parser.add_argument("--expected-source-sha256", default=SOURCE_SHA256)
    parser.add_argument("--expected-model-sha256", default=MODEL_SHA256)
    return parser.parse_args()


def main() -> int:
    try:
        extract(parse_args())
    except (ExtractionError, OSError) as error:
        print(f"FATAL: A133 battery-model extraction: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
