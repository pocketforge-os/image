#!/usr/bin/env python3
"""Verify the TG5040 payload-layout gate stays in the owned a133 build path."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
dockerfile = (ROOT / "build/Dockerfile.pf").read_text(encoding="utf-8")
builder = (ROOT / "scripts/build-sd-image.sh").read_text(encoding="utf-8")


def require(text: str, snippet: str, source: str) -> None:
    if snippet not in text:
        raise SystemExit(f"FAIL: {source} is missing {snippet!r}")


require(
    dockerfile,
    "install -D -m0755 tools/check_tg5040_boot_layout.py /out/check-tg5040-boot-layout.py",
    "Dockerfile bootchain stage",
)
require(
    dockerfile,
    "install -D -m0644 .config /out/uboot.config",
    "Dockerfile bootchain stage",
)
require(
    dockerfile,
    '--uboot-layout-check "${UBOOT_LAYOUT_CHECK}" --uboot-config "${UBOOT_CONFIG}"',
    "Dockerfile a133 assemble dispatch",
)
require(
    builder,
    'python3 "${UBOOT_LAYOUT_CHECK}"',
    "build-sd-image owned-SPL path",
)
require(builder, '--config "${UBOOT_CONFIG}"', "layout-check invocation")
require(builder, '--image "${KERNEL_IMAGE}"', "layout-check invocation")
require(builder, '--fdt "${DTB_FILE}"', "layout-check invocation")
require(builder, '--initrd "${WORK}/initrd.gz"', "layout-check invocation")

check = builder.index('python3 "${UBOOT_LAYOUT_CHECK}"')
stage = builder.index(
    'mcopy -i "${GENIMAGE_INPUT}/boot-resource.vfat" "${KERNEL_IMAGE}"', check
)
if check >= stage:
    raise SystemExit("FAIL: owned-SPL payloads are staged before the layout gate")

print("PASS: TG5040 layout gate and generated U-Boot config are wired before payload staging")
