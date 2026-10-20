#!/usr/bin/env python3
"""Check the Zink probe uses an offscreen EGL path for render-only Venus.

The A133 QEMU device deliberately has no scanout and disables KMS.  A GBM
window surface is therefore the wrong contract for this probe: it can fail at
gbm_create_device before EGL chooses the pinned Venus-backed Zink device.
This is a source contract test, so it remains hermetic and catches the
regression before an image is published.
"""

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tools/open-gpu-probe.c"
FUNCTION = "static int probe_gles32_zink_readback(void)"


def function_text(source: str) -> str:
    start = source.index(FUNCTION)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError("Zink probe function has unbalanced braces")


def check_contract(source: str) -> None:
    body = function_text(source)
    required = (
        "EGL_PLATFORM_SURFACELESS_MESA",
        "EGL_PBUFFER_BIT",
        "eglCreatePbufferSurface",
    )
    forbidden = (
        "gbm_create_device",
        "gbm_surface_create",
        "eglCreateWindowSurface",
        "EGL_PLATFORM_GBM_KHR",
    )
    missing = [token for token in required if token not in body]
    present = [token for token in forbidden if token in body]
    if missing or present:
        raise AssertionError(
            "render-only Zink EGL contract failed: "
            f"missing={missing} forbidden={present}"
        )


def main() -> int:
    source = SOURCE.read_text(encoding="utf-8")
    check_contract(source)

    # The old GBM/window implementation is an explicit negative control.  It
    # must remain rejected if this test is later weakened accidentally.
    old_source = source.replace(
        "EGL_PLATFORM_SURFACELESS_MESA", "EGL_PLATFORM_GBM_KHR"
    ).replace("EGL_PBUFFER_BIT", "EGL_WINDOW_BIT").replace(
        "eglCreatePbufferSurface", "eglCreateWindowSurface"
    )
    try:
        check_contract(old_source)
    except AssertionError:
        pass
    else:
        raise AssertionError("GBM/window negative control was accepted")

    print("open-gpu-probe-render-only=PASS positive=surfaceless-pbuffer negative=gbm-window")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, ValueError) as exc:
        print(f"open-gpu-probe-render-only=FAIL {exc}", file=sys.stderr)
        raise SystemExit(1)
