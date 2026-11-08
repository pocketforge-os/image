#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
distribution=
architecture=
snapshot=
output=
overlay=
mode=unshare
preflight_only=false
systemd_resolved_stub=false
packages=(ca-certificates libc6 libgcc-s1 libstdc++6)

usage() {
    echo "usage: $0 --preflight-only | --distribution debian-12|debian-13 --architecture arm64 --snapshot YYYYMMDDTHHMMSSZ [--mode root|unshare|fakechroot] [--package NAME]... [--overlay DIR] [--systemd-resolved-stub] --output DIR" >&2
    exit 64
}

preflight_tools() {
    local tool
    for tool in awk basename cp dirname find grep mkdir mktemp mmdebstrap mksquashfs mv paste \
                python3 rmdir sha256sum sort tar touch xargs; do
        command -v "${tool}" >/dev/null || {
            echo "app-root build: required tool unavailable: ${tool}" >&2
            exit 69
        }
    done
}

while (($#)); do
    case "$1" in
        --distribution) distribution=${2-}; shift 2 ;;
        --architecture) architecture=${2-}; shift 2 ;;
        --snapshot) snapshot=${2-}; shift 2 ;;
        --mode) mode=${2-}; shift 2 ;;
        --preflight-only) preflight_only=true; shift ;;
        --package) packages+=("${2-}"); shift 2 ;;
        --overlay) overlay=${2-}; shift 2 ;;
        --systemd-resolved-stub) systemd_resolved_stub=true; shift ;;
        --output) output=${2-}; shift 2 ;;
        *) usage ;;
    esac
done

if [[ "${preflight_only}" == true ]]; then
    preflight_tools
    echo "app-root-preflight=PASS"
    exit 0
fi

case "${distribution}" in
    debian-12) suite=bookworm ;;
    debian-13) suite=trixie ;;
    *) echo "app-root build: unsupported distribution: ${distribution:-<empty>}" >&2; exit 64 ;;
esac
[[ "${architecture}" == arm64 ]] || {
    echo "app-root build: unsupported architecture: ${architecture:-<empty>}" >&2
    exit 64
}
case "${mode}" in
    root|unshare|fakechroot) ;;
    *) echo "app-root build: unsupported mode: ${mode}" >&2; exit 64 ;;
esac
[[ "${snapshot}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || {
    echo "app-root build: invalid snapshot: ${snapshot:-<empty>}" >&2
    exit 64
}
[[ -n "${output}" ]] || usage
for package in "${packages[@]}"; do
    [[ "${package}" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || {
        echo "app-root build: invalid package name: ${package}" >&2
        exit 64
    }
done
if [[ -n "${overlay}" ]]; then
    [[ -d "${overlay}" && ! -L "${overlay}" ]] || {
        echo "app-root build: overlay is not a real directory: ${overlay}" >&2
        exit 66
    }
    if find "${overlay}" -mindepth 1 \( -type l -o ! -type d ! -type f \) -print -quit | grep -q .; then
        echo "app-root build: overlay contains a link or special file" >&2
        exit 65
    fi
fi
preflight_tools
[[ ! -e "${output}" ]] || {
    echo "app-root build: output already exists: ${output}" >&2
    exit 73
}

output_parent=$(dirname "${output}")
output_name=$(basename "${output}")
mkdir -p "${output_parent}"
stage=$(mktemp -d "${output_parent}/.${output_name}.XXXXXX")
cleanup() {
    if [[ -d "${stage}" ]]; then
        find "${stage}" -mindepth 1 -delete
        rmdir "${stage}"
    fi
}
trap cleanup EXIT INT TERM

package_csv=$(printf '%s\n' "${packages[@]}" | LC_ALL=C sort -u | paste -sd, -)
# Fetch transport (CVE-2026-109518, bd tsp-hqm1p.143). apt sends an https source through
# $http_proxy as a CONNECT tunnel (measured: apt 2.8.4 -> "CONNECT snapshot.debian.org:443"),
# which the NAS apt-cacher-ng lets through for the Debian hosts but cannot cache. An https
# mirror here therefore bypassed the cache and every build paid snapshot.debian.org's
# cold-object 504s directly (owned-image-build 42215946514: 18 min, then 9 packages failed).
# With the cache (http_proxy set) the source is plain http to the cache, which fetches the same
# immutable snapshot path upstream over verified https (nas/apt-cacher-ng/acng.conf); without
# it the source is https direct. apt verifies every byte against the signed snapshot index in
# both modes, and the persisted sources are rewritten to https below, so the root bytes do not
# depend on the transport.
if [[ -n "${http_proxy:-}" ]]; then
    mirror_scheme=http
else
    mirror_scheme=https
fi
mirror="${mirror_scheme}://snapshot.debian.org/archive/debian/${snapshot}/"
# apt retries by default (Acquire::Retries 3), and with the default retry delay apt 2.6 can
# stop for good in its update once one index fails transiently while another on the same
# host succeeds (LP #2003851, tsp-hqm1p.142): the delay is off, the retries stay.
mmdebstrap \
    --mode="${mode}" \
    --variant=minbase \
    --architectures="${architecture}" \
    --format=tar \
    --include="${package_csv}" \
    --aptopt='Acquire::Check-Valid-Until "false";' \
    --aptopt='Acquire::Retries::Delay "false";' \
    "${suite}" "${stage}/rootfs.tar" "${mirror}"

mkdir "${stage}/rootfs"
tar -xf "${stage}/rootfs.tar" -C "${stage}/rootfs" \
    --no-same-owner --exclude='./dev/*'
mkdir -p "${stage}/rootfs/dev"
# mmdebstrap wrote the mirror it was given into the root's apt sources: make them https in
# both transports (idempotent on a tree that is already https), then refuse any plain-http
# source so a cached build cannot ship the cache's scheme.
"${script_dir}/rewrite-rootfs-apt-sources-https.sh" "${stage}/rootfs"
if grep -rqE '^[^#]*(deb|URIs:).*http://' "${stage}/rootfs/etc/apt/sources.list" \
        "${stage}/rootfs/etc/apt/sources.list.d" 2>/dev/null; then
    echo "app-root build: a plain-http apt source survived in the root" >&2
    exit 65
fi
os_release="${stage}/rootfs/etc/os-release"
[[ -f "${os_release}" ]] || {
    echo "app-root build: mmdebstrap output has no /etc/os-release" >&2
    exit 65
}
grep -Fqx "VERSION_CODENAME=${suite}" "${os_release}" || {
    echo "app-root build: mmdebstrap suite identity is not ${suite}" >&2
    exit 65
}
if [[ -n "${overlay}" ]]; then
    while IFS= read -r -d '' source; do
        relative=${source#"${overlay}/"}
        [[ ! -e "${stage}/rootfs/${relative}" && ! -L "${stage}/rootfs/${relative}" ]] || {
            echo "app-root build: overlay file collides with base root: ${relative}" >&2
            exit 65
        }
    done < <(find "${overlay}" -type f -print0)
    cp -a "${overlay}/." "${stage}/rootfs/"
fi

if [[ "${systemd_resolved_stub}" == true ]]; then
    # RootImage services with PrivateNetwork=no share the base image's network
    # namespace, including systemd-resolved's loopback stub. Never preserve
    # mmdebstrap's build-host resolver in the immutable runtime root.
    rm -f "${stage}/rootfs/etc/resolv.conf"
    printf 'nameserver 127.0.0.53\n' >"${stage}/rootfs/etc/resolv.conf"
    chmod 0644 "${stage}/rootfs/etc/resolv.conf"
fi

find "${stage}/rootfs" -print0 | LC_ALL=C sort -z | xargs -0 touch -h --date='@0'
env -u SOURCE_DATE_EPOCH mksquashfs "${stage}/rootfs" "${stage}/root.raw" \
    -noappend -all-root -no-xattrs -all-time 0 -mkfs-time 0 \
    -comp zstd -Xcompression-level 15 -processors 1 -no-progress >/dev/null
root_sha=$(sha256sum "${stage}/root.raw" | awk '{print $1}')

PF_ROOT_DISTRIBUTION="${distribution}" \
PF_ROOT_SUITE="${suite}" \
PF_ROOT_ARCHITECTURE="${architecture}" \
PF_ROOT_SNAPSHOT="${snapshot}" \
PF_ROOT_MODE="${mode}" \
PF_ROOT_PACKAGES="${package_csv}" \
PF_ROOT_SHA256="${root_sha}" \
python3 - "${stage}/root.metadata.json" <<'PY'
import json
import os
import sys

value = {
    "schema_version": 1,
    "distribution": os.environ["PF_ROOT_DISTRIBUTION"],
    "suite": os.environ["PF_ROOT_SUITE"],
    "architecture": os.environ["PF_ROOT_ARCHITECTURE"],
    "snapshot": os.environ["PF_ROOT_SNAPSHOT"],
    "builder_mode": os.environ["PF_ROOT_MODE"],
    "packages": os.environ["PF_ROOT_PACKAGES"].split(","),
    "sha256": os.environ["PF_ROOT_SHA256"],
}
with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as handle:
    json.dump(value, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY

find "${stage}/rootfs" -mindepth 1 -delete
rmdir "${stage}/rootfs"
find "${stage}/rootfs.tar" -delete
mv "${stage}" "${output}"
trap - EXIT INT TERM
echo "app-root=PASS distribution=${distribution} suite=${suite} architecture=${architecture} mode=${mode} sha256=${root_sha}"
