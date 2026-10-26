#!/usr/bin/env bash
# Remove the build-transport apt proxy directives that mmdebstrap persisted
# into the assembled rootfs (bd tsp-mc9m.41.1002.5).
#
# mmdebstrap 1.5.5 permanently appends every --aptopt value to
# etc/apt/apt.conf.d/99mmdebstrap (its cleanup unlinks only 00mmdebstrap and
# 99debconf), so build-rootfs.sh's PF_APT_PROXY transport option
# 'Acquire::http::Proxy "http://<build-cache>:3142"' would otherwise ship in
# the release image. Build-6 did exactly that and first-boot cloud-config died
# on the unreachable private endpoint. This deletes proxy directive lines from
# any TEXT file under etc/apt (never hardcoded to 99mmdebstrap), keeps the
# sibling build-hardening aptopts (Check-Valid-Until, Retries, Sandbox::User)
# and the pinned snapshot.debian.org source, drops files that become empty,
# and is a byte-identical no-op on an already-clean (direct build) tree.
#
# Twin of scripts/verify-rootfs-apt-policy.sh: both MUST use the same
# PROXY_RE so the gate can never reject what this strip considered clean.
set -euo pipefail

ROOTFS="${1:?usage: strip-rootfs-apt-proxy.sh ROOTFS}"
APT_DIR="${ROOTFS}/etc/apt"

[ -d "${APT_DIR}" ] \
    || { echo "FATAL: rootfs apt strip: ${APT_DIR} is missing" >&2; exit 1; }

# apt config keys are matched case-insensitively and values may be quoted or
# unquoted (Acquire::<method>::Proxy, the per-host
# Acquire::<method>::Proxy::<host>, the shorthand <method>::Proxy, the
# block-body Proxy and suffix keys like Proxy-Auto-Detect); all reduce to a
# Proxy* key, a value and the statement's terminating semicolon, so matching
# is independent of quoting (review r4374217256).
PROXY_RE='(^|[[:space:]])([[:alnum:]_+.-]+::)*[Pp][Rr][Oo][Xx][Yy]([[:alnum:]_.-]+|::)*[[:space:]]*("[^"]*"|[^[:space:];"]+)[[:space:]]*;'

# grep -I skips binaries (trusted.gpg.d keyrings); rc=1 (no match) is the
# clean-tree fast path, rc>=2 is a real error and must not be swallowed.
rc=0
files="$(grep -rIlE "${PROXY_RE}" "${APT_DIR}")" || rc=$?
case "${rc}" in
    0) ;;
    1) echo "  rootfs apt strip: no persisted proxy directives under etc/apt"
       exit 0 ;;
    *) echo "FATAL: rootfs apt strip: grep over ${APT_DIR} failed (rc=${rc})" >&2
       exit 1 ;;
esac

removed_lines=0
removed_files=0
while IFS= read -r f; do
    [ -n "${f}" ] || continue
    n="$(grep -cIE "${PROXY_RE}" "${f}")" || n=0
    tmp="${f}.pf-apt-strip.tmp"
    sed -E "/${PROXY_RE}/d" "${f}" > "${tmp}"
    if [ -s "${tmp}" ]; then
        # Rewrite in place so ownership/mode survive (mke2fs -d preserves them).
        cat "${tmp}" > "${f}"
        rm -f -- "${tmp}"
    else
        rm -f -- "${tmp}" "${f}"
        removed_files=$(( removed_files + 1 ))
    fi
    removed_lines=$(( removed_lines + n ))
done <<< "${files}"

echo "  rootfs apt strip: removed ${removed_lines} proxy directive line(s)" \
     "(${removed_files} file(s) became empty and were dropped)"
