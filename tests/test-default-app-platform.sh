#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renderer="${root}/scripts/render-platform-capabilities.py"
dockerfile="${root}/build/Dockerfile.pf"
tmp="$(mktemp -d)"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT

runtime_source="${tmp}/runtime"
mkdir -p "${runtime_source}/crates/pf-app-manifest/src"
printf '%s\n' \
    'pub const KNOWN_CAPABILITIES: &[&str] = &[' \
    '    "input", "vibration", "entropy", "audio", "settings",' \
    '];' \
    > "${runtime_source}/crates/pf-app-manifest/src/lib.rs"

output="${tmp}/open/usr/share/pocketforge/platform-capabilities.toml"
PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
PF_APP_RUNTIME_ABI=1 \
PF_APP_PLATFORM_VERSION=20 \
PF_APP_CAPABILITIES='audio entropy input settings' \
    "${renderer}" --soc sun50iw10p1 --gpu-model open \
    --runtime-source "${runtime_source}" --output "${output}"

python3 - "${output}" <<'PY'
import sys
import tomllib
from pathlib import Path

parsed = tomllib.loads(Path(sys.argv[1]).read_text())
assert parsed == {
    "schema_version": 1,
    "runtime_family": "pocketforge/a133-powervr",
    "runtime_abi": "1",
    "platform_version": "20",
    "supported_capabilities": ["audio", "entropy", "input", "settings"],
}
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
    --runtime-source "${runtime_source}" --output "${tmp}/missing.toml"

assert_fatal env \
    PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
    PF_APP_RUNTIME_ABI=1 \
    PF_APP_PLATFORM_VERSION=20 \
    PF_APP_CAPABILITIES='audio unknown' \
    "${renderer}" --soc sun50iw10p1 --gpu-model open \
    --runtime-source "${runtime_source}" --output "${tmp}/unknown.toml"

assert_fatal env \
    PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
    PF_APP_RUNTIME_ABI=1 \
    PF_APP_PLATFORM_VERSION=20 \
    PF_APP_CAPABILITIES='input audio' \
    "${renderer}" --soc sun50iw10p1 --gpu-model open \
    --runtime-source "${runtime_source}" --output "${tmp}/unsorted.toml"

assert_fatal env \
    PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
    PF_APP_RUNTIME_ABI=1 \
    PF_APP_PLATFORM_VERSION=20 \
    PF_APP_CAPABILITIES='audio audio' \
    "${renderer}" --soc sun50iw10p1 --gpu-model open \
    --runtime-source "${runtime_source}" --output "${tmp}/duplicate.toml"

# Non-open profiles accept no PF_APP_* tuple and produce no file. Supplying
# even one member is fatal, including on A523 with an artificial open GPU value.
for scope in 'sun50iw10p1 ddk' 'sun50iw10p1 none' 'sun55iw3 ddk' 'sun55iw3 open'; do
    read -r soc gpu_model <<<"${scope}"
    non_open_output="${tmp}/${soc}-${gpu_model}.toml"
    env -u PF_APP_RUNTIME_FAMILY -u PF_APP_RUNTIME_ABI \
        -u PF_APP_PLATFORM_VERSION -u PF_APP_CAPABILITIES \
        "${renderer}" --soc "${soc}" --gpu-model "${gpu_model}" \
        --runtime-source "${runtime_source}" --output "${non_open_output}"
    test ! -e "${non_open_output}"
    assert_fatal env PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr \
        "${renderer}" --soc "${soc}" --gpu-model "${gpu_model}" \
        --runtime-source "${runtime_source}" --output "${non_open_output}"
done

for argument in PF_APP_RUNTIME_FAMILY PF_APP_RUNTIME_ABI PF_APP_PLATFORM_VERSION PF_APP_CAPABILITIES; do
    test "$(grep -c "^ARG ${argument}=" "${dockerfile}")" -eq 1
done
grep -F 'render-platform-capabilities' "${dockerfile}" >/dev/null

echo 'default-app platform contract: PASS (exact round trip and fail-closed scope)'
