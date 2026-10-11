#!/usr/bin/env python3
"""Hermetic policy test for every image-owned ELF producer class."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def verify(dockerfile: str, rootfs: str, finalizer: str) -> None:
    required = {
        "PowerVR firmware closed-vendor directory": (
            finalizer,
            '"${ROOTFS}/usr/lib/firmware/powervr"',
        ),
        "SDL CMake stage": (
            dockerfile,
            'LDFLAGS="-Wl,--build-id=sha1" \\\n+OUT=/work/out bash /work/src/build/build-libsdl3.sh',
        ),
        "wpa Make stage": (
            dockerfile,
            'LDFLAGS="-Wl,--build-id=sha1 -B/usr/lib/aarch64-linux-gnu -L/usr/lib/aarch64-linux-gnu"',
        ),
        "hwprobe Make stage": (
            dockerfile,
            'LDFLAGS="-Wl,--build-id=sha1" \\\n+  OUT_DIR=/out/bin',
        ),
        "runtime GNU Rust links": (
            dockerfile,
            'RUSTFLAGS="--remap-path-prefix=/work/runtime=. -C link-arg=-Wl,--build-id=sha1"',
        ),
        "runtime musl Rust links": (
            dockerfile,
            'RUSTFLAGS="--remap-path-prefix=/work/runtime=. -C link-arg=--build-id=sha1"',
        ),
        "recovery musl Rust link": (
            dockerfile,
            'RUSTFLAGS="-C link-arg=--build-id=sha1" \\\n+cargo build --offline --locked --release --target aarch64-unknown-linux-musl',
        ),
        "launcher musl Rust link": (
            dockerfile,
            'RUSTFLAGS="--remap-path-prefix=/work/launcher=. -C link-arg=--build-id=sha1"',
        ),
        "Poolsuite GNU Rust link": (
            dockerfile,
            'RUSTFLAGS="-C link-arg=-Wl,--build-id=sha1" ./ci/device-build.sh --offline',
        ),
    }
    missing = [name for name, (text, needle) in required.items() if needle not in text]
    if rootfs.count('"${BUILD_ID_LDFLAG}"') != 4:
        missing.append("four direct rootfs ARM GCC links")
    if 'BUILD_ID_LDFLAG="-Wl,--build-id=sha1"' not in rootfs:
        missing.append("rootfs central C linker flag")
    if dockerfile.count(
        'RUSTFLAGS="--remap-path-prefix=/work/runtime=. -C link-arg=--build-id=sha1"'
    ) != 5:
        missing.append("all five runtime musl cargo invocations")
    if missing:
        raise AssertionError("missing explicit build-id policy: " + ", ".join(missing))


dockerfile = (ROOT / "build/Dockerfile.pf").read_text()
rootfs = (ROOT / "scripts/build-rootfs.sh").read_text()
finalizer = (ROOT / "scripts/finalize-elf-debuginfo.sh").read_text()

verify(dockerfile, rootfs, finalizer)

# Negative control in the same invocation: removing one producer's explicit
# policy must make the verifier fail.
broken = dockerfile.replace(
    'LDFLAGS="-Wl,--build-id=sha1" \\\n+OUT=/work/out bash /work/src/build/build-libsdl3.sh',
    'OUT=/work/out bash /work/src/build/build-libsdl3.sh',
    1,
)
try:
    verify(broken, rootfs, finalizer)
except AssertionError as exc:
    assert "SDL CMake stage" in str(exc)
else:
    raise AssertionError("negative control: missing SDL build-id policy was accepted")

print("test-owned-elf-buildid-producers=ALL PASS")
