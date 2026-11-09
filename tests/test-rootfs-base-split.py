#!/usr/bin/env python3
"""Pin the cached rootfs-base input boundary (tsp-hqm1p.182.13).

The rootfs-base stage runs the a133 apt solve under qemu once per solve input.
It must not depend on the image tree, the image-wide epoch or any component
except the ones whose debs join the solve. Otherwise every image commit would
re-run it, which is the 17-minute cost this split removes. Every file the base
recipe reads from SRC_DIR must be among the files the stage copies. rootfs must
replay the base, and both mmdebstrap passes must take their options from
scripts/rootfs-package-list.sh.
"""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
TEXT = (ROOT / "build" / "Dockerfile.pf").read_text(encoding="utf-8")
LIB = (ROOT / "scripts" / "rootfs-package-list.sh").read_text(encoding="utf-8")
BASE = (ROOT / "scripts" / "build-rootfs-base.sh").read_text(encoding="utf-8")
FULL = (ROOT / "scripts" / "build-rootfs.sh").read_text(encoding="utf-8")
FROM_RE = re.compile(r"^FROM\s+(\S+)\s+AS\s+([A-Za-z0-9_.-]+)\s*$", re.M)
REF_RE = re.compile(r"(?:--from=|\bfrom=)([A-Za-z0-9_.${}-]+)")

matches = list(FROM_RE.finditer(TEXT))
blocks, parents = {}, {}
for index, match in enumerate(matches):
    end = matches[index + 1].start() if index + 1 < len(matches) else len(TEXT)
    blocks[match.group(2)] = TEXT[match.start():end]
    parents[match.group(2)] = match.group(1)

base = blocks["rootfs-base"]
assert parents["rootfs-base"] == "pf-build-base", parents["rootfs-base"]
refs = set(REF_RE.findall(base))
assert refs == {"image-src", "cloud-init", "gpu-um-mesa"}, sorted(refs)

args = set(re.findall(r"^ARG ([A-Z0-9_]+)", base, re.M))
assert args == {"PF_DEVICE_ID", "PF_SOC", "PF_GPU_MODEL", "PF_DISPLAY_PIPELINE",
                "PF_VARIANT", "PF_GAMESCOPE_MODE"}, sorted(args)

copied = set()
for line in re.findall(r"^COPY --from=image-src (.+)$", base, re.M):
    *sources, dest = line.split()
    assert "." not in sources, "rootfs-base must not copy the whole image tree"
    copied |= set(sources)
read = set(re.findall(r'\$\{SRC_DIR\}/([A-Za-z0-9_./-]+)', LIB + BASE))
missing = sorted(read - copied)
assert not missing, f"the base recipe reads files the stage does not copy: {missing}"
assert {"scripts/build-rootfs-base.sh", "scripts/rootfs-package-list.sh"} <= copied

rootfs = blocks["rootfs"]
assert "COPY --from=rootfs-base /out /work/rootfs-base" in rootfs
a133 = rootfs[rootfs.index("sun50iw10p1)"):rootfs.index("sun55iw3)")]
assert "PF_ROOTFS_BASE_DIR=/work/rootfs-base" in a133
assert "PF_ROOTFS_BASE_DIR" not in rootfs[rootfs.index("sun55iw3)"):]

# Both passes solve with the shared options; only the overlay replays the base.
assert re.search(r'"\$\{MMDEBSTRAP\}" \\\n\s+"\$\{MMDEBSTRAP_SOLVE_OPTS\[@\]\}" \\\n\s+--skip=cleanup \\\n'
                 r'\s+"\$\{MMDEBSTRAP_DPKG_OPTS\[@\]\}"', BASE)
assert "--customize-hook" not in BASE
assert 'MMDEBSTRAP_PASS_OPTS=("${MMDEBSTRAP_SOLVE_OPTS[@]}")' in FULL
assert 'MMDEBSTRAP_PASS_OPTS=("${MMDEBSTRAP_OVERLAY_OPTS[@]}")' in FULL
assert 'pf_rootfs_base_verify "${PF_ROOTFS_BASE_DIR}"' in FULL
assert re.search(r'mmdebstrap \\\n\s+"\$\{MMDEBSTRAP_PASS_OPTS\[@\]\}" \\\n\s+--customize-hook=', FULL)
assert '"${MMDEBSTRAP_DPKG_OPTS[@]}" \\\n    bookworm \\\n    "${ROOTFS_TAR}"' in FULL
assert FULL.count("mmdebstrap \\\n") == 1, "build-rootfs.sh must have exactly one mmdebstrap call"
for stale in ("--variant=minbase", "--include=\"${PKG_LIST}\"", "path-exclude=/usr/share/man"):
    assert stale not in FULL, f"build-rootfs.sh still spells {stale} itself"

print(f"rootfs-base-split-test=PASS base_inputs={len(copied)} files+cloud-init+gpu-um-mesa "
      f"recipe_reads={len(read)}")
