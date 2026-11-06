#!/bin/sh
# Install the IME harness tools from the frozen Debian snapshot (bd tsp-hqm1p.143).
#
# usage: install-tools.sh SNAPSHOT_DATE        (run as root inside the harness image build)
#
# Policy, shared with build/Dockerfile.pf:
#   * The internet leg is https with public-CA verification. The image's CA store is copied in
#     by the Containerfile (the pinned Debian slim base has none); nothing here uses plain http.
#     A pf-public-ci runner cannot reach the NAS apt cache (10.0.0.0/8 is a pf-public deny
#     CIDR), so this step talks to snapshot.debian.org directly.
#   * CVE-2026-109518: apt 2.6.1 overflows its HTTP method on a hostile redirect whenever
#     Acquire::Retries > 0, and nothing here upgrades apt. So every apt-get runs with
#     Retries 0, and the config the image keeps says so too.
#   * apt-get update fails closed (--error-on=any): apt 2.6.1 otherwise warns and exits 0
#     when an index cannot be fetched, and the install then fails far from the cause.
#   * snapshot.debian.org serves single pool objects with 503/504 for minutes at a time and then
#     serves them again (runs 42056228740, 42154043544, 42189186714: the same RUN took 14 s,
#     105 s, failed at 72 s, and once printed nothing for 30 min; run 42196722812 and a local
#     build both lost libdbus-1-3 on every attempt for 4 min while the object answered 200 on
#     a later probe). So a fresh apt is started again and again inside a total time budget; a
#     fetch that failed fast costs seconds, packages already downloaded stay in apt's cache and
#     the indexes are fetched once. That is a retry of the whole step, not apt's own Retries.
#     Every apt run has a timeout; the budget is checked before each attempt, so the worst case
#     is the budget plus one update and one install timeout (600 + 90 + 240 s by default,
#     under the 1200 s the wrapper allows the whole image build). A failure names the step,
#     the attempt and the reason.
#
# Test seams (all optional): PF_IME_ROOT prefixes /etc and /var; PF_IME_APT_ATTEMPTS (cap),
# PF_IME_APT_BUDGET, PF_IME_APT_UPDATE_TIMEOUT, PF_IME_APT_INSTALL_TIMEOUT and PF_IME_APT_BACKOFF
# are seconds, except the attempt cap.
set -eu

snapshot=${1:-}
case "${snapshot}" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
    *) echo "ime_apt=REFUSED reason=bad_snapshot_date value=${snapshot}" >&2; exit 2 ;;
esac

root=${PF_IME_ROOT:-}
attempts=${PF_IME_APT_ATTEMPTS:-40}
budget=${PF_IME_APT_BUDGET:-600}
update_timeout=${PF_IME_APT_UPDATE_TIMEOUT:-90}
install_timeout=${PF_IME_APT_INSTALL_TIMEOUT:-240}
backoff=${PF_IME_APT_BACKOFF:-15}

# The base's own sources are plain-http deb.debian.org; the frozen snapshot replaces them.
# No bookworm-backports line: every package below is in bookworm main, backports is
# NotAutomatic (pin 100, never preferred over main), and its snapshot index was the one that
# kept answering 503/504 while bookworm, -updates and -security were served (2026-11-06,
# 20260601T000000Z and 20260602T000000Z). A suite nothing installs from only adds a way to fail.
mkdir -p "${root}/etc/apt/sources.list.d" "${root}/etc/apt/apt.conf.d"
find "${root}/etc/apt/sources.list.d" -mindepth 1 -delete
base="https://snapshot.debian.org/archive"
printf '%s\n' \
    "deb [check-valid-until=no] ${base}/debian/${snapshot}/ bookworm main" \
    "deb [check-valid-until=no] ${base}/debian/${snapshot}/ bookworm-updates main" \
    "deb [check-valid-until=no] ${base}/debian-security/${snapshot}/ bookworm-security main" \
    > "${root}/etc/apt/sources.list"
printf '%s\n' \
    'Acquire::Check-Valid-Until "false";' \
    'Acquire::Retries "0";' \
    'Acquire::http::Timeout "30";' \
    'Acquire::https::Timeout "30";' \
    > "${root}/etc/apt/apt.conf.d/99-pocketforge-snapshot"

export DEBIAN_FRONTEND=noninteractive
# apt options on every call: Retries 0 is passed explicitly, not left to the config file.
set -- -o Acquire::Retries=0 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30

# step NAME LIMIT APT-ARGS...: one bounded apt run; names the step and reason on failure.
step() {
    step_name=$1
    step_limit=$2
    shift 2
    step_rc=0
    timeout --kill-after=10 "${step_limit}" apt-get "$@" || step_rc=$?
    if [ "${step_rc}" -eq 0 ]; then
        return 0
    fi
    if [ "${step_rc}" -eq 124 ] || [ "${step_rc}" -eq 137 ]; then
        step_reason="timed out after ${step_limit}s"
    else
        step_reason="apt-get exited ${step_rc}"
    fi
    echo "ime_apt=FAIL step=${step_name} attempt=${attempt} rc=${step_rc} reason=${step_reason}" >&2
    return 1
}

started=$(date +%s)
attempt=1
updated=0
while :; do
    if [ "${updated}" -eq 1 ] || step update "${update_timeout}" "$@" update --error-on=any; then
        updated=1
        if step install "${install_timeout}" "$@" install -y --no-install-recommends \
            dbus-bin \
            dbus-daemon \
            python3 \
            python3-dbus \
            python3-gi \
            xdg-dbus-proxy; then
            break
        fi
    fi
    elapsed=$(( $(date +%s) - started ))
    if [ "${attempt}" -ge "${attempts}" ]; then
        echo "ime_apt=FAIL reason=attempts_exhausted attempts=${attempt} elapsed=${elapsed}s snapshot=${snapshot}" >&2
        exit 1
    fi
    if [ $((elapsed + backoff)) -ge "${budget}" ]; then
        echo "ime_apt=FAIL reason=budget_exhausted budget=${budget}s attempts=${attempt} elapsed=${elapsed}s snapshot=${snapshot}" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    sleep "${backoff}"
done

apt-get "$@" clean
if [ -d "${root}/var/lib/apt/lists" ]; then
    find "${root}/var/lib/apt/lists" -mindepth 1 -delete
fi
echo "ime_apt=PASS snapshot=${snapshot} attempt=${attempt} elapsed=$(( $(date +%s) - started ))s"
