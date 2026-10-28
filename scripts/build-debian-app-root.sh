#!/usr/bin/env bash
set -euo pipefail

distribution=
architecture=
snapshot=
output=
overlay=
mode=unshare
preflight_only=false
packages=(ca-certificates libc6 libgcc-s1 libstdc++6)

usage() {
    echo "usage: $0 --preflight-only | --distribution debian-12|debian-13 --architecture arm64 --snapshot YYYYMMDDTHHMMSSZ [--mode root|unshare|fakechroot] [--package NAME]... [--overlay DIR] --output DIR" >&2
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
mirror="https://snapshot.debian.org/archive/debian/${snapshot}/"
mmdebstrap \
    --mode="${mode}" \
    --variant=minbase \
    --architectures="${architecture}" \
    --format=tar \
    --include="${package_csv}" \
    --aptopt='Acquire::Check-Valid-Until "false";' \
    "${suite}" "${stage}/rootfs.tar" "${mirror}"

mkdir "${stage}/rootfs"
tar -xf "${stage}/rootfs.tar" -C "${stage}/rootfs" \
    --no-same-owner --exclude='./dev/*'
mkdir -p "${stage}/rootfs/dev"
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
