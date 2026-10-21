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


def block_text(source: str, marker: str) -> str:
    start = source.index(marker)
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


def function_text(source: str) -> str:
    return block_text(source, FUNCTION)


def check_contract(source: str) -> None:
    body = function_text(source)
    required = (
        "EGL_PLATFORM_SURFACELESS_MESA",
        "EGL_PBUFFER_BIT",
        "eglCreatePbufferSurface",
        'setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1)',
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
    if "#define EGL_CONTEXT_MAJOR_VERSION_KHR 0x3098" not in source:
        raise AssertionError("EGL_CONTEXT_MAJOR_VERSION_KHR fallback is incorrect")

    diagnostics = (
        "print_venus_vulkan_features(icd);",
        "print_egl_config_diagnostics(display, config);",
        "print_zink_gles_version(display, config, surface_attributes);",
    )
    missing_diagnostics = [token for token in diagnostics if token not in body]
    if missing_diagnostics:
        raise AssertionError(
            "GLES failure diagnostics are not called by the probe: "
            f"missing={missing_diagnostics}"
        )
    failure_branch = block_text(body, "if (context == EGL_NO_CONTEXT)")
    if "print_zink_gles_version(display, config, surface_attributes);" not in failure_branch:
        raise AssertionError("ES 3.2 failure branch omits the fallback Zink diagnostic")
    for token in (
        "venus_vulkan_features=",
        "egl_config=",
        "zink_gles_version=",
        "EGL_CONFIG_ID",
        "EGL_RENDERABLE_TYPE",
        "EGL_SURFACE_TYPE",
        "EGL_CONTEXT_MINOR_VERSION_KHR, 1",
    ):
        if token not in source:
            raise AssertionError(f"GLES diagnostic implementation omits {token}")


def main() -> int:
    source = SOURCE.read_text(encoding="utf-8")
    check_contract(source)

    # The old GBM/window implementation is an explicit negative control.  It
    # must remain rejected if this test is later weakened accidentally.
    old_source = source.replace(
        "EGL_PLATFORM_SURFACELESS_MESA", "EGL_PLATFORM_GBM_KHR"
    ).replace("EGL_PBUFFER_BIT", "EGL_WINDOW_BIT").replace(
        "eglCreatePbufferSurface", "eglCreateWindowSurface"
    ).replace('setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);', "")
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
