#!/usr/bin/env bash
# Fail-closed gate: the dpkg database at ADMINDIR must carry an apt fixed for
# CVE-2026-109518 (bd tsp-hqm1p.143).
#
# The flaw is a heap overflow in apt's HTTP method that a hostile redirect
# reaches when Acquire::Retries > 0 (the default since apt 2.3). Fixed lines:
#   Debian bookworm  2.6.x  -> 2.6.2         (DLA-4880-1)
#   Ubuntu noble     2.8.x  -> 2.8.4ubuntu0.1
#   Debian trixie    3.0.x  -> 3.0.4
# Any other installed apt line has no reviewed minimum and fails closed. Every
# installed libapt-pkg* must carry exactly the apt version, so a fixed apt
# front end over a stale library cannot pass.
#
# Output: one line
#   apt_cve_2026_109518=PASS|FAIL version=<apt> min=<minimum> reason=<reason>
# Exit 0 on PASS, 1 on FAIL, 2 on usage error.
#
# Usage: assert-apt-fixed.sh [--admindir DIR]   (default /var/lib/dpkg)
set -euo pipefail

admindir=/var/lib/dpkg
while [ "$#" -gt 0 ]; do
    case "$1" in
        --admindir)
            [ "$#" -ge 2 ] || { echo "usage: assert-apt-fixed.sh [--admindir DIR]" >&2; exit 2; }
            admindir="$2"
            shift 2 ;;
        --admindir=*)
            admindir="${1#--admindir=}"
            shift ;;
        *)
            echo "usage: assert-apt-fixed.sh [--admindir DIR]" >&2
            exit 2 ;;
    esac
done

report() {
    echo "apt_cve_2026_109518=$1 version=$2 min=$3 reason=$4"
}

[ -s "${admindir}/status" ] \
    || { report FAIL none none "no-dpkg-status:${admindir}/status"; exit 1; }

# Query every package (no pattern: dpkg-query exits 1 when a pattern matches
# nothing) and filter here. Package and Architecture stay separate fields so a
# foreign-arch database (an arm64 rootfs read from an amd64 host) parses alike.
rc=0
packages="$(dpkg-query --admindir="${admindir}" -W \
    -f='${Package}\t${Architecture}\t${Version}\t${db:Status-Abbrev}\n' 2>/dev/null)" || rc=$?
[ "${rc}" -eq 0 ] || { report FAIL none none "dpkg-query-failed:rc=${rc}"; exit 1; }

# db:Status-Abbrev is want/status/error: installed means status 'i' with no
# error flag. 'n' (not installed) and 'c' (config files only) carry no code.
installed() {
    awk -F '\t' -v pattern="$1" '
        $1 ~ pattern {
            state = substr($4, 2, 1); err = substr($4, 3, 1)
            if (state == "n" || state == "c") next
            print $1 ":" $2 "\t" $3 "\t" ((state == "i" && (err == "" || err == " ")) ? "ok" : "bad:" $4)
        }' <<<"${packages}"
}

apt_rows="$(installed '^apt$')"
[ -n "${apt_rows}" ] || { report FAIL none none apt-not-installed; exit 1; }
[ "$(printf '%s\n' "${apt_rows}" | wc -l)" -eq 1 ] \
    || { report FAIL multiple none "multiple-apt-instances"; exit 1; }
IFS=$'\t' read -r _ version apt_state <<<"${apt_rows}"
[ "${apt_state}" = ok ] || { report FAIL "${version}" none "apt-not-fully-installed:${apt_state#bad:}"; exit 1; }

upstream="${version%%[^0-9.]*}"
line="$(printf '%s' "${upstream}" | cut -d. -f1-2)"
case "${line}" in
    2.6) min=2.6.2 ;;
    2.8) min=2.8.4ubuntu0.1 ;;
    3.0) min=3.0.4 ;;
    *) report FAIL "${version}" none "unknown-apt-line:${line:-none}"; exit 1 ;;
esac
dpkg --compare-versions "${version}" ge "${min}" \
    || { report FAIL "${version}" "${min}" below-minimum; exit 1; }

lib_rows="$(installed '^libapt-pkg')"
[ -n "${lib_rows}" ] || { report FAIL "${version}" "${min}" libapt-pkg-not-installed; exit 1; }
while IFS=$'\t' read -r lib lib_version lib_state; do
    [ "${lib_state}" = ok ] \
        || { report FAIL "${version}" "${min}" "libapt-not-fully-installed:${lib}"; exit 1; }
    [ "${lib_version}" = "${version}" ] \
        || { report FAIL "${version}" "${min}" "libapt-mismatch:${lib}=${lib_version}"; exit 1; }
done <<<"${lib_rows}"

report PASS "${version}" "${min}" fixed
