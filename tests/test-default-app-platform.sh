#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renderer="${root}/scripts/render-platform-capabilities.py"
dockerfile="${root}/build/Dockerfile.pf"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/default-app-platform.XXXXXX")"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT

runtime_source="${tmp}/runtime"
mkdir -p "${runtime_source}/crates/pf-app-manifest/src"
printf '%s\n' \
    'pub const KNOWN_CAPABILITIES: &[&str] = &[' \
    '    "input", "vibration", "entropy", "audio", "settings",' \
    '];' \
    'pub const KNOWN_GLES_VERSIONS: &[&str] = &["2.0", "3.0", "3.1", "3.2"];' \
    'pub const KNOWN_VULKAN_VERSIONS: &[&str] = &["1.0", "1.1", "1.2", "1.3", "1.4"];' \
    'pub const KNOWN_INPUTS: &[&str] = &[' \
    '    "buttons", "dpad", "stick", "two_sticks", "touch", "keyboard", "pointer",' \
    '];' \
    > "${runtime_source}/crates/pf-app-manifest/src/lib.rs"

# A pre-tsp-fxlsw runtime source (the pinned de890215 shape): it carries no
# schema-2 vocabularies, so the renderer must fail closed rather than invent them.
pre_task1_source="${tmp}/runtime-pre-task1"
mkdir -p "${pre_task1_source}/crates/pf-app-manifest/src"
printf '%s\n' \
    'pub const KNOWN_CAPABILITIES: &[&str] = &[' \
    '    "input", "vibration", "entropy", "audio", "settings",' \
    '];' \
    > "${pre_task1_source}/crates/pf-app-manifest/src/lib.rs"

# Descriptor fixture mirroring the shipped platform devices/a133/capabilities.toml
# (descriptor schema_version 2): [memory] facts, provisional gles_max with no
# vulkan_max, one primary screen, and the full pad input matrix including the
# class="system" volume rows that must NOT derive app-facing input tokens.
write_descriptor() { # $1=path $2=variant
    python3 - "$1" "$2" <<'PY'
import sys

path, variant = sys.argv[1], sys.argv[2]
version = 'schema_version = 2\n'
suffix = ''
memory = '[memory]\nphysical_mib = 970\napp_budget_mib = 600\n'
graphics = '[graphics]\ngles_max = "3.0"\n'
screens = ('[[screens]]\nrole = "primary"\npresent = "portrait"\nrotation = "cw90"\n'
           'render_canvas = { w = 1280, h = 720 }\n')
inputs = ''.join(
    f'[[inputs]]\nid = "{name}"\nkind = "{kind}"\n' + extra
    for name, kind, extra in (
        ("south", "button", ""),
        ("north", "button", ""),
        ("l1", "button", ""),
        ("dpad", "hat", ""),
        ("lstick", "stick", ""),
        ("rstick", "stick", ""),
        ("lstick-click", "stick-click", ""),
        ("ltrig", "trigger", ""),
        ("vol_up", "button", 'class = "system"\n'),
    )
)
if variant == "base":
    pass
elif variant == "touch":
    screens += 'touch = { protocol = "mt-b", slots = 5 }\n'
elif variant == "no-graphics":
    graphics = ""
elif variant == "no-memory":
    memory = ""
elif variant == "no-budget":
    memory = "[memory]\nphysical_mib = 970\n"
elif variant == "v1":
    version = "schema_version = 1\n"
elif variant == "v3":
    version = "schema_version = 3\n"
    suffix = ('\n[input_profile]\n'
              'device_class = "two_stick"\n'
              'reserved_controls = ["guide"]\n')
elif variant == "v4":
    version = "schema_version = 4\n"
elif variant == "no-primary":
    screens = screens.replace('role = "primary"', 'role = "secondary"')
elif variant == "two-primary":
    screens += screens
elif variant == "system-only":
    inputs = '[[inputs]]\nid = "vol_up"\nkind = "button"\nclass = "system"\n'
elif variant == "unknown-kind":
    inputs += '[[inputs]]\nid = "wand"\nkind = "wand"\n'
elif variant == "gles-bad":
    graphics = '[graphics]\ngles_max = "1.5"\n'
elif variant == "vulkan-bad":
    graphics = '[graphics]\ngles_max = "3.0"\nvulkan_max = "9.9"\n'
else:
    raise SystemExit(f"unknown descriptor variant {variant!r}")
with open(path, "w", encoding="utf-8") as handle:
    handle.write(version + memory + graphics + screens + inputs + suffix)
PY
}

descriptor="${tmp}/descriptor.toml"
write_descriptor "${descriptor}" base

render_open() { # $1=--descriptor value $2=output $3...=extra env via caller
    PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
    PF_APP_RUNTIME_ABI=1 \
    PF_APP_PLATFORM_VERSION=20 \
    PF_APP_CAPABILITIES='audio entropy input settings' \
        "${renderer}" --soc sun50iw10p1 --gpu-model open \
        --runtime-source "${runtime_source}" --descriptor "$1" --output "$2"
}

output="${tmp}/open/usr/share/pocketforge/platform-capabilities.toml"
render_open "${descriptor}" "${output}"

python3 - "${output}" <<'PY'
import sys
import tomllib
from pathlib import Path

parsed = tomllib.loads(Path(sys.argv[1]).read_text())
assert parsed == {
    "schema_version": 2,
    "runtime_family": "pocketforge/a133-powervr",
    "runtime_abi": "1",
    "platform_version": "20",
    "supported_capabilities": ["audio", "entropy", "input", "settings"],
    "physical_memory_mib": 970,
    "app_memory_budget_mib": 600,
    "gles_max": "3.0",
    "inputs": ["buttons", "dpad", "stick", "two_sticks"],
    "display": {"width": 1280, "height": 720},
}, parsed
PY

# Descriptor v3 adds [input_profile] while retaining the v2 memory/graphics,
# screen, and input facts consumed here. The renderer deliberately ignores the
# router-owned input profile and produces the identical image contract.
v3_descriptor="${tmp}/descriptor-v3.toml"
v3_output="${tmp}/open-v3/usr/share/pocketforge/platform-capabilities.toml"
write_descriptor "${v3_descriptor}" v3
render_open "${v3_descriptor}" "${v3_output}"
cmp "${output}" "${v3_output}"

# A screen touch table derives the touch token; the derived order stays the
# runtime KNOWN_INPUTS declaration order.
touch_descriptor="${tmp}/touch.toml"
write_descriptor "${touch_descriptor}" touch
render_open "${touch_descriptor}" "${tmp}/touch.toml.out"
python3 - "${tmp}/touch.toml.out" <<'PY'
import sys
import tomllib
from pathlib import Path

parsed = tomllib.loads(Path(sys.argv[1]).read_text())
assert parsed["inputs"] == ["buttons", "dpad", "stick", "two_sticks", "touch"], parsed
assert parsed["schema_version"] == 2
PY

# A descriptor without [graphics] (the a523 shape) still renders a valid
# schema-2 contract: gles_max/vulkan_max are omitted entirely, and the runtime
# treats their absence as requirement_unverifiable (fail-closed), never as a max.
nographics_descriptor="${tmp}/no-graphics.toml"
write_descriptor "${nographics_descriptor}" no-graphics
render_open "${nographics_descriptor}" "${tmp}/no-graphics.toml.out"
python3 - "${tmp}/no-graphics.toml.out" <<'PY'
import sys
import tomllib
from pathlib import Path

parsed = tomllib.loads(Path(sys.argv[1]).read_text())
assert "gles_max" not in parsed and "vulkan_max" not in parsed, parsed
assert parsed == {
    "schema_version": 2,
    "runtime_family": "pocketforge/a133-powervr",
    "runtime_abi": "1",
    "platform_version": "20",
    "supported_capabilities": ["audio", "entropy", "input", "settings"],
    "physical_memory_mib": 970,
    "app_memory_budget_mib": 600,
    "inputs": ["buttons", "dpad", "stick", "two_sticks"],
    "display": {"width": 1280, "height": 720},
}, parsed
PY

assert_fatal() {
    if "$@" >"${tmp}/negative.log" 2>&1; then
        echo "expected platform renderer failure: $*" >&2
        exit 1
    fi
    grep -F 'FATAL:' "${tmp}/negative.log" >/dev/null
}

assert_fatal env \
    PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
    PF_APP_RUNTIME_ABI=1 \
    PF_APP_PLATFORM_VERSION=20 \
    PF_APP_CAPABILITIES= \
    "${renderer}" --soc sun50iw10p1 --gpu-model open \
    --runtime-source "${runtime_source}" --descriptor "${descriptor}" \
    --output "${tmp}/missing.toml"

assert_fatal env \
    PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
    PF_APP_RUNTIME_ABI=1 \
    PF_APP_PLATFORM_VERSION=20 \
    PF_APP_CAPABILITIES='audio unknown' \
    "${renderer}" --soc sun50iw10p1 --gpu-model open \
    --runtime-source "${runtime_source}" --descriptor "${descriptor}" \
    --output "${tmp}/unknown.toml"

assert_fatal env \
    PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
    PF_APP_RUNTIME_ABI=1 \
    PF_APP_PLATFORM_VERSION=20 \
    PF_APP_CAPABILITIES='input audio' \
    "${renderer}" --soc sun50iw10p1 --gpu-model open \
    --runtime-source "${runtime_source}" --descriptor "${descriptor}" \
    --output "${tmp}/unsorted.toml"

assert_fatal env \
    PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
    PF_APP_RUNTIME_ABI=1 \
    PF_APP_PLATFORM_VERSION=20 \
    PF_APP_CAPABILITIES='audio audio' \
    "${renderer}" --soc sun50iw10p1 --gpu-model open \
    --runtime-source "${runtime_source}" --descriptor "${descriptor}" \
    --output "${tmp}/duplicate.toml"

# Every schema-2 device fact is derived from the staged descriptor; each missing,
# malformed, or off-vocabulary fact fails closed in the same invocation as the
# positives above.
for variant in no-memory no-budget v1 v4 no-primary two-primary system-only \
    unknown-kind gles-bad vulkan-bad; do
    bad_descriptor="${tmp}/${variant}.toml"
    write_descriptor "${bad_descriptor}" "${variant}"
    assert_fatal env \
        PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
        PF_APP_RUNTIME_ABI=1 \
        PF_APP_PLATFORM_VERSION=20 \
        PF_APP_CAPABILITIES='audio entropy input settings' \
        "${renderer}" --soc sun50iw10p1 --gpu-model open \
        --runtime-source "${runtime_source}" --descriptor "${bad_descriptor}" \
        --output "${tmp}/${variant}.out"
    test ! -e "${tmp}/${variant}.out"
done

# A pinned runtime source without the Task-1 vocabularies cannot validate
# schema-2 facts: fail closed instead of hardcoding a second vocabulary copy.
assert_fatal env \
    PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
    PF_APP_RUNTIME_ABI=1 \
    PF_APP_PLATFORM_VERSION=20 \
    PF_APP_CAPABILITIES='audio entropy input settings' \
    "${renderer}" --soc sun50iw10p1 --gpu-model open \
    --runtime-source "${pre_task1_source}" --descriptor "${descriptor}" \
    --output "${tmp}/pre-task1.out"
test ! -e "${tmp}/pre-task1.out"

# A133-open without a descriptor has no device facts to derive: fatal, not a
# silent schema-1 fallback.
assert_fatal env \
    PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
    PF_APP_RUNTIME_ABI=1 \
    PF_APP_PLATFORM_VERSION=20 \
    PF_APP_CAPABILITIES='audio entropy input settings' \
    "${renderer}" --soc sun50iw10p1 --gpu-model open \
    --runtime-source "${runtime_source}" --descriptor '' \
    --output "${tmp}/no-descriptor.out"
test ! -e "${tmp}/no-descriptor.out"

# Non-open profiles accept no PF_APP_* tuple and no descriptor and produce no
# file. Supplying even one member is fatal, including on A523 with an artificial
# open GPU value.
for scope in 'sun50iw10p1 ddk' 'sun50iw10p1 none' 'sun55iw3 ddk' 'sun55iw3 open'; do
    read -r soc gpu_model <<<"${scope}"
    non_open_output="${tmp}/${soc}-${gpu_model}.toml"
    env -u PF_APP_RUNTIME_FAMILY -u PF_APP_RUNTIME_ABI \
        -u PF_APP_PLATFORM_VERSION -u PF_APP_CAPABILITIES \
        "${renderer}" --soc "${soc}" --gpu-model "${gpu_model}" \
        --runtime-source "${runtime_source}" --descriptor '' \
        --output "${non_open_output}"
    test ! -e "${non_open_output}"
    assert_fatal env PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
        "${renderer}" --soc "${soc}" --gpu-model "${gpu_model}" \
        --runtime-source "${runtime_source}" --descriptor '' \
        --output "${non_open_output}"
    assert_fatal env -u PF_APP_RUNTIME_FAMILY -u PF_APP_RUNTIME_ABI \
        -u PF_APP_PLATFORM_VERSION -u PF_APP_CAPABILITIES \
        "${renderer}" --soc "${soc}" --gpu-model "${gpu_model}" \
        --runtime-source "${runtime_source}" --descriptor "${descriptor}" \
        --output "${non_open_output}"
    test ! -e "${non_open_output}"
done

for argument in PF_APP_RUNTIME_FAMILY PF_APP_RUNTIME_ABI PF_APP_PLATFORM_VERSION PF_APP_CAPABILITIES; do
    test "$(grep -c "^ARG ${argument}=" "${dockerfile}")" -eq 1
done
grep -F 'render-platform-capabilities' "${dockerfile}" >/dev/null
# The build passes the sha-verified staged descriptor from check-device-descriptor.
grep -F -- '--descriptor "${DESCRIPTOR}"' "${dockerfile}" >/dev/null

echo 'default-app platform contract: PASS (schema-2/v3 equivalence, descriptor-derived device facts, fail-closed versions, vocabularies and scope)'
