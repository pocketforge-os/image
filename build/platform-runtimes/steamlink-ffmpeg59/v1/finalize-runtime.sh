#!/usr/bin/env bash
set -euo pipefail

runtime="${1:?usage: finalize-runtime.sh RUNTIME}"
strip_tool="${PF_FFMPEG_STRIP:-aarch64-none-linux-gnu-strip}"
readelf_tool="${PF_FFMPEG_READELF:-readelf}"
libdir="${runtime}/lib/aarch64-linux-gnu"

die() { echo "steamlink-ffmpeg59 finalize: $*" >&2; exit 1; }

while read -r filename soname; do
    library="${libdir}/${filename}"
    link="${libdir}/${soname}"
    if [ ! -f "${library}" ] || [ -L "${library}" ]; then
        die "missing regular runtime library ${filename}"
    fi
    if [ ! -L "${link}" ] || [ "$(readlink "${link}")" != "${filename}" ]; then
        die "invalid SONAME link ${soname}"
    fi
    "${readelf_tool}" -d "${library}" | grep -Fq "(SONAME)" \
        || die "SONAME missing from ${filename}"
    "${readelf_tool}" -d "${library}" | grep -Fq "[${soname}]" \
        || die "SONAME differs in ${filename}"
    "${strip_tool}" --strip-debug "${library}"
    if "${readelf_tool}" -SW "${library}" \
            | grep -Eq '[[:space:]]\.(z?debug_info)([[:space:]]|$)'; then
        die "debug information survived finalization in ${filename}"
    fi
done <<'EOF'
libavcodec.so.59.37.100 libavcodec.so.59
libavutil.so.57.28.100 libavutil.so.57
libswresample.so.4.7.100 libswresample.so.4
EOF
