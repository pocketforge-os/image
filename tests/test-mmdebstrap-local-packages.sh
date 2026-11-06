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
apt_deb="${fixture}/apt-fix/apt_2.6.2_arm64.deb"
libapt_deb="${fixture}/apt-fix/libapt-pkg6.0_2.6.2_arm64.deb"
argv="${hook}.argv"
snapshot_path="snapshot.debian.org/archive/debian/$(cat "${repo_dir}/snapshot-date.txt")/"

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
    # CVE-2026-109518 (bd tsp-hqm1p.143): the fixed apt pair enters the same
    # initial solve as two more distinct local paths.
    if [ "$(count_exact "${path}" "--include=${apt_deb}")" -ne 1 ] \
        || [ "$(count_exact "${path}" "--include=${libapt_deb}")" -ne 1 ]; then
        echo "FAIL: the fixed apt/libapt-pkg6.0 debs did not reach mmdebstrap as distinct --include paths" >&2
        return 1
    fi
}

# assert_transport ARGV SCHEME PROXY_ARGS -- the mirror (mmdebstrap's last
# argument) uses SCHEME and exactly PROXY_ARGS proxy --aptopt arguments appear.
assert_transport() {
    local path="$1" scheme="$2" want_proxy="$3" got_proxy
    if [ "$(tail -n 1 "${path}")" != "${scheme}://${snapshot_path}" ]; then
        echo "FAIL: mirror is '$(tail -n 1 "${path}")', want ${scheme}://${snapshot_path}" >&2
        return 1
    fi
    got_proxy="$(grep -c -- '^--aptopt=Acquire::http::Proxy ' "${path}" || true)"
    if [ "${got_proxy}" -ne "${want_proxy}" ]; then
        echo "FAIL: ${got_proxy} proxy --aptopt arguments, want ${want_proxy}" >&2
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

# Direct transport: https mirror, no proxy (CVE-2026-109518, bd tsp-hqm1p.143).
assert_transport "${argv}" https 0

# Cache transport: plain http through the cache, which never carries https.
cache_hook="${scratch}/cache/customize-hook.sh"
mkdir -p "${scratch}/cache"
PF_APT_PROXY=http://10.0.32.86:3142 \
    capture_customize_hook "${repo_dir}" "${scratch}/cache-fixture" "${cache_hook}"
assert_transport "${cache_hook}.argv" http 1
if assert_transport "${cache_hook}.argv" https 1 2>/dev/null; then
    echo "FAIL: cache-mode argv passed the direct-mode https transport check" >&2
    exit 1
fi

# Negative control: a missing fixed apt deb stops the build before mmdebstrap.
mkdir -p "${scratch}/partial-apt-fix"
: > "${scratch}/partial-apt-fix/apt_2.6.2_arm64.deb"
if PF_APT_FIX_DIR="${scratch}/partial-apt-fix" \
    capture_customize_hook "${repo_dir}" "${scratch}/missing-fixture" "${scratch}/missing-hook.sh" 2>/dev/null; then
    echo "FAIL: build-rootfs.sh reached mmdebstrap without libapt-pkg6.0_2.6.2_arm64.deb" >&2
    exit 1
fi
grep -Fq "FATAL: CVE-2026-109518 fixed apt package is missing: ${scratch}/partial-apt-fix/libapt-pkg6.0_2.6.2_arm64.deb" \
    "${scratch}/missing-fixture/build-rootfs.err" \
    || { echo "FAIL: missing fixed apt deb did not fail closed by name" >&2; exit 1; }
[ ! -e "${scratch}/missing-hook.sh.argv" ] \
    || { echo "FAIL: mmdebstrap ran without the fixed apt deb" >&2; exit 1; }

echo "mmdebstrap-local-packages=PASS positive=real-builder-four-distinct-includes,https-direct-mirror,http-cache-mirror negative=comma-joined-local-paths,missing-fixed-apt-deb"
