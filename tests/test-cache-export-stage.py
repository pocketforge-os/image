#!/usr/bin/env python3
"""Pin the cross-slot cache-export boundary (tsp-hqm1p.182.13).

CI solves `--target cache-export` after a successful image build and exports its
cache, mode=max, to the executing slot's registry ref. That stage must reach every
component that rootfs/assemble consume, so another slot's warm build can reuse
them. It must reach nothing keyed on the image-wide SOURCE_DATE_EPOCH, so the
per-image-commit rootfs/assemble layers are never uploaded.
"""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
TEXT = (ROOT / "build" / "Dockerfile.pf").read_text(encoding="utf-8")
FROM_RE = re.compile(r"^FROM\s+(\S+)\s+AS\s+([A-Za-z0-9_.-]+)\s*$", re.M)
REF_RE = re.compile(r"(?:--from=|\bfrom=)([A-Za-z0-9_.${}-]+)")
IMAGE_EPOCH_RE = re.compile(r"^ARG SOURCE_DATE_EPOCH(?:=.*)?$", re.M)
# Image-product stages: per image commit, useless to another slot.
IMAGE_STAGES = {"rootfs", "assemble", "debuginfo", "export"}


def parse(text):
    matches = list(FROM_RE.finditer(text))
    blocks, parents = {}, {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        blocks[match.group(2)] = text[match.start():end]
        parents[match.group(2)] = match.group(1)
    return blocks, parents


blocks, parents = parse(TEXT)


def resolve(name):
    """Stage names a FROM/--from reference can select (a ${ARG} picks a variant)."""
    if "${" not in name:
        return {name} if name in blocks else set()
    if re.fullmatch(r"\$\{[A-Za-z0-9_]+\}", name):
        return set()  # FROM ${PF_CONTAINER}: a digest-pinned external image
    pattern = re.compile("^" + re.sub(r"\\\$\\\{[A-Za-z0-9_]+\\\}", "[A-Za-z0-9_.-]+",
                                      re.escape(name)) + "$")
    found = {stage for stage in blocks if pattern.match(stage)}
    assert found, f"unresolvable stage reference {name}"
    return found


def direct(stage):
    refs = set(REF_RE.findall(blocks[stage]))
    out = set()
    for ref in refs | {parents[stage]}:
        out |= resolve(ref)
    return out


def closure(stage):
    seen, todo = set(), [stage]
    while todo:
        current = todo.pop()
        if current in seen:
            continue
        seen.add(current)
        todo.extend(direct(current) - seen)
    return seen


assert "cache-export" in blocks, "missing cache-export target"
export = blocks["cache-export"]
assert parents["cache-export"] == "scratch", "cache-export must be FROM scratch"
assert not re.search(r"^RUN\b", export, re.M), "cache-export must not run anything"
contexts = set(REF_RE.findall(export)) - set(blocks)
assert not contexts, f"cache-export copies named contexts: {sorted(contexts)}"

# Every component stage rootfs/assemble consume directly, plus rootfs's parent.
wanted = set()
for stage in ("rootfs", "assemble"):
    wanted |= {ref for ref in REF_RE.findall(blocks[stage]) if ref in blocks}
wanted -= IMAGE_STAGES
wanted.add(parents["rootfs"])
have = set(REF_RE.findall(export))
assert have == wanted, (
    f"cache-export components drifted: missing={sorted(wanted - have)} "
    f"extra={sorted(have - wanted)}"
)

reach = closure("cache-export")
leaked = sorted(reach & IMAGE_STAGES)
assert not leaked, f"cache-export reaches image-product stages {leaked}"
epoch = sorted(stage for stage in reach if IMAGE_EPOCH_RE.search(blocks.get(stage, "")))
assert not epoch, f"cache-export reaches image-epoch stages {epoch}"
# Positive control: the image stages really carry the image epoch, so the check
# above would see a leak.
for stage in ("rootfs", "assemble", "debuginfo"):
    assert IMAGE_EPOCH_RE.search(blocks[stage]), f"{stage}: image epoch control lost"

print(
    f"cache-export-stage-test=PASS components={len(have)} reachable_stages={len(reach)} "
    "image_epoch_stages=0"
)
