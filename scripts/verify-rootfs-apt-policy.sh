#!/usr/bin/env bash
# Fail-closed release gate on the assembled rootfs's apt configuration
# (bd tsp-mc9m.41.1002.5).
#
# Build-6 shipped the build-only apt proxy persisted by mmdebstrap in
# /etc/apt/apt.conf.d/99mmdebstrap; first-boot cloud-config tried to reach
# 10.0.32.86:3142, got "Network is unreachable" and cloud-config.service
# failed. This gate rejects any release rootfs whose etc/apt still carries:
#   1. an apt proxy directive (Acquire::<method>::Proxy, the shorthand
#      <method>::Proxy or a block-body Proxy) in ANY file, regardless of
#      value quoting or terminator: apt accepts ';', a block's '}' and
#      values continued on the line after the key (review r4374286544,
#      confirmed with apt-config dump), so the matcher keys on the Proxy*
#      token itself and the policy is not hardcoded to 99mmdebstrap; or
#   2. a private build endpoint: an RFC1918 10.x / 192.168.x / 172.16-31.x
#      address (the apt-cacher-ng build cache 10.0.32.86:3142 included),
#      even without a Proxy directive (e.g. a sources.list.d drop-in).
# The pinned snapshot.debian.org source is public and unaffected.
#
# Twin of scripts/strip-rootfs-apt-proxy.sh: both MUST use the same PROXY_RE.
set -euo pipefail

ROOTFS="${1:?usage: verify-rootfs-apt-policy.sh ROOTFS}"
APT_DIR="${ROOTFS}/etc/apt"

[ -d "${APT_DIR}" ] \
    || { echo "FATAL: rootfs apt policy: ${APT_DIR} is missing" >&2; exit 1; }

# Token-boundary matcher: any Proxy* key as its own config token (left
# boundary start-of-line/whitespace/'{', right boundary end-of-line/
# whitespace/';'/'}'/quote). Value shape and terminator are deliberately NOT
# required — fail closed on every form apt can parse. MUST stay equivalent
# to the strip twin's discovery regex and its python3 TOKEN.
PROXY_RE='(^|[[:space:]{])([[:alnum:]_+.-]+::)*[Pp][Rr][Oo][Xx][Yy]([[:alnum:]_.-]+|::)*($|[[:space:];}"])'
ENDPOINT_RE='(^|[^[:alnum:].])(10(\.[0-9]{1,3}){3}|192\.168(\.[0-9]{1,3}){2}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2})([^0-9.]|$)'

# Relative paths in the report (etc/apt/...) by grepping from the rootfs root.
cd "${ROOTFS}"

# grep -I skips binaries (trusted.gpg.d keyrings); rc=1 means clean, rc>=2 is
# a real error and must fail the build, not be swallowed.
rc=0
proxy_hits="$(grep -rInE "${PROXY_RE}" etc/apt)" || rc=$?
case "${rc}" in
    0) ;;
    1) proxy_hits="" ;;
    *) echo "FATAL: rootfs apt policy: proxy grep over etc/apt failed (rc=${rc})" >&2
       exit 1 ;;
esac
rc=0
endpoint_hits="$(grep -rInE "${ENDPOINT_RE}" etc/apt)" || rc=$?
case "${rc}" in
    0) ;;
    1) endpoint_hits="" ;;
    *) echo "FATAL: rootfs apt policy: endpoint grep over etc/apt failed (rc=${rc})" >&2
       exit 1 ;;
esac

if [ -n "${proxy_hits}" ] || [ -n "${endpoint_hits}" ]; then
    {
        echo "FATAL: rootfs apt policy: release rootfs must not persist build-only apt configuration"
        if [ -n "${proxy_hits}" ]; then
            echo "  persisted proxy directive(s):"
            printf '%s\n' "${proxy_hits}" | sed -nE '1,20{s|^|    |;p;}'
        fi
        if [ -n "${endpoint_hits}" ]; then
            echo "  private build endpoint(s):"
            printf '%s\n' "${endpoint_hits}" | sed -nE '1,20{s|^|    |;p;}'
        fi
        echo "  (build transport belongs to PF_APT_PROXY at build time only;" \
             "see scripts/strip-rootfs-apt-proxy.sh)"
    } >&2
    exit 1
fi

echo "  rootfs apt policy: no persisted proxy directives or private build endpoints under etc/apt"
