#!/usr/bin/env bash
# Contract test for the browser platform defaults (bd tsp-be9lx):
#   - /etc/machine-info CHASSIS=handset (A133 and A523 images)
#   - systemd-resolved DNSOverTLS=opportunistic
#   - pf-app@.service per-app cache dir (XDG_CACHE_HOME + CacheDirectory +
#     ReadWritePaths)
#   - /usr/share/applications/pocketforge-mimeapps.list default browser files
#   - systemd-coredump ProcessSizeMax/ExternalSizeMax capped at <= 64 MiB
#
# Hermetic: fixture rootfs trees in a tmpdir seeded from the REAL repo overlay
# files, so a content regression in rootfs-overlay turns this test red, not
# just a verifier-logic regression. Every check has a positive control and a
# seeded-regression negative control in the same invocation.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="${root}/scripts/verify-rootfs-browser-defaults.sh"
overlay="${root}/rootfs-overlay"
app_unit_src="${overlay}/etc/systemd/system/pf-app@.service"
rootfs_builder="${root}/scripts/build-rootfs.sh"
a523_customize="${root}/boards/tsp-s/rootfs-customize.sh"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/browser-platform-defaults.XXXXXX")"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Seed one fixture rootfs from the committed overlay sources.
seed_rootfs() {
    local r="$1"
    mkdir -p "${r}/etc/systemd/resolved.conf.d" "${r}/etc/systemd/coredump.conf.d" \
        "${r}/etc/systemd/system" "${r}/usr/share/applications"
    cp "${overlay}/etc/machine-info" "${r}/etc/machine-info"
    cp "${overlay}/etc/systemd/resolved.conf.d/pocketforge.conf" \
        "${r}/etc/systemd/resolved.conf.d/pocketforge.conf"
    cp "${overlay}/etc/systemd/coredump.conf.d/pocketforge.conf" \
        "${r}/etc/systemd/coredump.conf.d/pocketforge.conf"
    cp "${overlay}/usr/share/applications/pocketforge-mimeapps.list" \
        "${r}/usr/share/applications/pocketforge-mimeapps.list"
    cp "${app_unit_src}" "${r}/etc/systemd/system/pf-app@.service"
}

# The verifier must reject a seeded regression naming the expected reason.
expect_reject() {
    local r="$1" want="$2"; shift 2
    local log="${r}.reject.log"
    if "${verifier}" "${r}" "$@" >"${log}" 2>&1; then
        echo "FAIL: verifier accepted a seeded regression in ${r} (wanted reason: ${want})" >&2
        exit 1
    fi
    grep -Fq -- "${want}" "${log}" || {
        echo "FAIL: rejection of ${r} did not report '${want}':" >&2
        cat "${log}" >&2
        exit 1
    }
}

# --- overlay source content ---------------------------------------------------
grep -Fxq 'CHASSIS=handset' "${overlay}/etc/machine-info" \
    || fail "rootfs-overlay/etc/machine-info must set CHASSIS=handset"
grep -Fxq 'DNSOverTLS=opportunistic' \
    "${overlay}/etc/systemd/resolved.conf.d/pocketforge.conf" \
    || fail "resolved drop-in must set DNSOverTLS=opportunistic"
grep -Fxq 'ProcessSizeMax=64M' \
    "${overlay}/etc/systemd/coredump.conf.d/pocketforge.conf" \
    || fail "coredump drop-in must set ProcessSizeMax=64M"
grep -Fxq 'ExternalSizeMax=64M' \
    "${overlay}/etc/systemd/coredump.conf.d/pocketforge.conf" \
    || fail "coredump drop-in must set ExternalSizeMax=64M"
grep -Fxq 'x-scheme-handler/http=pocketforge-browser.desktop' \
    "${overlay}/usr/share/applications/pocketforge-mimeapps.list" \
    || fail "mimeapps.list must name pocketforge-browser.desktop for http"
grep -Fxq 'x-scheme-handler/https=pocketforge-browser.desktop' \
    "${overlay}/usr/share/applications/pocketforge-mimeapps.list" \
    || fail "mimeapps.list must name pocketforge-browser.desktop for https"

# --- build wiring -------------------------------------------------------------
grep -Fq 'rootfs-overlay/etc/machine-info' "${rootfs_builder}" \
    || fail "build-rootfs.sh must install /etc/machine-info from the overlay"
grep -Fq 'rootfs-overlay/etc/systemd/coredump.conf.d/pocketforge.conf' "${rootfs_builder}" \
    || fail "build-rootfs.sh must install the coredump drop-in from the overlay"
grep -Fq 'rootfs-overlay/usr/share/applications/pocketforge-mimeapps.list' "${rootfs_builder}" \
    || fail "build-rootfs.sh must install pocketforge-mimeapps.list from the overlay"
grep -Fq 'scripts/verify-rootfs-browser-defaults.sh' "${rootfs_builder}" \
    || fail "build-rootfs.sh must run verify-rootfs-browser-defaults.sh on the extracted rootfs"
grep -Fq -- '--expect-pf-app' "${rootfs_builder}" \
    || fail "build-rootfs.sh must require the pf-app@ cache wiring on open profiles"
grep -Fq 'rootfs-overlay/etc/machine-info' "${a523_customize}" \
    || fail "boards/tsp-s/rootfs-customize.sh must install /etc/machine-info (A523 image)"

# --- positive control ---------------------------------------------------------
good="${tmp}/good"
seed_rootfs "${good}"
"${verifier}" "${good}" --expect-pf-app
"${verifier}" "${good}"

# A non-open profile has no pf-app@.service; that is accepted without the flag.
noapp="${tmp}/noapp"
seed_rootfs "${noapp}"
find "${noapp}/etc/systemd/system" -mindepth 1 -delete
"${verifier}" "${noapp}"

# --- negative controls: chassis -----------------------------------------------
missing="${tmp}/neg-missing-machine-info"
seed_rootfs "${missing}"
find "${missing}/etc/machine-info" -delete
expect_reject "${missing}" '/etc/machine-info is missing' --expect-pf-app

wrong="${tmp}/neg-chassis-desktop"
seed_rootfs "${wrong}"
printf 'CHASSIS=desktop\n' > "${wrong}/etc/machine-info"
expect_reject "${wrong}" 'CHASSIS=handset' --expect-pf-app

# --- negative controls: DNS-over-TLS -------------------------------------------
nodot="${tmp}/neg-no-dot"
seed_rootfs "${nodot}"
grep -v '^DNSOverTLS=' "${nodot}/etc/systemd/resolved.conf.d/pocketforge.conf" \
    > "${nodot}/resolved.tmp"
mv "${nodot}/resolved.tmp" "${nodot}/etc/systemd/resolved.conf.d/pocketforge.conf"
expect_reject "${nodot}" 'DNSOverTLS=opportunistic' --expect-pf-app

dotstrict="${tmp}/neg-dot-strict"
seed_rootfs "${dotstrict}"
printf '[Resolve]\nDNSOverTLS=yes\n' \
    > "${dotstrict}/etc/systemd/resolved.conf.d/pocketforge.conf"
expect_reject "${dotstrict}" 'DNSOverTLS=opportunistic' --expect-pf-app

# --- negative controls: coredump size cap --------------------------------------
nocap="${tmp}/neg-coredump-absent"
seed_rootfs "${nocap}"
find "${nocap}/etc/systemd/coredump.conf.d" -mindepth 1 -delete
# Unset means systemd's multi-gigabyte default: a web-process crash could fill
# the card, so the verifier must reject the no-configuration state too.
expect_reject "${nocap}" 'ProcessSizeMax' --expect-pf-app

raised="${tmp}/neg-coredump-raised"
seed_rootfs "${raised}"
printf '[Coredump]\nProcessSizeMax=64M\nExternalSizeMax=2G\n' \
    > "${raised}/etc/systemd/coredump.conf.d/pocketforge.conf"
expect_reject "${raised}" 'ExternalSizeMax' --expect-pf-app

laterdropin="${tmp}/neg-coredump-later-dropin"
seed_rootfs "${laterdropin}"
printf '[Coredump]\nProcessSizeMax=infinity\n' \
    > "${laterdropin}/etc/systemd/coredump.conf.d/zz-later.conf"
expect_reject "${laterdropin}" 'ProcessSizeMax' --expect-pf-app

# An exactly-64MiB cap expressed differently must still pass (positive control
# for the size parser, same run).
kibi="${tmp}/pos-coredump-kib"
seed_rootfs "${kibi}"
printf '[Coredump]\nProcessSizeMax=65536K\nExternalSizeMax=67108864\n' \
    > "${kibi}/etc/systemd/coredump.conf.d/pocketforge.conf"
"${verifier}" "${kibi}" --expect-pf-app

# --- negative controls: default browser files ----------------------------------
nomime="${tmp}/neg-mimeapps-missing"
seed_rootfs "${nomime}"
find "${nomime}/usr/share/applications/pocketforge-mimeapps.list" -delete
expect_reject "${nomime}" 'pocketforge-mimeapps.list is missing' --expect-pf-app

wronghandler="${tmp}/neg-mimeapps-wrong-handler"
seed_rootfs "${wronghandler}"
printf '[Default Applications]\nx-scheme-handler/http=pocketforge-browser.desktop\nx-scheme-handler/https=firefox.desktop\n' \
    > "${wronghandler}/usr/share/applications/pocketforge-mimeapps.list"
expect_reject "${wronghandler}" 'x-scheme-handler/https' --expect-pf-app

# --- negative controls: pf-app@ per-app cache ----------------------------------
nounit="${tmp}/neg-pf-app-missing"
seed_rootfs "${nounit}"
find "${nounit}/etc/systemd/system/pf-app@.service" -delete
expect_reject "${nounit}" 'pf-app@.service is missing' --expect-pf-app

noenv="${tmp}/neg-pf-app-no-cache-env"
seed_rootfs "${noenv}"
grep -v '^Environment=XDG_CACHE_HOME=' "${noenv}/etc/systemd/system/pf-app@.service" \
    > "${noenv}/unit.tmp"
mv "${noenv}/unit.tmp" "${noenv}/etc/systemd/system/pf-app@.service"
expect_reject "${noenv}" 'XDG_CACHE_HOME=/var/cache/pocketforge/apps/%i' --expect-pf-app

nocachedir="${tmp}/neg-pf-app-no-cachedirectory"
seed_rootfs "${nocachedir}"
grep -v '^CacheDirectory=' "${nocachedir}/etc/systemd/system/pf-app@.service" \
    > "${nocachedir}/unit.tmp"
mv "${nocachedir}/unit.tmp" "${nocachedir}/etc/systemd/system/pf-app@.service"
expect_reject "${nocachedir}" 'CacheDirectory=pocketforge/apps/%i' --expect-pf-app

norwp="${tmp}/neg-pf-app-no-rwp"
seed_rootfs "${norwp}"
sed 's|^ReadWritePaths=.*$|ReadWritePaths=/var/lib/pocketforge/apps/%i|' \
    "${norwp}/etc/systemd/system/pf-app@.service" > "${norwp}/unit.tmp"
mv "${norwp}/unit.tmp" "${norwp}/etc/systemd/system/pf-app@.service"
expect_reject "${norwp}" 'ReadWritePaths' --expect-pf-app

# The unit content is validated even without --expect-pf-app when it is present.
silent="${tmp}/neg-pf-app-broken-without-flag"
seed_rootfs "${silent}"
grep -v '^Environment=XDG_CACHE_HOME=' "${silent}/etc/systemd/system/pf-app@.service" \
    > "${silent}/unit.tmp"
mv "${silent}/unit.tmp" "${silent}/etc/systemd/system/pf-app@.service"
expect_reject "${silent}" 'XDG_CACHE_HOME=/var/cache/pocketforge/apps/%i'

echo 'browser-platform-defaults-test=PASS'
