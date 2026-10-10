#!/usr/bin/env python3
"""Fail closed when component stages regain image-revision cache inputs."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
DOCKERFILE = ROOT / "build" / "Dockerfile.pf"
TEXT = DOCKERFILE.read_text(encoding="utf-8")


def stages(text: str) -> dict[str, str]:
    matches = list(re.finditer(r"^FROM\s+.+?\s+AS\s+([A-Za-z0-9_.-]+)\s*$", text, re.M))
    return {
        match.group(1): text[match.start() : matches[index + 1].start() if index + 1 < len(matches) else len(text)]
        for index, match in enumerate(matches)
    }


blocks = stages(TEXT)
component_epochs = {
    "kernel": "PF_KERNEL_SOURCE_DATE_EPOCH",
    "gpu-km-build": "PF_KERNEL_SOURCE_DATE_EPOCH",
    "gpu-um-source": "PF_GPU_UM_SOURCE_DATE_EPOCH",
    "gpu-um-native-precompilers": "PF_GPU_UM_SOURCE_DATE_EPOCH",
    "gpu-um-build": "PF_GPU_UM_SOURCE_DATE_EPOCH",
    "bootchain": "PF_BOOTCHAIN_SOURCE_DATE_EPOCH",
    "sdl": "PF_LIBSDL3_SOURCE_DATE_EPOCH",
    "wpa": "PF_WPA_SOURCE_DATE_EPOCH",
    "cloud-init": "PF_CLOUD_INIT_SOURCE_DATE_EPOCH",
    "runtime": "PF_RUNTIME_SOURCE_DATE_EPOCH",
    "platform-runtime-steamlink-ffmpeg59-v1": "PF_FFMPEG_SOURCE_DATE_EPOCH",
    "sdl-static": "PF_SDL_STATIC_SOURCE_DATE_EPOCH",
    "hwprobe-dev": "PF_HWPROBE_SOURCE_DATE_EPOCH",
    "poolsuite-dev": "PF_POOLSUITE_SOURCE_DATE_EPOCH",
    "recovery-open": "PF_RECOVERY_SOURCE_DATE_EPOCH",
    "launcher-open": "PF_LAUNCHER_SOURCE_DATE_EPOCH",
}

for stage, epoch in component_epochs.items():
    block = blocks[stage]
    assert f"ARG {epoch}" in block, f"{stage}: missing {epoch}"
    assert not re.search(r"^ARG SOURCE_DATE_EPOCH(?:=|$)", block, re.M), (
        f"{stage}: image-wide SOURCE_DATE_EPOCH still changes its cache key"
    )
    assert "${SOURCE_DATE_EPOCH:-" not in block, f"{stage}: generic epoch fallback remains"

for stage in ("rootfs", "assemble"):
    assert re.search(r"^ARG SOURCE_DATE_EPOCH$", blocks[stage], re.M), (
        f"{stage}: final image epoch must remain explicit"
    )

fetch = blocks["fetch"]
assert "ARG PF_DEVICE_ID" not in fetch
assert "COPY --from=vendor-manifest-src" not in fetch
assert "COPY --from=blobs-car" not in fetch
assert "COPY --from=blobs-src" not in fetch
for source in ("vendor-manifest-src", "blobs-car", "blobs-src"):
    assert f"type=bind,from={source}" in fetch, f"fetch: missing read-only bind for {source}"
assert 'find "${IPFS_PATH}" -mindepth 1 -delete' in fetch
assert 'rmdir "${IPFS_PATH}"' in fetch

cloud = blocks["cloud-init"]
recovery = blocks["recovery-open"]
assert "COPY --from=image-src . /work/image" not in cloud
assert "COPY --from=image-src . /work/image" not in recovery
assert "COPY --from=image-src tests/test-cloud-init-firstboot.sh" in cloud
assert "COPY --from=image-src apps/pocketforge-recovery-entry" in recovery

profile_only_args = {
    "gpu-km-build": ("PF_DEVICE_ID",),
    "bootchain": ("PF_DEVICE_ID",),
    "sdl": ("PF_DEVICE_ID", "PF_GPU_REPO"),
    "wpa": ("PF_DEVICE_ID", "PF_GPU_REPO"),
    "runtime": ("PF_DEVICE_ID", "PF_GPU_REPO"),
    "launcher-open": ("PF_DEVICE_ID", "PF_GPU_REPO"),
}
for stage, names in profile_only_args.items():
    for name in names:
        assert f"ARG {name}" not in blocks[stage], f"{stage}: provenance-only {name} keys the producer"

for stage in (
    "fetch", "kernel", "gpu-km", "gpu-um", "bootchain", "sdl", "wpa",
    "cloud-init", "runtime", "ffmpeg", "sdl-static", "hwprobe", "poolsuite",
    "recovery", "launcher", "gamescope",
):
    target = f"component-test-{stage}"
    assert target in blocks, f"missing CI byte-test target {target}"
    assert f"COPY --from={stage if stage not in {'gpu-um', 'ffmpeg'} else {'gpu-um': 'gpu-um-mesa', 'ffmpeg': 'platform-runtime-steamlink-ffmpeg59'}[stage]} /out /" in blocks[target]

print(
    "component-cache-key-test=PASS image_epoch_consumers=rootfs,assemble "
    f"component_epoch_stages={len(component_epochs)} fetch=output-only"
)
