#!/usr/bin/env bash
# CVE-2026-109518 apt gate (bd tsp-hqm1p.143).
#
# scripts/assert-apt-fixed.sh must PASS only a dpkg database whose installed
# apt is at or above its line's fixed version and whose every installed
# libapt-pkg* carries exactly that version. The stock pinned build base
# (bookworm apt 2.6.1) is the red control; a missing apt, a stale library and
# an apt line with no reviewed minimum all fail closed. Fake status trees keep
# the test hermetic.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
assert="${repo_dir}/scripts/assert-apt-fixed.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "${assert}" ] || fail "missing executable ${assert}"
command -v dpkg-query >/dev/null 2>&1 || fail "this test requires dpkg-query on the host"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-assert-apt-fixed.XXXXXX")"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

# stanza PACKAGE ARCH VERSION [STATUS]
stanza() {
    printf 'Package: %s\nStatus: %s\nArchitecture: %s\nVersion: %s\n\n' \
        "$1" "${4:-install ok installed}" "$2" "$3"
}

# make_db NAME -- reads stanzas from stdin into NAME/status
make_db() {
    local dir="${scratch}/$1"
    mkdir -p "${dir}/info" "${dir}/updates"
    cat > "${dir}/status"
    printf '%s\n' "${dir}"
}

# expect NAME RESULT REASON ADMINDIR
expect() {
    local name="$1" want="$2" reason="$3" admindir="$4" out rc=0
    out="$("${assert}" --admindir "${admindir}")" || rc=$?
    case "${want}" in
        PASS) [ "${rc}" -eq 0 ] || fail "${name}: want PASS, got rc=${rc}: ${out}" ;;
        FAIL) [ "${rc}" -eq 1 ] || fail "${name}: want FAIL rc=1, got rc=${rc}: ${out}" ;;
    esac
    case "${out}" in
        "apt_cve_2026_109518=${want} "*"reason=${reason}") ;;
        *) fail "${name}: want ${want} reason=${reason}, got: ${out}" ;;
    esac
    printf '%-22s %s\n' "${name}" "${out}"
}

base_db() {
    stanza base-files amd64 12.4+deb12u11
    stanza dpkg amd64 1.21.22
}

db="$({ base_db; stanza apt amd64 2.6.1; stanza libapt-pkg6.0 amd64 2.6.1; } | make_db red-2.6.1)"
expect red-control-2.6.1 FAIL below-minimum "${db}"

db="$({ base_db; stanza apt amd64 2.6.2; stanza libapt-pkg6.0 amd64 2.6.2; } | make_db fixed-2.6.2)"
expect fixed-2.6.2 PASS fixed "${db}"

# The rootfs gate reads an arm64 database from an amd64 host.
db="$({ base_db; stanza apt arm64 2.6.2; stanza libapt-pkg6.0 arm64 2.6.2; } | make_db fixed-2.6.2-arm64)"
expect fixed-2.6.2-arm64 PASS fixed "${db}"

db="$({ base_db; stanza apt amd64 2.6.2 'deinstall ok config-files'; stanza libapt-pkg6.0 amd64 2.6.2; } | make_db no-apt)"
expect missing-apt FAIL apt-not-installed "${db}"

db="$({ base_db; stanza apt amd64 2.6.2; stanza libapt-pkg6.0 amd64 2.6.1; } | make_db libapt-mismatch)"
expect libapt-mismatch FAIL libapt-mismatch:libapt-pkg6.0:amd64=2.6.1 "${db}"

db="$({ base_db; stanza apt amd64 2.6.2; } | make_db no-libapt)"
expect missing-libapt FAIL libapt-pkg-not-installed "${db}"

db="$({ base_db; stanza apt amd64 2.6.2; stanza libapt-pkg6.0 amd64 2.6.2 'install ok unpacked'; } | make_db libapt-unpacked)"
expect libapt-unpacked FAIL libapt-not-fully-installed:libapt-pkg6.0:amd64 "${db}"

db="$({ base_db; stanza apt amd64 2.8.3; stanza libapt-pkg6.0t64 amd64 2.8.3; } | make_db noble-2.8.3)"
expect noble-2.8.3 FAIL below-minimum "${db}"

db="$({ base_db; stanza apt amd64 2.8.4ubuntu0.1; stanza libapt-pkg6.0t64 amd64 2.8.4ubuntu0.1; } | make_db noble-fixed)"
expect noble-2.8.4ubuntu0.1 PASS fixed "${db}"

db="$({ base_db; stanza apt amd64 3.0.3; stanza libapt-pkg7.0 amd64 3.0.3; } | make_db trixie-3.0.3)"
expect trixie-3.0.3 FAIL below-minimum "${db}"

db="$({ base_db; stanza apt amd64 3.0.4; stanza libapt-pkg7.0 amd64 3.0.4; } | make_db trixie-fixed)"
expect trixie-3.0.4 PASS fixed "${db}"

db="$({ base_db; stanza apt amd64 2.7.14; stanza libapt-pkg6.0 amd64 2.7.14; } | make_db unknown-line)"
expect unknown-line-2.7.14 FAIL unknown-apt-line:2.7 "${db}"

mkdir -p "${scratch}/empty"
expect no-status FAIL "no-dpkg-status:${scratch}/empty/status" "${scratch}/empty"

rc=0
"${assert}" --bogus >/dev/null 2>&1 || rc=$?
[ "${rc}" -eq 2 ] || fail "usage error must exit 2, got ${rc}"

echo "assert-apt-fixed=PASS cases=14 red-control=2.6.1"
