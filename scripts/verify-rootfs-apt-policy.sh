#!/usr/bin/env bash
# Fail-closed release gate on the assembled rootfs's apt configuration
# (bd tsp-mc9m.41.1002.5).
#
# Build-6 shipped the build-only apt proxy persisted by mmdebstrap in
# /etc/apt/apt.conf.d/99mmdebstrap; first-boot cloud-config tried to reach
# 10.0.32.86:3142, got "Network is unreachable" and cloud-config.service
# failed. This gate rejects any release rootfs whose etc/apt still carries:
#   1. an effective apt proxy key, detected with apt's OWN parser instead of
#      text matching: `apt-config dump` pointed at the rootfs tree normalizes
#      every layout apt accepts — quoted key components (Acquire::"http"::Proxy,
#      "Acquire"::http::Proxy, block-body { "Proxy" false; }, quoted suffix
#      keys such as "Proxy-Auto-Detect" and "Proxy::example.com"; review
#      r4374477053), block '}' terminators and key/value splits across lines
#      (r4374286544), unquoted values (r4374217256) — into dump lines of the
#      form 'Acquire::<method>::Proxy* "<value>";'. Any dumped key matching
#      Acquire::*Proxy* (case-insensitive) fails the build; a config
#      apt-config cannot parse, or a missing apt-config, also fails closed;
#      and
#   2. a private build endpoint: an RFC1918 10.x / 192.168.x / 172.16-31.x
#      address (the apt-cacher-ng build cache 10.0.32.86:3142 included) as
#      text anywhere under etc/apt, even without a proxy key (e.g. a
#      sources.list.d drop-in).
# The pinned snapshot.debian.org source is public and unaffected. The dump
# reads only the rootfs tree (Dir override); tests/test-rootfs-apt-policy.sh
# proves the host's /etc/apt never leaks into it.
set -euo pipefail

ROOTFS="${1:?usage: verify-rootfs-apt-policy.sh ROOTFS}"

[ -d "${ROOTFS%/}/etc/apt" ] \
    || { echo "FATAL: rootfs apt policy: ${ROOTFS%/}/etc/apt is missing" >&2; exit 1; }
# Resolve to an absolute physical path: the apt Dir override below would
# otherwise be evaluated relative to apt's own CWD.
resolved="$(cd -- "${ROOTFS%/}" && pwd -P)" \
    || { echo "FATAL: rootfs apt policy: cannot resolve ${ROOTFS}" >&2; exit 1; }
ROOTFS="${resolved}"
case "${ROOTFS}" in
    *'"'*|*'\'*)
        echo "FATAL: rootfs apt policy: path contains a quote or backslash; cannot safely embed it in apt config: ${ROOTFS}" >&2
        exit 1 ;;
esac
command -v apt-config >/dev/null 2>&1 \
    || { echo "FATAL: rootfs apt policy: apt-config is required to parse the rootfs apt config (fail closed)" >&2; exit 1; }

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-rootfs-apt-policy-gate.XXXXXX")"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

# Point apt's own parser at the rootfs tree: it then reads the rootfs's
# etc/apt/apt.conf and apt.conf.d/* parts and nothing from the host.
printf 'Dir "%s";\n' "${ROOTFS}" > "${scratch}/apt-config-env"
rc=0
dump="$(APT_CONFIG="${scratch}/apt-config-env" apt-config dump 2>"${scratch}/apt-config.err")" || rc=$?
if [ "${rc}" -ne 0 ]; then
    echo "FATAL: rootfs apt policy: apt-config could not parse the rootfs apt config (rc=${rc}):" >&2
    sed -nE '1,10{s|^|    |;p;}' "${scratch}/apt-config.err" >&2
    exit 1
fi

# Effective-key policy: anything apt would actually evaluate as a proxy.
rc=0
proxy_hits="$(printf '%s\n' "${dump}" | grep -iE '^Acquire::.*Proxy')" || rc=$?
case "${rc}" in
    0) ;;
    1) proxy_hits="" ;;
    *) echo "FATAL: rootfs apt policy: grep over the apt-config dump failed (rc=${rc})" >&2
       exit 1 ;;
esac

# Text policy on the raw tree: private build endpoints under etc/apt.
# grep -I skips binaries (trusted.gpg.d keyrings); rc=1 means clean, rc>=2 is
# a real error and must fail the build, not be swallowed.
ENDPOINT_RE='(^|[^[:alnum:].])(10(\.[0-9]{1,3}){3}|192\.168(\.[0-9]{1,3}){2}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2})([^0-9.]|$)'
cd "${ROOTFS}"
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
            echo "  persisted proxy directive(s) (effective apt-config keys):"
            printf '%s\n' "${proxy_hits}" | sed -nE '1,20{s|^|    |;p;}'
            # Best-effort attribution: name the etc/apt file(s) carrying the
            # dumped value so the build log points at the producer.
            while IFS= read -r hit; do
                value="$(printf '%s' "${hit}" | sed -nE 's/^[^"]*"([^"]*)".*$/\1/p')"
                [ -n "${value}" ] || continue
                rc=0
                src="$(grep -rIlF -m3 -- "${value}" etc/apt)" || rc=$?
                case "${rc}" in
                    0) printf '    set by: %s\n' "$(printf '%s\n' "${src}" | paste -sd, -)" ;;
                    1) printf '    (value not found verbatim under etc/apt: %s)\n' "${hit}" ;;
                    *) printf '    (attribution grep failed rc=%s for %s)\n' "${rc}" "${hit}" ;;
                esac
            done < <(printf '%s\n' "${proxy_hits}" | sed -nE '1,5p')
        fi
        if [ -n "${endpoint_hits}" ]; then
            echo "  private build endpoint(s) under etc/apt:"
            printf '%s\n' "${endpoint_hits}" | sed -nE '1,20{s|^|    |;p;}'
        fi
        echo "  (build transport belongs to PF_APT_PROXY at build time only;" \
             "see scripts/strip-rootfs-apt-proxy.sh)"
    } >&2
    exit 1
fi

echo "  rootfs apt policy: no persisted proxy directives or private build endpoints under etc/apt"
