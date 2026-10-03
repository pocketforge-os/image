#!/usr/bin/env bash
set -euo pipefail

producer="${1:?usage: install-platform-runtime.sh PRODUCER ROOTFS}"
rootfs="${2:?usage: install-platform-runtime.sh PRODUCER ROOTFS}"
runtime_rel=usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1
source_rel=usr/share/pocketforge/corresponding-source/steamlink-ffmpeg59/v1

die() { echo "platform-runtime install: $*" >&2; exit 1; }

if [ -f "${producer}/NOT-SHIPPED" ]; then
    [ ! -e "${producer}/${runtime_rel}" ] || die "NOT-SHIPPED producer also contains a runtime"
    exit 0
fi
[ -d "${producer}/${runtime_rel}" ] || die "runtime payload missing"
[ -d "${producer}/${source_rel}" ] || die "corresponding source missing"
[ -f "${producer}/${runtime_rel}/metadata/runtime.toml" ] || die "runtime manifest missing"
[ -f "${producer}/${runtime_rel}/metadata/libraries.sha256" ] || die "library hash manifest missing"
[ -f "${producer}/${runtime_rel}/metadata/payload.sha256" ] || die "payload hash manifest missing"

# Complete every validation before the first copy. A collision or malformed
# producer therefore cannot leave half of a new revision beside an older,
# known-good revision.
for rel in "${runtime_rel}" "${source_rel}"; do
    src="${producer}/${rel}"
    dst="${rootfs}/${rel}"
    if [ -e "${dst}" ] || [ -L "${dst}" ]; then
        die "collision at /${rel}"
    fi
    if find "${src}" -xdev -type f -perm /222 -print -quit | grep -q .; then
        die "writable producer file rejected under /${rel}"
    fi
    if find "${src}" -xdev -type d -perm /222 -print -quit | grep -q .; then
        die "writable producer directory rejected under /${rel}"
    fi
    if find "${src}" -xdev -type l -print | while IFS= read -r link; do
        target="$(readlink "${link}")"
        case "${target}" in ''|.|..|/*|*/*) exit 1 ;; esac
    done; then :; else
        die "unsafe symlink rejected under /${rel}"
    fi
    parent="${dst%/*}"
    while [ "${parent}" != "${rootfs}" ] && [ "${parent}" != / ]; do
        [ ! -L "${parent}" ] || die "symlinked destination ancestor rejected: ${parent}"
        parent="${parent%/*}"
    done
done

(cd "${producer}" && sha256sum -c "${runtime_rel}/metadata/payload.sha256") \
    >/dev/null || die "payload hash verification failed"

for rel in "${runtime_rel}" "${source_rel}"; do
    src="${producer}/${rel}"
    dst="${rootfs}/${rel}"
    mkdir -p "${dst%/*}"
    cp -a "${src}" "${dst}"
done

libdir="${rootfs}/${runtime_rel}/lib/aarch64-linux-gnu"
(cd "${libdir}" && sha256sum -c ../../metadata/libraries.sha256)
while read -r soname target; do
    if [ ! -L "${libdir}/${soname}" ] \
            || [ "$(readlink "${libdir}/${soname}")" != "${target}" ]; then
        die "invalid SONAME link ${soname}"
    fi
done <<'EOF'
libavcodec.so.59 libavcodec.so.59.37.100
libavutil.so.57 libavutil.so.57.28.100
libswresample.so.4 libswresample.so.4.7.100
EOF
[ ! -e "${rootfs}/etc/ld.so.conf.d/steamlink-ffmpeg59.conf" ] \
    || die "global loader configuration is forbidden"
