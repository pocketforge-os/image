#!/usr/bin/env python3
"""Guard load-bearing gpu-um-toolchain lines against the pinned upstream recipe.

THREAT MODEL (bd tsp-0df0a59562b2cb408557)
==========================================

Trust boundary:
  This guard ensures Dockerfile.pf's gpu-um-toolchain stage matches the checked-in
  fixture (approved upstream recipe from gpu-um-tsp at a pinned commit). Both files
  are tracked in git and can be modified via PR on shared/public CI runners.

Attacker-controlled inputs:
  - Dockerfile.pf content (via PR from fork/branch)
  - Fixture file content (via PR)
  - File paths (symlinks at fixture/dockerfile paths via PR)
  - Multiple comment lines matching the SHA extraction regex

Deployment surface:
  Shared/public CI runners consume externally selected gpu-um-tsp source revisions
  (via platform.lock or build args). The test runs on the PR's working tree.

Already rejected by existing guard:
  - Stale SHA in comments (vs pinned SHA) — verified by test-dockerfile-pf-transforms.sh
  - Stage content drift (base image, sed expression, ENV, arm64 stanza, apt packages)
  - Missing installed-output evidence export
  - Missing toolchain stage (stage() raises ValueError)

Evidenced gaps (now tested below):
  1. Decoy SHA comment: re.search returns first match. Attacker adds fake comment
     with correct SHA before the real one, then modifies the real comment. The test
     checks the decoy (correct) and ignores the real (modified).
  2. SHA comment vs build arg: Test validates the comment but not PF_GPU_UM_SHA
     build arg. Attacker can change the build arg while leaving comment unchanged.
  3. Symlink at fixture/dockerfile path: read_text() follows symlinks. Attacker
     can replace fixture with symlink to attacker-controlled content.
"""

from __future__ import annotations

import argparse
import itertools
import os
import re
import sys
import tempfile
from pathlib import Path


ARM64_DESTINATION = "/etc/apt/sources.list.d/ubuntu-arm64.sources"
PINNED_GPU_UM_SHA = "6d641070c7725389ab3e3f9db94d20109f5a0962"

# CVE-2026-109518 (bd tsp-hqm1p.143): reviewed downstream deviations from the pinned
# upstream recipe, kept until gpu-um-tsp carries them. apt.llvm.org and ports.ubuntu.com
# follow the stage's apt transport: ${pf_apt_scheme} is http to the NAS apt-cacher-ng while
# http_proxy is set and https otherwise (the same selection as pf-build-base). The live
# stage must carry exactly these, nothing looser; tests/test-apt-cache-transport.py
# executes the selection in both modes.
LLVM_HTTPS_REWRITE = "s#http://apt.llvm.org/#${pf_apt_scheme}://apt.llvm.org/#"
REVIEWED_HTTPS_STANZA = {
    "URIs: http://ports.ubuntu.com/ubuntu-ports": "URIs: ${pf_apt_scheme}://ports.ubuntu.com/ubuntu-ports",
}

INSTALLED_REPRO_CONTRACT = {
    "first-pass install": (
        'DESTDIR=/instroot-first SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" '
        'meson install -C "${build_dir}" --no-rebuild --skip-subprojects'
    ),
    "second-pass install": (
        'DESTDIR=/instroot SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" '
        'meson install -C "${build_dir}" --no-rebuild --skip-subprojects'
    ),
    "first installed Gallium capture": (
        "cp /instroot-first/usr/local/lib/libgallium_dri.so "
        "/first-installed-gallium.so"
    ),
    "first installed Vulkan capture": (
        "cp /instroot-first/usr/local/lib/libvulkan_powervr_mesa.so "
        "/first-installed-vulkan.so"
    ),
    "installed Vulkan comparison": (
        "cmp /first-installed-vulkan.so "
        "/instroot/usr/local/lib/libvulkan_powervr_mesa.so"
    ),
    "installed Gallium comparison": (
        "cmp /first-installed-gallium.so "
        "/instroot/usr/local/lib/libgallium_dri.so"
    ),
    "installed output digest": (
        "sha256sum /first-installed-vulkan.so "
        "/instroot/usr/local/lib/libvulkan_powervr_mesa.so "
        "/first-installed-gallium.so "
        "/instroot/usr/local/lib/libgallium_dri.so "
        ">/src/installed-cross-build-sha256.txt"
    ),
    "installed output evidence export": (
        "COPY --from=gpu-um-build /src/installed-cross-build-sha256.txt "
        "/installed-cross-build-sha256.txt"
    ),
}


def stage(text: str, alias: str) -> str:
    match = re.search(
        rf"(?ms)^FROM [^\n]+ AS {re.escape(alias)}\n(.*?)(?=^FROM |\Z)", text
    )
    if not match:
        raise ValueError(f"stage {alias!r} not found")
    return match.group(0)


def base_image(text: str) -> str:
    match = re.search(r"(?m)^FROM\s+(\S+)\s+AS\s+\S+", text)
    if not match:
        raise ValueError("base image line not found")
    return match.group(1)


def logical_lines(text: str) -> list[str]:
    lines: list[str] = []
    current = ""
    for raw in text.splitlines():
        stripped = raw.strip()
        if not current and (not stripped or stripped.startswith("#")):
            continue
        current += (" " if current else "") + stripped.removesuffix("\\").rstrip()
        if not stripped.endswith("\\"):
            lines.append(current)
            current = ""
    if current:
        lines.append(current)
    return lines


def mesa_env(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in logical_lines(text):
        if not line.startswith("ENV "):
            continue
        for assignment in line.removeprefix("ENV ").split():
            if assignment.startswith("MESA_"):
                name, separator, value = assignment.partition("=")
                if not separator:
                    raise ValueError(f"unsupported ENV MESA_* form: {line}")
                values[name] = value
    return values


def sed_strip(text: str) -> str:
    matches = [
        match
        for match in re.findall(
            r"sed -i\s+(['\"])(.*?)\1\s+/usr/local/src/install-mesa-buildenv\.sh", text
        )
        if match[1] != LLVM_HTTPS_REWRITE
    ]
    if len(matches) != 1:
        raise ValueError(f"expected one Mesa buildenv sed strip, found {len(matches)}")
    return matches[0][1]


def arm64_stanza(text: str) -> list[str]:
    blocks = [line for line in logical_lines(text) if f">{ARM64_DESTINATION}" in line]
    if len(blocks) != 1:
        raise ValueError(f"expected one arm64 sources stanza, found {len(blocks)}")
    values = [
        single or double
        for single, double in re.findall(r"'([^']+)'|\"([^\"]+)\"", blocks[0])
    ]
    try:
        first = values.index("Types: deb")
        last = next(i for i in range(first, len(values)) if values[i].startswith("Signed-By:"))
    except (ValueError, StopIteration) as error:
        raise ValueError("arm64 sources stanza boundaries not found") from error
    return values[first : last + 1]


def installed_packages(text: str) -> list[str]:
    match = re.search(
        r"apt-get install -y --no-install-recommends\s+"
        r"(.*?)\n\s*(?:&&\s+)?dpkg-query -W",
        text,
        re.DOTALL,
    )
    if not match:
        raise ValueError("toolchain apt package list not found")
    return sorted(
        token
        for token in match.group(1).replace("\\\n", " ").split()
        if token not in {"&&", "\\"}
    )


def fixture_source_sha(text: str) -> str:
    match = re.search(
        r"(?m)^# Vendored from gpu-um-tsp docker/Dockerfile\.ge8300-mesa-cross "
        r"at ([0-9a-f]{8}|[0-9a-f]{40})\.$",
        text,
    )
    if not match:
        raise ValueError("gpu-um-tsp fixture source identity not found")
    return match.group(1)


def dockerfile_source_sha(text: str) -> str:
    match = re.search(
        r"(?m)^# docker/Dockerfile\.ge8300-mesa-cross "
        r"at ([0-9a-f]{8}|[0-9a-f]{40})\. Do NOT add$",
        text,
    )
    if not match:
        raise ValueError("gpu-um-tsp live source identity not found")
    return match.group(1)


def count_dockerfile_source_sha_matches(text: str) -> int:
    """Count how many lines match the live SHA comment pattern (decoy detection)."""
    return len(
        re.findall(
            r"(?m)^# docker/Dockerfile\.ge8300-mesa-cross "
            r"at (?:[0-9a-f]{8}|[0-9a-f]{40})\. Do NOT add$",
            text,
        )
    )


def count_fixture_source_sha_matches(text: str) -> int:
    """Count how many lines match the fixture SHA comment pattern (decoy detection)."""
    return len(
        re.findall(
            r"(?m)^# Vendored from gpu-um-tsp docker/Dockerfile\.ge8300-mesa-cross "
            r"at (?:[0-9a-f]{8}|[0-9a-f]{40})\.$",
            text,
        )
    )


def extract_build_arg_sha(text: str) -> str | None:
    """Extract PF_GPU_UM_SHA default value from the Dockerfile, if present.
    
    Looks for: ARG PF_GPU_UM_SHA=<value>
    Returns None if no default is set (just 'ARG PF_GPU_UM_SHA').
    """
    match = re.search(r"(?m)^ARG PF_GPU_UM_SHA=([0-9a-f]+)$", text)
    return match.group(1) if match else None


def validate_path_is_regular_file(path: Path, label: str) -> None:
    """Reject symlinks, FIFOs, devices, and other non-regular files.
    
    On shared CI, a PR could replace the fixture or dockerfile with a symlink
    pointing outside the repo. read_text() follows symlinks, which would bypass
    the guard. This validation ensures both paths are regular files in the repo.
    """
    if not path.exists():
        raise ValueError(f"{label} does not exist: {path}")
    if path.is_symlink():
        raise ValueError(f"{label} is a symlink (rejected for hermetic validation): {path}")
    if not path.is_file():
        raise ValueError(f"{label} is not a regular file: {path}")


def fail(name: str, expected: object, actual: object) -> None:
    print(f"FAIL: {name}: expected {expected!r}, got {actual!r}", file=sys.stderr)


def normalized_commands(text: str) -> str:
    return " ".join(text.replace("\\\n", " ").split())


def self_test() -> int:
    """Hermetic RED→GREEN self-test: prove the guard rejects hostile inputs.
    
    Creates temp files with known-bad content, runs the guard against them,
    and verifies the guard catches each attack. Returns 0 if all attacks are
    rejected, 1 if any attack passes (false trust).
    """
    root = Path(__file__).resolve().parents[2]
    real_dockerfile = root / "build/Dockerfile.pf"
    real_fixture = root / "build/tests/fixtures/gpu-um-toolchain-6d641070.Dockerfile"
    
    failed = False
    
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        
        # --- Gap 1: Decoy SHA comment (live Dockerfile) ---
        # Attack: prepend a fake comment with the correct SHA before the real one,
        # then modify the real comment to a different SHA. re.search returns the
        # first match (the decoy), so the test would pass if we only checked the SHA.
        decoy_dockerfile = tmp / "decoy.Dockerfile"
        dockerfile_text = real_dockerfile.read_text()
        decoy_text = (
            f"# docker/Dockerfile.ge8300-mesa-cross at {PINNED_GPU_UM_SHA}. Do NOT add\n"
            + dockerfile_text.replace(
                f"# docker/Dockerfile.ge8300-mesa-cross at {PINNED_GPU_UM_SHA}. Do NOT add",
                "# docker/Dockerfile.ge8300-mesa-cross at deadbeefdeadbeefdeadbeefdeadbeefdeadbeef. Do NOT add",
            )
        )
        decoy_dockerfile.write_text(decoy_text)
        try:
            validate_path_is_regular_file(decoy_dockerfile, "decoy dockerfile")
            text = decoy_dockerfile.read_text()
            count = count_dockerfile_source_sha_matches(text)
            if count != 1:
                print(f"SELF-TEST PASS: decoy SHA comment detected ({count} matches, expected 1)")
            else:
                print("SELF-TEST FAIL: decoy SHA comment not detected (1 match — false trust)")
                failed = True
        except ValueError as error:
            print(f"SELF-TEST FAIL: decoy dockerfile rejected: {error}")
            failed = True
        
        # --- Gap 1b: Decoy SHA comment (fixture) ---
        decoy_fixture = tmp / "decoy-fixture.Dockerfile"
        fixture_text = real_fixture.read_text()
        decoy_fixture_text = (
            f"# Vendored from gpu-um-tsp docker/Dockerfile.ge8300-mesa-cross at {PINNED_GPU_UM_SHA}.\n"
            + fixture_text
        )
        decoy_fixture.write_text(decoy_fixture_text)
        try:
            validate_path_is_regular_file(decoy_fixture, "decoy fixture")
            text = decoy_fixture.read_text()
            count = count_fixture_source_sha_matches(text)
            if count != 1:
                print(f"SELF-TEST PASS: decoy fixture SHA comment detected ({count} matches, expected 1)")
            else:
                print("SELF-TEST FAIL: decoy fixture SHA comment not detected (1 match — false trust)")
                failed = True
        except ValueError as error:
            print(f"SELF-TEST FAIL: decoy fixture rejected: {error}")
            failed = True
        
        # --- Gap 2: SHA comment vs build arg mismatch ---
        # Attack: leave the comment at the pinned SHA, but set a different default
        # in the ARG line. The test validates the comment but not the build arg.
        # This is a documentation-vs-execution gap. We detect it by extracting both.
        mismatch_dockerfile = tmp / "mismatch.Dockerfile"
        mismatch_text = dockerfile_text.replace(
            "ARG PF_GPU_UM_SHA\n",
            f"ARG PF_GPU_UM_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n",
            1,  # Replace only the first occurrence
        )
        mismatch_dockerfile.write_text(mismatch_text)
        try:
            text = mismatch_dockerfile.read_text()
            comment_sha = dockerfile_source_sha(text)
            build_arg_sha = extract_build_arg_sha(text)
            if build_arg_sha is not None and build_arg_sha != comment_sha:
                print(f"SELF-TEST PASS: build arg SHA mismatch detected (comment={comment_sha[:12]}..., arg={build_arg_sha[:12]}...)")
            elif build_arg_sha is None:
                print("SELF-TEST PASS: no build arg default (accepted — runtime validation)")
            else:
                print("SELF-TEST FAIL: build arg SHA mismatch not detected (false trust)")
                failed = True
        except ValueError as error:
            print(f"SELF-TEST FAIL: mismatch dockerfile rejected: {error}")
            failed = True
        
        # --- Gap 3: Symlink at fixture/dockerfile path ---
        # Attack: replace the fixture with a symlink to attacker-controlled content.
        # read_text() follows symlinks, bypassing the guard.
        symlink_fixture = tmp / "symlink-fixture.Dockerfile"
        attacker_content = tmp / "attacker.Dockerfile"
        attacker_content.write_text("# Malicious content\n")
        symlink_fixture.symlink_to(attacker_content)
        try:
            validate_path_is_regular_file(symlink_fixture, "symlink fixture")
            print("SELF-TEST FAIL: symlink fixture not rejected (false trust)")
            failed = True
        except ValueError as error:
            print(f"SELF-TEST PASS: symlink fixture rejected: {error}")
        
        # --- Gap 3b: Non-regular file (FIFO) ---
        # Attack: replace the fixture with a FIFO. read_text() would block.
        fifo_fixture = tmp / "fifo-fixture.Dockerfile"
        try:
            os.mkfifo(fifo_fixture)
            try:
                validate_path_is_regular_file(fifo_fixture, "FIFO fixture")
                print("SELF-TEST FAIL: FIFO fixture not rejected (false trust)")
                failed = True
            except ValueError as error:
                print(f"SELF-TEST PASS: FIFO fixture rejected: {error}")
        except OSError as error:
            print(f"SELF-TEST SKIP: could not create FIFO: {error}")
    
    if failed:
        print("SELF-TEST: some attacks passed (false trust)")
        return 1
    print("SELF-TEST: all attacks rejected")
    return 0


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser()
    parser.add_argument("--dockerfile", type=Path, default=root / "build/Dockerfile.pf")
    parser.add_argument(
        "--fixture",
        type=Path,
        default=root / "build/tests/fixtures/gpu-um-toolchain-6d641070.Dockerfile",
    )
    parser.add_argument("--source-sha", default=PINNED_GPU_UM_SHA)
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run hermetic RED→GREEN self-test proving the guard rejects hostile inputs",
    )
    args = parser.parse_args()
    
    if args.self_test:
        return self_test()

    try:
        # Validate paths are regular files (reject symlinks, FIFOs, devices)
        validate_path_is_regular_file(args.dockerfile, "dockerfile")
        validate_path_is_regular_file(args.fixture, "fixture")
        
        dockerfile_text = args.dockerfile.read_text()
        
        # Detect decoy SHA comments (multiple matches indicate an attack)
        live_sha_count = count_dockerfile_source_sha_matches(dockerfile_text)
        if live_sha_count != 1:
            raise ValueError(
                f"expected exactly one live SHA comment, found {live_sha_count} "
                "(decoy comment attack detected)"
            )
        
        actual = stage(dockerfile_text, "gpu-um-toolchain")
        fixture_text = args.fixture.read_text()
        
        fixture_sha_count = count_fixture_source_sha_matches(fixture_text)
        if fixture_sha_count != 1:
            raise ValueError(
                f"expected exactly one fixture SHA comment, found {fixture_sha_count} "
                "(decoy comment attack detected)"
            )
        
        expected = stage(fixture_text, "toolchain")
        
        # Detect build arg SHA mismatch (documentation vs execution gap)
        build_arg_sha = extract_build_arg_sha(dockerfile_text)
        if build_arg_sha is not None:
            comment_sha = dockerfile_source_sha(dockerfile_text)
            if build_arg_sha != comment_sha:
                raise ValueError(
                    f"build arg SHA mismatch: comment says {comment_sha}, "
                    f"but ARG PF_GPU_UM_SHA defaults to {build_arg_sha}"
                )
        
        checks = [
            ("live source pin", args.source_sha, dockerfile_source_sha(dockerfile_text)),
            ("fixture source pin", args.source_sha, fixture_source_sha(fixture_text)),
            ("base image", base_image(expected), base_image(actual)),
            ("sed strip expression", sed_strip(expected), sed_strip(actual)),
            (
                "apt.llvm.org https rewrite",
                1,
                actual.count(f'sed -i "{LLVM_HTTPS_REWRITE}" /usr/local/src/install-mesa-buildenv.sh'),
            ),
            (
                "upstream toolchain apt packages missing",
                [],
                sorted(set(installed_packages(expected)) - set(installed_packages(actual))),
            ),
        ]
        expected_env = mesa_env(expected)
        actual_env = mesa_env(actual)
        normalized_dockerfile = normalized_commands(dockerfile_text)
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1

    failed = False
    for name, wanted, got in checks:
        if wanted != got:
            fail(name, wanted, got)
            failed = True

    for name in sorted(expected_env.keys() | actual_env.keys()):
        wanted = expected_env.get(name, "<missing>")
        got = actual_env.get(name, "<missing>")
        if wanted != got:
            fail(f"ENV {name}", wanted, got)
            failed = True

    for name, command in INSTALLED_REPRO_CONTRACT.items():
        if command not in normalized_dockerfile:
            fail(name, "present", "missing")
            failed = True

    expected_stanza = [REVIEWED_HTTPS_STANZA.get(line, line) for line in arm64_stanza(expected)]
    actual_stanza = arm64_stanza(actual)
    for line_number, (wanted, got) in enumerate(
        itertools.zip_longest(expected_stanza, actual_stanza, fillvalue="<missing>"), 1
    ):
        if wanted != got:
            fail(f"arm64 stanza line {line_number}", wanted, got)
            failed = True

    if failed:
        return 1
    print(
        "PASS: gpu-um-toolchain matches pinned gpu-um-tsp "
        f"{args.source_sha} live annotation and load-bearing lines"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
