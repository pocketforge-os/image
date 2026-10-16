#!/usr/bin/env python3
"""Hermetic self-test for the laptop input harness (tests/input-harness).

No docker, no network, no device: this test exercises the transcript
validator and the run-report evaluator against generated fixtures, with a
positive control (a healthy run directory reports PASS) and negative
controls (every mutated directory reports FAIL with the exact reason=) in
the same invocation. It also audits the committed harness assets for the
container-safety rules (no --privileged, no /sbin/init, no docker.sock,
no rm -rf) with an injected-violation negative control for the auditor.

Registered in .github/workflows/hermetic-tests.yml.
"""

from __future__ import annotations

import datetime
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARNESS = os.path.join(REPO, "tests", "input-harness")


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validate_transcript = load_module(
    "pf_validate_transcript", os.path.join(HARNESS, "validate", "validate_transcript.py")
)
report_mod = load_module("pf_report", os.path.join(HARNESS, "report", "report.py"))
make_fixtures = load_module(
    "pf_make_fixtures", os.path.join(HARNESS, "selftest", "make_fixtures.py")
)

FAILURES = []


def require(condition, message):
    if not condition:
        FAILURES.append(message)
        print(f"FAIL: {message}")


def run_report(out_dir):
    """Run report.py as a subprocess; return (rc, combined output)."""
    proc = subprocess.run(
        [sys.executable, "-B", os.path.join(HARNESS, "report", "report.py"), out_dir],
        capture_output=True,
        text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def section_validator_and_report(work):
    fixtures = os.path.join(work, "fixtures")
    os.makedirs(fixtures)
    good = make_fixtures.build_good(os.path.join(fixtures, "good"))
    negatives = make_fixtures.build_negatives(good)
    validator_cases = make_fixtures.build_validator_negatives(fixtures)

    # Positive control: the validator accepts every generated transcript.
    for name in sorted(os.listdir(os.path.join(good, "transcripts"))):
        if name == "broken-client.jsonl":
            continue
        problems = validate_transcript.validate_file(
            os.path.join(good, "transcripts", name)
        )
        require(problems == [], f"validator rejected good fixture {name}: {problems}")
    session_problems = validate_transcript.validate_file(
        os.path.join(good, "session.jsonl"), expected_client="session"
    )
    require(session_problems == [], f"validator rejected good session fixture: {session_problems}")

    # Positive control: a healthy run directory reports PASS, exit 0, and
    # the final line carries the transcript paths.
    rc, out = run_report(good)
    require(rc == 0, f"report.py failed on the good fixture (rc={rc}):\n{out}")
    require(
        "PASS: input-harness" in out,
        f"report.py did not print a final PASS line on the good fixture:\n{out}",
    )
    for client in ("gtk4-text", "qt6-text", "sdl3-text", "sdl2-game", "x11-gtk", "xim-only", "no-im"):
        require(
            f"PASS: {client} " in out,
            f"report.py missing PASS line for {client}:\n{out}",
        )
    require(
        "negative_control=confirmed" in out,
        f"report.py did not confirm the broken-client negative control:\n{out}",
    )
    require(
        "PASS: wpe-view" not in out and "SKIP: wpe-view" in out,
        f"report.py should SKIP the optional wpe-view client:\n{out}",
    )
    require(
        os.path.join(good, "transcripts", "gtk4-text.jsonl") in out,
        f"final PASS line must carry transcript paths:\n{out}",
    )

    # Negative controls: every mutated directory fails with its reason.
    for name, (path, reason) in sorted(negatives.items()):
        rc, out = run_report(path)
        require(rc != 0, f"report.py accepted negative fixture {name}")
        require(
            f"reason={reason}" in out,
            f"report.py did not report reason={reason} for {name}:\n{out}",
        )

    # Negative controls at the validator level.
    for path, reason in validator_cases:
        problems = validate_transcript.validate_file(path, expected_client="case")
        require(
            any(problem.reason == reason for problem in problems),
            f"validator missed {reason} in {os.path.basename(path)}: got {[str(p) for p in problems]}",
        )
    # And the validator's negative control has a positive counterpart:
    # the same builder output with the mutation removed validates clean.
    b = make_fixtures.Builder("case")
    b.event("start", pid=1, argv=["case"], backend="wayland", display="gamescope-0")
    b.event("enter", serial=1)
    b.event("stop", rc=0)
    clean = os.path.join(work, "clean-case.jsonl")
    b.write(clean)
    require(
        validate_transcript.validate_file(clean) == [],
        "validator rejected a clean minimal transcript",
    )


FORBIDDEN_PATTERNS = (
    "--privileged",
    "/sbin/init",
    "docker.sock",
    "rm -rf",
    "--cap-add=ALL",
    "--cap-add SYS_ADMIN",
)

RUN_DEVICE_EXPOSURE_PATTERNS = (
    ("device_flag", re.compile(r"(?:^|\s)--device(?:=|\s)", re.MULTILINE)),
    ("device_cgroup_rule", re.compile(r"--device-cgroup-rule")),
    ("uinput_path", re.compile(r"/dev/uinput(?:\s|$)")),
    (
        "input_bind",
        re.compile(
            r"(?:-v|--volume)\s+[^\n]*?/dev/input(?:[/:\s]|$)"
            r"|--mount[^\n]*(?:source|src)=/dev/input(?:[,/\s]|$)"
        ),
    ),
)


def audit_file(path):
    """Return the forbidden patterns found in a harness asset."""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    return [pattern for pattern in FORBIDDEN_PATTERNS if pattern in text]


def audit_run_device_exposure(text):
    """Return host-device grants forbidden in the default harness runner."""
    return [name for name, pattern in RUN_DEVICE_EXPOSURE_PATTERNS if pattern.search(text)]


def section_asset_audit(work):
    required_assets = [
        "README.md",
        "Containerfile",
        "pins.env",
        "run.sh",
        "run-guest.sh",
        "build-guest-payload.sh",
        "guest-payload.pins",
        "negative-control.sh",
        "report/report.py",
        "report/layout_scenario.py",
        "validate/validate_transcript.py",
        "selftest/make_fixtures.py",
        "session/entry.sh",
        "session/driver.py",
        "session/mangoapp",
        "session/udev-shim.sh",
        "tools/fake-input.c",
        "tools/pf_uinput_domain_guard.h",
        "tools/require-apt-proxy.sh",
        "tools/normalize-guest-payload-root.sh",
        "tools/regenerate-guest-ld-cache.sh",
        "tools/inventory-guest-payload.py",
        "tools/private-input.c",
        "tools/pf-shot.c",
        "tools/provision-wayland-protocols.sh",
        "tools/require-empty-output.sh",
        "tools/text-glyphs.h",
        "tools/transcript.c",
        "tools/transcript.h",
        "clients/gtk4-text.c",
        "clients/qt6-text.cpp",
        "clients/sdl3-text.c",
        "clients/sdl2-game.c",
        "clients/x11-gtk.c",
        "clients/xim-only.c",
        "clients/no-im.c",
        "clients/broken-client.c",
        "schema/transcript-schema.md",
        "selftest/fake_input_guard_test.c",
        "selftest/test-fake-input-guard.sh",
        "selftest/test-negative-control-wrapper.sh",
        "selftest/test-layout-scenario-shell.sh",
        "selftest/test-guest-agent.py",
        "selftest/test-guest-kernel-cleanup.py",
        "selftest/test-apt-proxy-guard.sh",
        "selftest/test-payload-reproducibility.sh",
        "guest/agent.py",
        "guest/build-tools.sh",
        "session/entry-guest.sh",
        "selftest/uinput-domain-v1.SOURCE",
        "selftest/uinput-domain-v1.tsv",
    ]
    for rel in required_assets:
        require(
            os.path.exists(os.path.join(HARNESS, rel)),
            f"missing harness asset tests/input-harness/{rel}",
        )

    # Executable assets must not carry forbidden container patterns. The
    # README documents the rules in prose (naming the forbidden flags), so
    # it is exempt from the string audit but must state the blast radius.
    for rel in required_assets:
        if rel == "README.md" or not os.path.exists(os.path.join(HARNESS, rel)):
            continue
        hits = audit_file(os.path.join(HARNESS, rel))
        require(not hits, f"forbidden pattern(s) {hits} in tests/input-harness/{rel}")

    with open(os.path.join(REPO, "scripts", "build-rootfs.sh"), "r", encoding="utf-8") as handle:
        rootfs_build = handle.read()
    require(
        'tests/input-harness/guest/agent.py' not in rootfs_build
        and 'tests/input-harness/run-guest.sh' not in rootfs_build
        and 'pf-input-harness-agent.service' not in rootfs_build,
        "product rootfs unexpectedly packages the test-only harness",
    )
    payload_builder_path = os.path.join(HARNESS, "build-guest-payload.sh")
    with open(payload_builder_path, "r", encoding="utf-8") as handle:
        payload_builder = handle.read()
    with open(os.path.join(HARNESS, "Containerfile.guest-payload"), "r", encoding="utf-8") as handle:
        payload_container = handle.read()
    payload_pins = {}
    with open(os.path.join(HARNESS, "guest-payload.pins"), "r", encoding="utf-8") as handle:
        for line in handle:
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.rstrip("\n").split("=", 1)
                payload_pins[key] = value
    snapshot_epoch = int(
        datetime.datetime.strptime(
            payload_pins.get("SNAPSHOT_DATE", ""), "%Y%m%dT%H%M%SZ"
        )
        .replace(tzinfo=datetime.timezone.utc)
        .timestamp()
    )
    require(
        int(payload_pins.get("SOURCE_DATE_EPOCH", "0")) == snapshot_epoch
        and snapshot_epoch > 0,
        "payload SOURCE_DATE_EPOCH is not the fixed, nonzero snapshot instant",
    )
    with open(os.path.join(HARNESS, "guest", "build-tools.sh"), "r", encoding="utf-8") as handle:
        payload_build_tools = handle.read()
    require(
        f"export SOURCE_DATE_EPOCH={snapshot_epoch}" in payload_build_tools
        and f'test "${{SOURCE_DATE_EPOCH}}" = {snapshot_epoch}' in payload_container,
        "payload producer phases do not share the snapshot epoch",
    )
    require(
        "mmdebstrap" in payload_container
        and "snapshot.debian.org" in payload_container
        and ". /work/guest-payload.pins" in payload_container
        and "export SOURCE_DATE_EPOCH" in payload_container
        and payload_container.count(". /usr/local/libexec/require-apt-proxy.sh") == 3
        and '--aptopt=Acquire::http::Proxy' in payload_container
        and "git clone" not in payload_container
        and "mksquashfs" in payload_builder
        and "-all-time" in payload_builder
        and "contains_product_gamescope" in payload_builder
        and "gamescope must not be included" in payload_builder,
        "guest attachment lacks pinned Bookworm/squashfs/product-gamescope exclusions",
    )
    # Positive/negative controls for cross-run reproducibility. Repacking one
    # already-built tree twice cannot detect mmdebstrap or source-tree clock
    # inputs, so both producer phases must consume the committed epoch.
    require(
        'find "$stage/build-root/src" -print0' in payload_builder
        and payload_builder.index('find "$stage/build-root/src" -print0')
        < payload_builder.index('chroot "$stage/build-root"'),
        "payload producer does not normalize source mtimes before compilation",
    )
    require(
        payload_builder.index("normalize-guest-payload-root.sh")
        < payload_builder.index("regenerate-guest-ld-cache.sh")
        < payload_builder.index("inventory-guest-payload.py"),
        "payload producer does not inventory the final regenerated loader cache",
    )
    nonreproducible_container = payload_container.replace(
        "export SOURCE_DATE_EPOCH", "# seeded missing epoch"
    )
    require(
        "export SOURCE_DATE_EPOCH" not in nonreproducible_container,
        "reproducibility audit missed its absent-mmdebstrap-epoch negative control",
    )
    nonreproducible_builder = payload_builder.replace(
        'find "$stage/build-root/src" -print0', "# seeded missing normalization"
    )
    require(
        'find "$stage/build-root/src" -print0' not in nonreproducible_builder,
        "reproducibility audit missed its absent-source-normalization negative control",
    )
    with open(os.path.join(HARNESS, "verify-guest-payload.sh"), "r", encoding="utf-8") as handle:
        payload_verifier = handle.read()
    require(
        "guest-payload-observed" in payload_verifier
        and payload_verifier.index("guest-payload-observed")
        < payload_verifier.index('[[ "$actual_sha" =='),
        "payload verifier does not report observed addresses before pin refusal",
    )
    with open(
        os.path.join(REPO, ".github", "workflows", "input-harness-payload.yml"),
        "r",
        encoding="utf-8",
    ) as handle:
        payload_workflow = handle.read()
    require(
        'docker buildx inspect pf-insecure --bootstrap' in payload_workflow
        and '--builder pf-insecure' in payload_workflow
        and 'docker pull "$PF_BUILD_IMAGE"' not in payload_workflow
        and '--build-arg PF_BUILD_IMAGE="$PF_BUILD_IMAGE"' in payload_workflow,
        "payload workflow does not use the runner's approved insecure-registry builder",
    )
    require(
        '--build-arg PF_APT_PROXY=http://10.0.32.86:3142' in payload_workflow,
        "payload workflow does not pass the fleet apt-cacher-ng endpoint",
    )
    require(
        'GITHUB_EVENT_NAME" = pull_request' in payload_workflow
        and "cache_args+=(--no-cache)" in payload_workflow
        and "input-harness-payload-cache-mode=cold" in payload_workflow,
        "payload PR workflow does not force and report a cold timing sample",
    )
    require(
        '--build-context sdl-src="$RUNNER_TEMP/payload-contexts/sdl"' in payload_workflow
        and '--build-context gamescope-src="$RUNNER_TEMP/payload-contexts/gamescope"'
        in payload_workflow
        and '--build-context libei-src="$RUNNER_TEMP/payload-contexts/libei"'
        in payload_workflow,
        "payload workflow does not stage pinned source contexts outside BuildKit RUN",
    )
    require(
        payload_workflow.index('cat "$out/$evidence"')
        < payload_workflow.index("verify-guest-payload.sh")
        and "apt-sources.txt runtime-packages.tsv payload-files.tsv" in payload_workflow,
        "payload workflow does not print full provenance before pin verification",
    )
    require(
        "push:" in payload_workflow
        and "branches: [main]" in payload_workflow
        and "github.event_name == 'push'" in payload_workflow,
        "payload workflow lacks its main-only trusted-intake producer",
    )
    require(
        "pf-artifact-intake-put" in payload_workflow
        and payload_workflow.count("intake_status=PASS") >= 1
        and "actions/upload-artifact" not in payload_workflow,
        "payload workflow does not use trusted intake exclusively",
    )
    with open(
        os.path.join(HARNESS, "guest", "build-tools.sh"), "r", encoding="utf-8"
    ) as handle:
        guest_build_tools = handle.read()
    require(
        "nproc" in guest_build_tools
        and "--parallel 2" not in guest_build_tools
        and "parallel=" in guest_build_tools,
        "payload guest build does not use and report runner capacity",
    )
    with open(os.path.join(HARNESS, "run-guest.sh"), "r", encoding="utf-8") as handle:
        guest_runner = handle.read()
    require(
        "reason=unsafe_uinput_domain" in guest_runner
        and "systemd-detect-virt --container --quiet" in guest_runner
        and "/proc/device-tree/compatible" in guest_runner,
        "guest runner lacks the positive-identity fail-closed preflight",
    )

    # Negative control for the auditor itself: injecting --privileged into
    # a copy of run.sh must be caught by the same scan.
    if os.path.exists(os.path.join(HARNESS, "run.sh")):
        poisoned = os.path.join(work, "poisoned-run.sh")
        shutil.copyfile(os.path.join(HARNESS, "run.sh"), poisoned)
        with open(poisoned, "a", encoding="utf-8") as handle:
            handle.write("# docker run --privileged\n")
        require(
            "--privileged" in audit_file(poisoned),
            "asset auditor failed its own negative control (--privileged not caught)",
        )

    # run.sh must be syntactically valid bash and executable.
    run_sh = os.path.join(HARNESS, "run.sh")
    if os.path.exists(run_sh):
        proc = subprocess.run(["bash", "-n", run_sh], capture_output=True, text=True)
        require(proc.returncode == 0, f"run.sh fails bash -n:\n{proc.stderr}")
        require(os.access(run_sh, os.X_OK), "run.sh is not executable")
        with open(run_sh, "r", encoding="utf-8") as handle:
            text = handle.read()
        require(
            audit_run_device_exposure(text) == [],
            f"run.sh exposes host input devices: {audit_run_device_exposure(text)}",
        )

        # Negative control for the host-input audit: the former unsafe grants
        # must all be rejected without executing the poisoned runner.
        poisoned_device_run = text + (
            "\ndocker run --device /dev/uinput "
            "--device-cgroup-rule 'c 13:* rmw' "
            "-v /dev/input:/dev/input image\n"
        )
        require(
            set(audit_run_device_exposure(poisoned_device_run))
            == {"device_flag", "device_cgroup_rule", "uinput_path", "input_bind"},
            "host-input auditor failed its seeded legacy-grants negative control",
        )
        require(
            "--label pf.bead" in text or "pf.bead=" in text,
            "run.sh does not label built images with pf.bead",
        )
        require("--rm" in text, "run.sh does not run containers with --rm")
        require(
            'tools/require-empty-output.sh" "$OUT"' in text,
            "run.sh does not call the non-empty output guard",
        )

        # Exercise the same freshness helper used by run.sh. An empty output
        # is the positive control; a prior artifact must fail closed without
        # deleting or overwriting it.
        output_check = os.path.join(HARNESS, "tools", "require-empty-output.sh")
        fresh = os.path.join(work, "fresh-output")
        proc = subprocess.run([output_check, fresh], capture_output=True, text=True)
        require(proc.returncode == 0, f"empty output directory was rejected:\n{proc.stdout}{proc.stderr}")
        stale = os.path.join(work, "stale-output")
        os.makedirs(stale)
        sentinel = os.path.join(stale, "prior.jsonl")
        with open(sentinel, "w", encoding="utf-8") as handle:
            handle.write("prior evidence\n")
        proc = subprocess.run([output_check, stale], capture_output=True, text=True)
        require(
            proc.returncode != 0
            and "reason=output_not_empty" in proc.stdout
            and os.path.exists(sentinel),
            f"non-empty output did not fail closed:\n{proc.stdout}{proc.stderr}",
        )
        for entry in ("session/entry.sh", "session/driver.py", "session/mangoapp", "session/udev-shim.sh"):
            path = os.path.join(HARNESS, entry)
            if not os.path.exists(path):
                continue
            if entry.endswith(".py"):
                # Compile in memory: `-m py_compile` would write a
                # __pycache__/*.pyc into the source tree, and this test
                # must never dirty the checkout it runs from.
                proc = subprocess.run(
                    [
                        sys.executable,
                        "-B",
                        "-c",
                        "import sys; compile(open(sys.argv[1], 'rb').read(), sys.argv[1], 'exec')",
                        path,
                    ],
                    capture_output=True,
                    text=True,
                )
            else:
                proc = subprocess.run(
                    ["bash", "-n", path], capture_output=True, text=True
                )
            require(proc.returncode == 0, f"{entry} fails syntax check:\n{proc.stderr}")

    private_input = os.path.join(HARNESS, "tools", "private-input.c")
    driver = os.path.join(HARNESS, "session", "driver.py")
    bridge = os.path.join(HARNESS, "tools", "eis-bridge.c")
    if all(os.path.exists(path) for path in (private_input, driver, bridge)):
        with open(driver, "r", encoding="utf-8") as handle:
            driver_text = handle.read()
        with open(bridge, "r", encoding="utf-8") as handle:
            bridge_text = handle.read()
        with open(private_input, "r", encoding="utf-8") as handle:
            private_input_text = handle.read()
        require(
            "socket.SOCK_SEQPACKET" in driver_text,
            "driver.py does not create private SOCK_SEQPACKET streams",
        )
        require(
            '"--keyboard-event-fd"' in bridge_text
            and '"--pointer-event-fd"' in bridge_text,
            "eis-bridge.c does not require explicit private event fds",
        )
        require(
            'open("/dev/uinput"' not in private_input_text
            and 'open("/dev/input' not in private_input_text,
            "private-input.c opens a host input device",
        )
        require(
            "send(fd, events, size, MSG_NOSIGNAL)" in private_input_text
            and "event(EV_SYN, SYN_REPORT, 0)" in private_input_text,
            "private-input.c does not frame complete input_event packets",
        )
        require(
            "open(" not in bridge_text and "open(" not in private_input_text,
            "private input path opens a filesystem object",
        )
        for rel, source in (
            ("session/driver.py", driver_text),
            ("tools/eis-bridge.c", bridge_text),
            ("tools/private-input.c", private_input_text),
        ):
            require(
                "/dev/uinput" not in source and "/dev/input/" not in source,
                f"default input path {rel} references a host input device",
            )
        require(
            'os.environ.get("PF_INPUT_SOURCE") == "guest-kernel"' in driver_text
            and 'class KernelInput:' in driver_text
            and '"fake-input"' in driver_text
            and "udev-shim.sh" not in driver_text,
            "driver.py does not confine the kernel-device path to the explicit guest mode",
        )
        with open(os.path.join(HARNESS, "Containerfile"), "r", encoding="utf-8") as handle:
            container_text = handle.read()
        require(
            "/src/tools/private-input.c" in container_text
            and "/src/tools/fake-input.c" not in container_text,
            "default harness image does not exclusively build private-input",
        )

    # Gamescope may start its primary child before exporting WAYLAND_DISPLAY.
    # The driver must make its documented gamescope-0 fallback visible to all
    # client subprocesses, rather than using it only for its own socket wait.
    driver_mod = load_module(
        "pf_input_harness_driver",
        os.path.join(HARNESS, "session", "driver.py"),
    )
    fallback_env = {}
    fallback_display = driver_mod.configure_wayland_display(fallback_env)
    require(
        fallback_display == "gamescope-0"
        and fallback_env.get("WAYLAND_DISPLAY") == "gamescope-0",
        "driver does not export its fallback Wayland display to clients",
    )
    explicit_env = {"WAYLAND_DISPLAY": "gamescope-test"}
    require(
        driver_mod.configure_wayland_display(explicit_env) == "gamescope-test"
        and explicit_env["WAYLAND_DISPLAY"] == "gamescope-test",
        "driver overwrites an explicit Wayland display",
    )

    # Direct driver invocation must also fail closed on stale evidence, even
    # when a caller bypasses run.sh's output-directory guard.
    driver_out = os.path.join(work, "driver-output")
    driver_mod.TX_DIR = os.path.join(driver_out, "transcripts")
    driver_mod.SHOT_DIR = os.path.join(driver_out, "screenshots")
    driver_mod.SESSION_TX = os.path.join(driver_out, "session.jsonl")
    driver_mod.prepare_output()
    require(
        os.path.isdir(driver_mod.TX_DIR) and os.path.isdir(driver_mod.SHOT_DIR),
        "driver rejected a fresh output directory",
    )
    stale_tx = os.path.join(driver_mod.TX_DIR, "gtk4-text.jsonl")
    with open(stale_tx, "w", encoding="utf-8") as handle:
        handle.write("prior evidence\n")
    try:
        driver_mod.prepare_output()
    except RuntimeError as exc:
        require(
            "not empty" in str(exc) and os.path.exists(stale_tx),
            f"driver stale-output rejection was not fail-closed: {exc}",
        )
    else:
        require(False, "driver accepted a stale transcript directory")

    # libei event-owned objects are transient. The bridge keeps the emulated
    # device after EI_EVENT_DEVICE_ADDED, so it must own a reference until the
    # matching removal rather than retaining the event's borrowed pointer.
    bridge_path = os.path.join(HARNESS, "tools", "eis-bridge.c")
    with open(bridge_path, "r", encoding="utf-8") as handle:
        bridge_source = handle.read()
    require(
        "g_dev = ei_device_ref(ei_event_get_device(event));" in bridge_source,
        "eis-bridge retains an event-borrowed device without ei_device_ref",
    )
    require(
        "g_dev = ei_device_unref(g_dev);" in bridge_source,
        "eis-bridge does not release its retained device",
    )

    # A socket alone is insufficient: gamescope only manages native
    # xdg-shell surfaces when its Wayland exposure path is enabled.
    entry_path = os.path.join(HARNESS, "session", "entry-guest.sh")
    with open(entry_path, "r", encoding="utf-8") as handle:
        entry_source = handle.read()
    require(
        "/usr/bin/gamescope --backend drm --expose-wayland" in entry_source
        and "--backend headless" not in entry_source,
        "guest real-kernel tier must use product gamescope's libinput-capable DRM session",
    )

    with open(os.path.join(HARNESS, "session", "driver.py"), "r", encoding="utf-8") as handle:
        driver_source = handle.read()
    require(
        'sw.emit("client_stop", target=name)' in driver_source,
        "driver does not record screenshot-before-stop ordering",
    )
    require(
        'screenshot(sw, "idle")' not in driver_source,
        "driver requests a screenshot before any surface can trigger a repaint",
    )
    require(
        'pointer.cmd("abs 320 240")' in driver_source
        and 'pointer.cmd("abs 640 360")' not in driver_source,
        "driver does not target the logical center shared by its 640x480 clients",
    )
    x_ready = driver_source.find("wait_for_x_display(")
    client_loop = driver_source.find("for (name, backend, purpose, phrase, gui, preload,")
    require(
        x_ready >= 0 and client_loop > x_ready and "XOpenDisplay" in driver_source,
        "driver launches clients before Xwayland accepts display connections",
    )
    require(
        'kbd.cmd("key 42 1")' in driver_source
        and 'kbd.cmd("key 42 0")' in driver_source,
        "driver does not initialize the emulated keyboard before acceptance input",
    )
    first_click = driver_source.find('pointer.cmd("btn 272 1")')
    second_click = driver_source.find('pointer.cmd("btn 272 1")', first_click + 1)
    require(
        first_click >= 0 and second_click > first_click
        and "A newly mapped gamescope window may consume the first click"
        in driver_source[first_click - 250:first_click],
        "driver does not separate compositor activation from the observable client click",
    )

    with open(os.path.join(HARNESS, "clients", "no-im.c"), "r", encoding="utf-8") as handle:
        no_im_source = handle.read()
    initial_commit = no_im_source.find("wl_surface_commit(g_surface);", no_im_source.find("xdg_toplevel_set_title"))
    configure_wait = no_im_source.find("while (!g_configured)")
    require(
        initial_commit >= 0 and initial_commit < configure_wait,
        "no-im waits for the first xdg configure without an initial empty surface commit",
    )

    for rel in ("clients/sdl3-text.c", "clients/sdl2-game.c"):
        with open(os.path.join(HARNESS, rel), "r", encoding="utf-8") as handle:
            sdl_source = handle.read()
        require(
            "SDL_CreateRenderer" in sdl_source and "SDL_RenderPresent" in sdl_source,
            f"{rel} never attaches a rendered buffer to its Wayland surface",
        )

    for rel in (
        "clients/gtk4-text.c",
        "clients/qt6-text.cpp",
        "clients/sdl3-text.c",
        "clients/sdl2-game.c",
        "clients/x11-gtk.c",
        "clients/xim-only.c",
        "clients/no-im.c",
    ):
        with open(os.path.join(HARNESS, rel), "r", encoding="utf-8") as handle:
            client_source = handle.read()
        require(
            '"widget_text"' in client_source,
            f"{rel} does not read back and transcribe its displayed text buffer",
        )

    with open(os.path.join(HARNESS, "schema", "transcript-schema.md"), "r", encoding="utf-8") as handle:
        schema_text = handle.read()
    require(
        "`widget_text`" in schema_text,
        "transcript schema does not define widget_text readback evidence",
    )

    with open(os.path.join(HARNESS, "clients", "gtk4-text.c"), "r", encoding="utf-8") as handle:
        gtk_source = handle.read()
    require(
        "gtk_event_controller_legacy_new()" in gtk_source
        and "GTK_PHASE_CAPTURE" in gtk_source
        and "gdk_button_event_get_button" in gtk_source,
        "GTK client does not record real GDK button events in capture phase",
    )
    require(
        "gtk_event_controller_key_new()" in gtk_source
        and "gtk_widget_add_controller(win, kc);" in gtk_source
        and "gtk_event_controller_set_propagation_phase(kc, GTK_PHASE_CAPTURE);"
        in gtk_source,
        "GTK key transcript runs after the input-method filter",
    )
    require(
        'g_signal_connect(clock, "after-paint"' in gtk_source
        and 'pf_tx_emitf("mapped"' in gtk_source,
        "GTK client declares itself mapped before its first painted frame",
    )
    require(
        'gtk_widget_set_cursor_from_name(g_entry, "text");' in gtk_source
        and 'pf_tx_emitf("cursor", ",\\"name\\":\\"text\\"");' in gtk_source,
        "GTK client does not record its explicit text cursor request",
    )

    # pins.env must pin the fork by full commit sha.
    pins_path = os.path.join(HARNESS, "pins.env")
    if os.path.exists(pins_path):
        pins = {}
        with open(pins_path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    key, value = line.split("=", 1)
                    pins[key.strip()] = value.strip()
        require(
            pins.get("GAMESCOPE_URL") == "https://github.com/pocketforge-os/gamescope.git",
            f"pins.env GAMESCOPE_URL is not the org fork: {pins.get('GAMESCOPE_URL')!r}",
        )
        require(
            re.fullmatch(r"[0-9a-f]{40}", pins.get("GAMESCOPE_COMMIT", "")) is not None,
            f"pins.env GAMESCOPE_COMMIT is not a full sha: {pins.get('GAMESCOPE_COMMIT')!r}",
        )
        require(
            pins.get("GAMESCOPE_BRANCH") == "pocketforge-linear",
            f"pins.env does not identify the linear gamescope branch: {pins.get('GAMESCOPE_BRANCH')!r}",
        )
        require(
            pins.get("GAMESCOPE_COMMIT")
            == "0b03a62e720ae93afbd5e59167c8774f8ad74f0c",
            f"pins.env lost the producer-verified gamescope pin: {pins.get('GAMESCOPE_COMMIT')!r}",
        )
        require(
            pins.get("WAYLAND_PROTOCOLS_URL")
            == "https://github.com/pocketforge-os/wayland-protocols.git",
            "pins.env lost the source-closure wayland-protocols fork",
        )
        require(
            pins.get("WAYLAND_PROTOCOLS_COMMIT")
            == "aa62366fb800a0689f4e9de83811ff33f6a91f44",
            "pins.env lost gamescope's wlroots-wayland-protocols closure pin",
        )

        with open(os.path.join(HARNESS, "Containerfile"), "r", encoding="utf-8") as handle:
            containerfile = handle.read()
        require(
            'ARG GAMESCOPE_COMMIT=0b03a62e720ae93afbd5e59167c8774f8ad74f0c'
            in containerfile,
            "Containerfile does not default to the headless-safe gamescope pin",
        )
        require(
            'ARG WAYLAND_PROTOCOLS_COMMIT=aa62366fb800a0689f4e9de83811ff33f6a91f44'
            in containerfile,
            "Containerfile does not default to the admitted wayland-protocols closure pin",
        )
        require(
            "libjson-c-dev" in containerfile,
            "Containerfile does not provision gamescope's required json-c dependency",
        )
        require(
            "libjson-c5" in containerfile,
            "Containerfile does not provision gamescope's json-c runtime library",
        )
        require(
            'checkout "${WAYLAND_PROTOCOLS_COMMIT}"' in containerfile,
            "Containerfile does not materialize the exact wayland-protocols commit",
        )

    # The trixie builder's wayland-protocols 1.44 must not win over the
    # gamescope source closure's 1.49. Exercise the provisioning helper and
    # prove both the required ordering and its deliberately reversed negative.
    provision = os.path.join(HARNESS, "tools", "provision-wayland-protocols.sh")
    protocol_fixture = os.path.join(work, "wayland-protocols-source")
    cursor_shape = os.path.join(
        protocol_fixture, "staging", "cursor-shape", "cursor-shape-v1.xml"
    )
    os.makedirs(os.path.dirname(cursor_shape))
    with open(cursor_shape, "w", encoding="utf-8") as handle:
        handle.write("<protocol name=\"fixture\"/>\n")
    exposed = os.path.join(work, "wayland-protocols-exposed")
    pinned_pc = os.path.join(work, "wayland-protocols-pinned-pc")
    proc = subprocess.run(
        [provision, protocol_fixture, exposed, pinned_pc],
        capture_output=True,
        text=True,
    )
    require(proc.returncode == 0, f"wayland-protocol provisioning failed:\n{proc.stderr}")
    old_pc = os.path.join(work, "wayland-protocols-old-pc")
    os.makedirs(old_pc)
    with open(os.path.join(old_pc, "wayland-protocols.pc"), "w", encoding="utf-8") as handle:
        handle.write(
            "prefix=/fixture-old\nName: wayland-protocols\n"
            "Description: deliberately old negative control\nVersion: 1.44\n"
        )

    def resolved_protocol_version(path):
        env = os.environ.copy()
        env["PKG_CONFIG_PATH"] = path
        result = subprocess.run(
            ["pkg-config", "--modversion", "wayland-protocols"],
            env=env,
            capture_output=True,
            text=True,
        )
        return result.returncode, result.stdout.strip(), result.stderr

    rc, version, error = resolved_protocol_version(os.pathsep.join((pinned_pc, old_pc)))
    require(rc == 0 and version == "1.49", f"pinned .pc did not win: {version!r} {error}")
    rc, version, error = resolved_protocol_version(os.pathsep.join((old_pc, pinned_pc)))
    require(
        rc == 0 and version == "1.44",
        f"reversed-order negative control did not expose 1.44: {version!r} {error}",
    )

    # The hermetic CI workflow must run this self-test.
    workflow = os.path.join(REPO, ".github", "workflows", "hermetic-tests.yml")
    with open(workflow, "r", encoding="utf-8") as handle:
        workflow_text = handle.read()
    require(
        "tests/test-input-harness-selftest.sh" in workflow_text,
        "hermetic-tests.yml does not run tests/test-input-harness-selftest.sh",
    )

    # README must document blast radius and the one-command entry point.
    readme = os.path.join(HARNESS, "README.md")
    if os.path.exists(readme):
        with open(readme, "r", encoding="utf-8") as handle:
            text = handle.read().lower()
        for phrase in ("blast radius", "run.sh", "transcript", "1280x720"):
            require(phrase in text, f"README.md lost load-bearing phrase: {phrase}")


def section_layout_scenario(work):
    """AC1: shipped layout environment controls the private-fd GTK path."""
    for retired in (
        os.path.join(REPO, "tests", "kbd-layout-harness"),
        os.path.join(REPO, "tests", "test-kbd-layout-gamescope.sh"),
        os.path.join(REPO, ".github", "workflows", "kbd-layout-gamescope.yml"),
    ):
        require(not os.path.exists(retired), f"unsafe legacy layout harness remains: {retired}")

    scenario_path = os.path.join(HARNESS, "report", "layout_scenario.py")
    require(os.path.exists(scenario_path), "shared harness has no layout scenario evaluator")
    if not os.path.exists(scenario_path):
        return

    scenario = load_module("pf_layout_scenario", scenario_path)
    transcript = os.path.join(work, "layout.jsonl")
    builder = make_fixtures.Builder("gtk4-text")
    builder.event(
        "start", pid=201, argv=["gtk4-text"], backend="wayland", display="gamescope-0"
    )
    builder.event("widget_text", text="zö")
    builder.event("stop", rc=0)
    builder.write(transcript)

    passed, reason, actual = scenario.evaluate_transcript(transcript, "zö")
    require(passed and reason == "ok" and actual == "zö", "de layout positive control failed")
    passed, reason, actual = scenario.evaluate_transcript(transcript, "y;")
    require(
        not passed and reason == "layout_widget_text_mismatch" and actual == "zö",
        "deliberately wrong layout expectation did not fail closed",
    )
    proc = subprocess.run(
        [sys.executable, "-B", scenario_path, transcript, "y;", "de-wrong"],
        capture_output=True,
        text=True,
    )
    require(
        proc.returncode != 0 and "reason=layout_widget_text_mismatch" in proc.stdout,
        f"layout CLI negative control did not print reason=: {proc.stdout}{proc.stderr}",
    )

    with open(os.path.join(HARNESS, "session", "entry.sh"), encoding="utf-8") as handle:
        entry = handle.read()
    with open(os.path.join(HARNESS, "session", "driver.py"), encoding="utf-8") as handle:
        driver = handle.read()
    require(
        "/usr/lib/pocketforge/kbd-layout-env" in entry
        and "run_layout de 'zö'" in entry
        and "run_layout us 'y;'" in entry
        and "keyboardLayout" in entry,
        "layout sessions do not derive de and us environments through shipped code",
    )
    require(
        '"KEY_Y": 21' in driver and '"KEY_SEMICOLON": 39' in driver,
        "layout scenario does not send evdev KEY_Y and KEY_SEMICOLON",
    )
    require(
        "SOCK_SEQPACKET" in driver and "PF_LAYOUT_SCENARIO" in driver,
        "layout scenario is not carried by the shared private-fd driver",
    )


def main():
    with tempfile.TemporaryDirectory(prefix="pf-input-harness-selftest.") as work:
        section_validator_and_report(work)
        section_asset_audit(work)
        section_layout_scenario(work)
    if FAILURES:
        print(f"FAIL: input-harness self-test ({len(FAILURES)} failure(s))")
        return 1
    print("PASS: input-harness hermetic self-test (validator + report + asset audit, positive and negative controls)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
