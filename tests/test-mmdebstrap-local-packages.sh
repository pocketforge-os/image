#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/capture-customize-hook.sh
source "${repo_dir}/tests/lib/capture-customize-hook.sh"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-mmdebstrap-local-packages.XXXXXX")"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

fixture="${scratch}/fixture"
hook="${scratch}/customize-hook.sh"
capture_customize_hook "${repo_dir}" "${fixture}" "${hook}"

cloud_deb="${fixture}/cloud-init/cloud-init-pocketforge.deb"
gpu_deb="${fixture}/mesa/pocketforge-open-gpu-stack.deb"
argv="${hook}.argv"

count_exact() {
    local path="$1"
    local expected="$2"
    awk -v expected="${expected}" '$0 == expected { count++ } END { print count + 0 }' "${path}"
}

assert_distinct_local_debs() {
    local path="$1"
    if [ "$(count_exact "${path}" "--include=${cloud_deb}")" -ne 1 ]; then
        echo "FAIL: cloud-init local package did not reach mmdebstrap as its own --include path" >&2
        return 1
    fi
    if [ "$(count_exact "${path}" "--include=${gpu_deb}")" -ne 1 ]; then
        echo "FAIL: open-GPU local package did not reach mmdebstrap as its own --include path" >&2
        return 1
    fi
    if [ "$(count_exact "${path}" "--include=${cloud_deb},${gpu_deb}")" -ne 0 ]; then
        echo "FAIL: local package paths were comma-joined into one mmdebstrap argument" >&2
        return 1
    fi
}

# Positive control: capture the exact argv produced by scripts/build-rootfs.sh.
assert_distinct_local_debs "${argv}"

# Negative control: the image#203 comma-joined shape must fail in this invocation.
bad_argv="${scratch}/comma-joined.argv"
awk -v cloud="--include=${cloud_deb}" -v gpu="--include=${gpu_deb}" '
    $0 == cloud { next }
    $0 == gpu { print cloud "," substr(gpu, length("--include=") + 1); next }
    { print }
' "${argv}" > "${bad_argv}"
if assert_distinct_local_debs "${bad_argv}" 2>/dev/null; then
    echo "FAIL: comma-joined local-package negative was accepted" >&2
    exit 1
fi

echo "mmdebstrap-local-packages=PASS positive=real-builder-two-distinct-includes negative=comma-joined-local-paths"
