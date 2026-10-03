#!/usr/bin/env python3
"""Machine-check the load-bearing G0/G1 session-display design contract."""

from pathlib import Path
import re
import tomllib


ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs" / "SESSION-COMPOSITOR.md"
FIXTURE = ROOT / "tests" / "fixtures" / "session-compositor-contract.toml"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def full_sha(value: str, label: str) -> None:
    require(re.fullmatch(r"[0-9a-f]{40}", value) is not None,
            f"{label} is not a full Git object ID")


data = tomllib.loads(FIXTURE.read_text(encoding="utf-8"))
doc = DOC.read_text(encoding="utf-8")
app_unit = (ROOT / "rootfs-overlay" / "etc" / "systemd" / "system" /
            "pf-app@.service").read_text(encoding="utf-8")
default_apps = (ROOT / "docs" / "DEFAULT-APPS.md").read_text(encoding="utf-8")

require(data["schema"] == 2, "fixture schema drift")
require(data["design_state"] == "G0", "design is no longer G0")
require(data["implementation_gate"] ==
        "blocked-until-g0-gaps-and-g1-device-bench",
        "implementation/device gate was weakened")
require(data["device_claims"] == "UNPROVEN", "device claims were promoted")
require(data["qemu_scope"] == "logic-only", "QEMU scope was overstated")

pins = data["pins"]
gamescope = pins["gamescope"]
require(gamescope["commit"] == "5fb8dce4a09d0a68d097b9faf9513782106bc843",
        "Gamescope pin changed")
for field in ("commit", "tree"):
    full_sha(gamescope[field], f"Gamescope {field}")
require(re.fullmatch(r"[0-9a-f]{64}", gamescope["license_sha256"]) is not None,
        "Gamescope license digest is not SHA-256")
for value in gamescope.values():
    if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40,64}", value):
        require(value in doc, f"document omits Gamescope pin value {value}")

for group in (gamescope["gitlinks"], gamescope["wraps"]):
    for name, sha in group.items():
        full_sha(sha, f"Gamescope dependency {name}")
        require(sha in doc, f"document omits dependency pin {name}")

for component in ("mesa_pvr", "a133_kernel_audit", "weston_fallback",
                  "pixman_fallback"):
    pin = pins[component]
    full_sha(pin["commit"], f"{component} commit")
    require(pin["commit"] in doc, f"document omits {component} commit")
    if "tree" in pin:
        full_sha(pin["tree"], f"{component} tree")
        require(pin["tree"] in doc, f"document omits {component} tree")

for name, sha in data["admitted_repositories"].items():
    full_sha(sha, f"admitted {name}")
    require(sha in doc, f"document omits admitted {name} SHA")

session = data["session"]
require(session["runtime_dir"] == "/run/pocketforge/session",
        "canonical session directory changed")
require(session["wayland_socket"] == "/run/pocketforge/session/wayland-0",
        "canonical Wayland socket changed")
require(session["environment_file"] == "/run/pocketforge/session/environment",
        "environment record changed")
require(session["app_unit_template"] == "pf-app@.service",
        "a second app launch unit was introduced")
require(session["app_descriptor"] == "app.toml", "descriptor contract changed")
require(session["authority"] == "pf-session-authority", "authority forked")
require(session["input_broker"] == "pf-input-broker", "input broker forked")
require(session["client_protocol"] == "xdg-shell",
        "ordinary clients became compositor-specific")
require(session["socket_collision_policy"] == "refuse",
        "socket cleanup is no longer fail-closed")
require(session["environment_publish"] == "temp-fsync-rename",
        "environment publication lost atomicity")
for key in ("runtime_dir", "wayland_socket", "environment_file"):
    require(session[key] in doc, f"document omits session {key}")

capability = data["capability_schema"]
require(capability["source_glob"] == "platform/devices/<id>/capabilities.toml",
        "device capability source changed")
require(capability["staged_glob"] ==
        "/usr/share/pocketforge/devices/<id>/capabilities.toml",
        "device capability destination changed")
require(capability["launcher_app_vocabulary_unchanged"],
        "display facts must not pollute app capabilities")
expected_fields = {
    "native_mode", "composition_tier", "plane_count", "plane_modifiers",
    "plane_alpha", "plane_zpos", "kms_rotations", "gpu_composition",
    "vulkan_level",
}
require(set(capability["screen_fields"]) == expected_fields,
        "display capability vocabulary drift")

tiers = {tier["id"]: tier for tier in data["device_tiers"]}
require(set(tiers) == {"projector-256m", "a133-1g", "real-gpu-8-12g"},
        "device tier set changed")
projector = tiers["projector-256m"]
require(projector["composition_tier"] == "plane-only"
        and projector["plane_count_min"] == 2
        and projector["overlay_behavior"] == "freeze-client-last-buffer"
        and not projector["gpu_composition"],
        "256 MiB plane-only policy changed")
a133 = tiers["a133-1g"]
require(a133["composition_tier"] == "planes-first"
        and a133["display_owner"] == "gamescope-candidate"
        and a133["failover_owner"] == "lightweight-plane-owner",
        "A133 owner decision changed")
require((a133["native_width"], a133["native_height"]) == (720, 1280),
        "A133 native portrait mode changed")
require((a133["logical_width"], a133["logical_height"]) == (1280, 720),
        "A133 logical landscape mode changed")
require(a133["plane_count"] == 4 and a133["plane_modifier"] == "LINEAR"
        and a133["kms_rotations"] == ["normal"],
        "A133 plane/no-rotation hypothesis changed")
require(not a133["gpu_composition"] and a133["qualification"] == "G1",
        "A133 GPU composition was admitted before G1")
high = tiers["real-gpu-8-12g"]
require(high["composition_tier"] == "gpu" and high["gpu_composition"],
        "real-GPU tier lost full composition")

ownership = data["ownership"]
require("Mesa-PVR-and-kernel" in ownership["gpucap"],
        "GPUCAP capability ownership lost")
require("Gamescope-staging-rotation-present-gating-packaging" in
        ownership["compositor"], "COMPOSITOR ownership drift")
require("device-bench3-pf-bench" in ownership["cx_deputy"],
        "CX-DEPUTY ownership drift")
require(not ownership["mesa_worker_from_compositor"],
        "COMPOSITOR must not create a Mesa worker")
require(not ownership["platform_lock_moves_under_sealed_bench"],
        "sealed bench must prohibit GPU pin moves")

gaps = {gap["id"]: gap for gap in data["g0_gaps"]}
require(set(gaps) == {"L", "M-semaphore", "M-rotation", "S", "M-packaging"},
        "G0 gap set changed")
require(gaps["M-semaphore"]["owner"] == "GPUCAP",
        "opaque timeline FD must remain GPUCAP-owned")
for gap_id in ("L", "M-rotation", "S", "M-packaging"):
    require(gaps[gap_id]["owner"] == "COMPOSITOR",
            f"{gap_id} must remain COMPOSITOR-owned")
require(gaps["M-packaging"]["bead"] == "tsp-op5a.440.1",
        "Gamescope M-packaging must remain owned by tsp-op5a.440.1")
fallback_only_beads = {"tsp-0c9b666ac3daca7d5aed"}
require(fallback_only_beads.isdisjoint(gap["bead"] for gap in gaps.values()),
        "a fallback-only bead cannot satisfy a Gamescope G0 gap")
require(gaps["L"]["dependency_owner"] == "GPUCAP"
        and gaps["M-rotation"]["dependency_owner"] == "GPUCAP",
        "Gamescope patches lost GPUCAP capability dependencies")
for gap in gaps.values():
    require(gap["source_state"] == "RED", f"{gap['id']} was promoted without work")
    require(gap["bead"] in doc, f"document omits gap bead {gap['id']}")

input_contract = data["input"]
require(input_contract["physical_gamepad_owner"] == "pf-input-broker",
        "broker must be the sole physical gamepad owner")
require(input_contract["transport"] == "uinput-SCM_RIGHTS",
        "input fd transport changed")
require(not input_contract["menu_forwarded_to_client"]
        and not input_contract["gamescope_opens_physical_gamepad"]
        and not input_contract["gamescope_opens_broker_gamepad"]
        and not input_contract["dual_delivery"],
        "protected input isolation was weakened")
require("EVIOCGRAB" in default_apps and "SCM_RIGHTS" in default_apps
        and "BTN_MODE" in default_apps,
        "existing broker evidence disappeared")

xwayland = data["xwayland"]
require(xwayland["opt_in_per_app"] and xwayland["filesystem_socket_projected"]
        and xwayland["abstract_socket_forbidden"] and xwayland["tcp_forbidden"]
        and xwayland["xauthority_required"]
        and not xwayland["host_x11_directory_projected"],
        "private-root Xwayland policy changed")

require(data["g1"]["prerequisites"] ==
        ["pf-bench", "gpucap-receipts", "sealed-exact-pin-manifest"],
        "G1 prerequisites changed")
primary = data["g1"]["primary"]
require(primary["mode"] == "720x1280@60"
        and primary["buffer"] == "pre-rotated-720x1280-XRGB8888-LINEAR"
        and primary["buffer_transform"] == "normal"
        and primary["kms_rotation"] == "normal",
        "G1 pre-rotated/no-KMS-rotation contract changed")
require(primary["duration_seconds"] == 120 and primary["warmup_seconds"] == 10
        and primary["overlay_toggles"] == 100,
        "G1 primary sampling plan changed")
require(primary["required_app_plane_stability"]
        and not primary["forced_composite_allowed"],
        "G1 primary was weakened")
pt = primary["thresholds"]
require((pt["mean_fps_min"], pt["mean_fps_max"]) == (59.0, 61.0),
        "primary fps threshold changed")
require(pt["p99_frame_interval_ms_max"] == 20.0
        and pt["frame_intervals_over_33_34_ms_max"] == 0,
        "primary pacing threshold changed")
for key in ("failed_atomic_commits_max", "gamescope_composite_dispatches_max",
            "gamescope_staging_copies_max", "gpu_faults_max",
            "guilty_lockups_max"):
    require(pt[key] == 0, f"primary zero threshold changed: {key}")

secondary = data["g1"]["secondary"]
require(secondary["duration_seconds"] == 600
        and secondary["path"].startswith("forced-full-GPU-composition"),
        "secondary composition plan changed")
require((secondary["estimate_gib_per_second_low"],
         secondary["estimate_gib_per_second_high"]) == (0.99, 1.07),
        "secondary binary-GiB estimate changed")
st = secondary["thresholds"]
require(st["measured_dram_gib_per_second_delta_max"] == 1.50
        and st["measured_dram_fraction_of_sustainable_max"] == 0.50,
        "secondary bandwidth threshold changed")
memory = data["g1"]["memory"]
require(memory == {
    "gamescope_pss_mib_max": 128,
    "xwayland_pss_mib_max": 96,
    "client_pss_mib_max": 128,
    "combined_pss_mib_max": 384,
    "combined_rss_mib_max": 512,
    "system_memavailable_mib_min": 192,
    "sample_period_seconds": 1,
}, "G1 memory budget changed")

recovery = data["recovery"]
require(not recovery["authority_may_restart"]
        and not recovery["input_broker_may_restart"]
        and recovery["client_kill_first"]
        and recovery["compositor_restart_max_per_incident"] == 1
        and recovery["recovery_ui_deadline_seconds"] == 3
        and recovery["session_generation_increment"] == 1
        and recovery["restart_storm_forbidden"]
        and not recovery["intentional_device_fault_injection"],
        "fault-containment contract changed")

require(data["g2"]["order"] == [
    "pf-shell-client", "session-socket-contract", "input-and-system-keys",
    "gamescope-external-overlay", "steam-link-handoff",
], "G2 order changed")

estimate = data["estimates"]["a133_720x1280_60"]
require(estimate["pixels_per_frame"] == 720 * 1280, "pixel count is wrong")
require(estimate["pixels_per_second"] == 720 * 1280 * 60,
        "pixel rate is wrong")
require(estimate["rgba_bytes_per_frame"] == 720 * 1280 * 4,
        "RGBA frame size is wrong")
require(estimate["one_layer_read_write_bytes_per_second"] ==
        estimate["rgba_bytes_per_frame"] * 60 * 2,
        "one-layer traffic estimate is wrong")
require(estimate["staging_copy_increment_bytes_per_second"] ==
        estimate["rgba_bytes_per_frame"] * 60 * 2,
        "staging traffic estimate is wrong")
require(estimate["one_layer_plus_staging_lower_bound_bytes_per_second"] ==
        estimate["rgba_bytes_per_frame"] * 60 * 4,
        "composition+staging estimate is wrong")
require(not estimate["measurement"], "analytic estimate was called a measurement")

require("ExecStart=/usr/bin/pf-app-launch %i" in app_unit,
        "the single pf-app launch path changed")
required_doc_phrases = (
    "Gamescope-first",
    "UNPROVEN until G1",
    "logic-only",
    "freeze the client's last framebuffer",
    "Claim / evidence / counterexample adjudication",
    "G1 PRIMARY FAIL",
    "COMPOSITOR creates no Mesa worker",
    "No `platform.lock` gpu-um-tsp movement occurs under a sealed bench",
    "one `pf-session-authority`",
    "one `pf-app@<id>.service`",
    "estimate is analytical, not a measurement",
)
normalized_doc = " ".join(doc.split()).lower()
for phrase in required_doc_phrases:
    require(" ".join(phrase.split()).lower() in normalized_doc,
            f"document lost load-bearing phrase: {phrase}")

print("PASS: exact-pinned Gamescope-first G0/G1 session-display contract")
