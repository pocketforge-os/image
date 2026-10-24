#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="${root}/build/platform-runtimes/steamlink-ffmpeg59/v1/build.sh"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/steamlink-ffmpeg59-normalizer.XXXXXX")"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

# Execute the producer's real normalizer without running its cross-build. Keep
# the extraction anchored to the complete shell function so implementation and
# test cannot silently drift into separate normalization rules.
awk '
    /^normalize_config_log\(\) \{$/ { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' "${builder}" > "${scratch}/normalizer.sh"
grep -Fxq 'normalize_config_log() {' "${scratch}/normalizer.sh"
grep -Fxq '}' "${scratch}/normalizer.sh"
# shellcheck disable=SC1091
. "${scratch}/normalizer.sh"

# Consumed by the sourced normalize_config_log function.
# shellcheck disable=SC2034
work=/work/pf-steamlink-ffmpeg59-v1
write_fixture() {
    local output=$1
    local ppid=$2
    local arch=$3
    mkdir -p "${output}/reports"
    cat > "${output}/input.log" <<EOF
BEGIN /work/pf-steamlink-ffmpeg59-v1/ffbuild/config.log
PPID='${ppid}'
ARCH='${arch}'
PPID='701' trailing-control
XPPID='702'
configure_result='enabled'
EOF
    normalize_config_log "${output}/input.log" > "${output}/reports/config.log"
    (
        cd "${output}"
        sha256sum reports/config.log > manifest.sha256
    )
}

write_fixture "${scratch}/one" 623 aarch64
write_fixture "${scratch}/two" 624 aarch64
write_fixture "${scratch}/negative" 625 arm64

# Positive control: a runner-specific exact PPID assignment cannot affect the
# installed report or the manifest that authenticates it.
cmp "${scratch}/one/reports/config.log" "${scratch}/two/reports/config.log"
cmp "${scratch}/one/manifest.sha256" "${scratch}/two/manifest.sha256"

# Negative control in the same invocation: stable configure state remains
# observable, as do near-matches that are not an exact decimal PPID assignment.
if cmp -s "${scratch}/one/reports/config.log" "${scratch}/negative/reports/config.log"; then
    echo 'FAIL: substantive configure difference was normalized away' >&2
    exit 1
fi
if cmp -s "${scratch}/one/manifest.sha256" "${scratch}/negative/manifest.sha256"; then
    echo 'FAIL: manifest hid substantive configure difference' >&2
    exit 1
fi
grep -Fxq "ARCH='aarch64'" "${scratch}/one/reports/config.log"
grep -Fxq "ARCH='arm64'" "${scratch}/negative/reports/config.log"
grep -Fxq "PPID='701' trailing-control" "${scratch}/one/reports/config.log"
grep -Fxq "XPPID='702'" "${scratch}/one/reports/config.log"

echo 'PASS: steamlink FFmpeg config PPID normalization is deterministic and narrow'
