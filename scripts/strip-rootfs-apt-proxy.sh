#!/usr/bin/env bash
# Remove the builder-written apt proxy line from the release rootfs
# (bd tsp-mc9m.41.1002.5).
#
# mmdebstrap 1.5.5 permanently appends every --aptopt value verbatim (adding
# a trailing ';' when missing) to etc/apt/apt.conf.d/99mmdebstrap, and its
# cleanup unlinks only 00mmdebstrap and 99debconf — so build-rootfs.sh's
# PF_APT_PROXY build transport would otherwise ship in the release image
# (Build-6 did exactly that; first-boot cloud-config died on the unreachable
# 10.0.32.86:3142). This removes exactly the line(s) the builder passes as
# PERSISTED_APTOPT_LINE arguments, by whole-line exact match against that
# known drop-in, keeping the sibling build-hardening aptopts
# (Check-Valid-Until, Retries, Sandbox::User) and the pinned
# snapshot.debian.org source. An absent line is a silent idempotent no-op; a
# drop-in consisting solely of persisted lines is deleted. Rewrites truncate
# in place, preserving inode/owner/mode for mke2fs -d.
#
# Deliberately NOT a general apt config editor: quoting/terminator variants
# kept outgrowing any line matcher (reviews r4374217256, r4374286544,
# r4374477053), so proxy config this script does not recognize is left for
# the parser-backed gate scripts/verify-rootfs-apt-policy.sh, which fails the
# build before ext4 assembly (fail closed) — the strip can never launder what
# the gate must reject.
set -euo pipefail

usage="usage: strip-rootfs-apt-proxy.sh ROOTFS [PERSISTED_APTOPT_LINE]..."
ROOTFS="${1:?${usage}}"
shift

DROP_IN="${ROOTFS%/}/etc/apt/apt.conf.d/99mmdebstrap"
removed_lines=0

for line in "$@"; do
    [ -n "${line}" ] || continue
    if [ ! -f "${DROP_IN}" ]; then
        echo "FATAL: rootfs apt strip: cannot remove the builder-persisted line; ${DROP_IN} is missing: ${line}" >&2
        exit 1
    fi
    if grep -Fxq -- "${line}" "${DROP_IN}"; then
        rc=0
        kept="$(grep -Fxv -- "${line}" "${DROP_IN}")" || rc=$?
        case "${rc}" in
            0)  printf '%s\n' "${kept}" > "${DROP_IN}" ;;
            1)  rm -f -- "${DROP_IN}" ;;   # the drop-in was only the persisted line
            *)  echo "FATAL: rootfs apt strip: grep over ${DROP_IN} failed (rc=${rc})" >&2
                exit 1 ;;
        esac
        removed_lines=$((removed_lines + 1))
    fi
done

if [ "${removed_lines}" -eq 0 ]; then
    echo "  rootfs apt strip: no builder-persisted proxy lines under etc/apt"
else
    echo "  rootfs apt strip: removed ${removed_lines} builder-persisted proxy line(s)" \
         "from etc/apt/apt.conf.d/99mmdebstrap"
fi
