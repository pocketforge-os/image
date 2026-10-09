#!/usr/bin/env python3
"""Hermetic contract for unprivileged DMA-heap access (tsp-mc9m.41.1013)."""

from __future__ import annotations

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
RULE = ROOT / "rootfs-overlay/etc/udev/rules.d/73-pocketforge-dma-heap.rules"
BUILDER = ROOT / "scripts/build-rootfs.sh"


def score(mode: int | None, group: str | None) -> str:
    if mode is None or group is None:
        return "blocked"
    if mode == 0o660 and group == "video":
        return "pass"
    return "fail"


rule = RULE.read_text(encoding="utf-8")
active = [line.strip() for line in rule.splitlines()
          if line.strip() and not line.lstrip().startswith("#")]
assert active == ['SUBSYSTEM=="dma_heap", GROUP="video", MODE="0660"']
assert 'MODE="0666"' not in rule
assert 'GROUP="video"' in rule

builder = BUILDER.read_text(encoding="utf-8")
source_rule = (
    'install -D -m 0644 "/work/src/rootfs-overlay/etc/udev/rules.d/'
    '73-pocketforge-dma-heap.rules"'
)
target_rule = '"${ROOTFS}/etc/udev/rules.d/73-pocketforge-dma-heap.rules"'
assert builder.count(source_rule) == 1
assert builder.count(target_rule) == 1

# The open-GPU image is produced by this builder.  Assert its own product-user
# setup, not a board customization hook that the production path may bypass.
assert re.search(
    r"usermod\s+-aG\s+(?:[a-z]+,)*video(?:,[a-z]+)*\s+gamer", builder
)

# Positive, prior-policy negative, and cannot-measure controls remain distinct.
assert score(0o660, "video") == "pass"
assert score(0o600, "root") == "fail"
assert score(None, None) == "blocked"
assert score(0o666, "video") == "fail"

print("PASS dma-heap udev policy, gamer video membership, and verdict controls")
