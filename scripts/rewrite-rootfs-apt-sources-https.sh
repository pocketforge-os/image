#!/usr/bin/env bash
# Persist the rootfs's snapshot.debian.org apt sources as https
# (CVE-2026-109518, bd tsp-hqm1p.143).
#
# mmdebstrap writes its mirror argument into the target's etc/apt/sources.list.
# The rootfs builders fetch over plain http only through the PF_APT_PROXY
# cache (the cache never carries https) and over https otherwise, so the
# persisted source would depend on the build transport. Rewriting the
# snapshot.debian.org scheme here makes the shipped sources identical in both
# modes and keeps on-device apt off plain http. Only that one origin is
# rewritten; verify-rootfs-apt-policy.sh rejects any other plain-http source.
# Idempotent: an https tree is left byte-identical.
set -euo pipefail

ROOTFS="${1:?usage: rewrite-rootfs-apt-sources-https.sh ROOTFS}"
apt_dir="${ROOTFS%/}/etc/apt"
[ -d "${apt_dir}" ] \
    || { echo "FATAL: rootfs apt sources: ${apt_dir} is missing" >&2; exit 1; }

rewritten=0
while IFS= read -r -d '' source_file; do
    rc=0
    grep -Fq 'http://snapshot.debian.org/' "${source_file}" || rc=$?
    case "${rc}" in
        0) ;;
        1) continue ;;
        *) echo "FATAL: rootfs apt sources: cannot read ${source_file} (grep rc=${rc})" >&2
           exit 1 ;;
    esac
    sed -i 's#http://snapshot\.debian\.org/#https://snapshot.debian.org/#g' "${source_file}"
    rewritten=$((rewritten + 1))
    echo "  rootfs apt sources: https snapshot.debian.org in ${source_file#"${ROOTFS%/}/"}"
done < <(find "${apt_dir}" \( -path "${apt_dir}/sources.list" -o -path "${apt_dir}/sources.list.d/*" \) \
    -type f -print0 | sort -z)
echo "  rootfs apt sources: rewrote ${rewritten} file(s) to https"
