#!/usr/bin/env python3
"""Hermetic policy test for every image-owned ELF producer class."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def verify(dockerfile: str, rootfs: str, finalizer: str, steamlink_builder: str) -> None:
    required = {
        "PowerVR firmware closed-vendor directory": (
            finalizer,
            '"${ROOTFS}/usr/lib/firmware/powervr"',
        ),
        "SDL CMake stage": (
            dockerfile,
            'LDFLAGS="-Wl,--build-id=sha1" \\' + "\n"
            'OUT=/work/out bash /work/src/build/build-libsdl3.sh',
        ),
        "wpa Make stage": (
            dockerfile,
            'LDFLAGS="-Wl,--build-id=sha1 -B/usr/lib/aarch64-linux-gnu -L/usr/lib/aarch64-linux-gnu"',
        ),
        "hwprobe Make stage": (
            dockerfile,
            'PF_STATIC=/work/runtime-sdk/lib/libpocketforge.a \\' + "\n"
            '  LDFLAGS="-static -Wl,--build-id=sha1" \\' + "\n"
            '  OUT_DIR=/out/bin',
        ),
        "hwprobe artifact build-id assertion": (
            dockerfile,
            "aarch64-none-linux-gnu-readelf -n /out/bin/pf-hwprobe | grep -q 'Build ID:'",
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
            'RUSTFLAGS="-C link-arg=--build-id=sha1" \\' + "\n"
            'cargo build --offline --locked --release --target aarch64-unknown-linux-musl',
        ),
        "launcher musl Rust link": (
            dockerfile,
            'RUSTFLAGS="--remap-path-prefix=/work/launcher=. -C link-arg=--build-id=sha1"',
        ),
        "Poolsuite GNU Rust link": (
            dockerfile,
            'RUSTFLAGS="-C link-arg=-Wl,--build-id=sha1" ./ci/device-build.sh --offline',
        ),
        "Steam Link FFmpeg 5.9 shared-library links": (
            steamlink_builder,
            "--extra-ldflags='-Wl,--build-id=sha1 -B/usr/lib/aarch64-linux-gnu "
            "-L/usr/lib/aarch64-linux-gnu'",
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
steamlink_builder = (
    ROOT / "build/platform-runtimes/steamlink-ffmpeg59/v1/build.sh"
).read_text()

verify(dockerfile, rootfs, finalizer, steamlink_builder)

# Negative control in the same invocation: removing one producer's explicit
# policy must make the verifier fail.
broken = dockerfile.replace(
    'LDFLAGS="-Wl,--build-id=sha1" \\' + "\n"
    'OUT=/work/out bash /work/src/build/build-libsdl3.sh',
    'OUT=/work/out bash /work/src/build/build-libsdl3.sh',
    1,
)
try:
    verify(broken, rootfs, finalizer, steamlink_builder)
except AssertionError as exc:
    assert "SDL CMake stage" in str(exc)
else:
    raise AssertionError("negative control: missing SDL build-id policy was accepted")

# Command-line make variables replace Makefile `?=` defaults. The hwprobe
# producer must therefore preserve its static-link invariant while adding the
# build-id flag; a build-id-only override is an unsafe negative control.
unsafe_hwprobe = dockerfile.replace(
    'LDFLAGS="-static -Wl,--build-id=sha1"',
    'LDFLAGS="-Wl,--build-id=sha1"',
    1,
)
try:
    verify(unsafe_hwprobe, rootfs, finalizer, steamlink_builder)
except AssertionError as exc:
    assert "hwprobe Make stage" in str(exc)
else:
    raise AssertionError("negative control: hwprobe static-link flags were replaced")

steamlink_without_build_id = steamlink_builder.replace(
    "-Wl,--build-id=sha1 ",
    "",
    1,
)
try:
    verify(dockerfile, rootfs, finalizer, steamlink_without_build_id)
except AssertionError as exc:
    assert "Steam Link FFmpeg 5.9 shared-library links" in str(exc)
else:
    raise AssertionError("negative control: Steam Link FFmpeg build-id policy was accepted")

print("test-owned-elf-buildid-producers=ALL PASS")
