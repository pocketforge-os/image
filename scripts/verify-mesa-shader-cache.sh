#!/bin/sh
# Verify that the built Zink Gallium artifact contains Mesa's on-disk shader
# cache path and actively links the zstd compression API used by that cache.
set -eu

if [ "$#" -ne 1 ]; then
    echo 'usage: verify-mesa-shader-cache.sh LIBGALLIUM_DRI_SO' >&2
    exit 2
fi

artifact=$1
cache_witness='zink: Failed to create disk cache queue'

fatal() {
    echo "FATAL: Mesa shader cache: $*" >&2
    exit 1
}

[ -f "${artifact}" ] && [ ! -L "${artifact}" ] \
    || fatal "artifact is missing or not a regular file: ${artifact}"

readelf_bin=${PF_MESA_READELF:-}
if [ -z "${readelf_bin}" ]; then
    for candidate in aarch64-linux-gnu-readelf aarch64-none-linux-gnu-readelf readelf; do
        if command -v "${candidate}" >/dev/null 2>&1; then
            readelf_bin=${candidate}
            break
        fi
    done
fi
[ -n "${readelf_bin}" ] && command -v "${readelf_bin}" >/dev/null 2>&1 \
    || fatal 'readelf is unavailable'

"${readelf_bin}" -h "${artifact}" >/dev/null 2>&1 \
    || fatal "artifact is not a readable ELF: ${artifact}"
dynamic=$("${readelf_bin}" --wide -d "${artifact}") \
    || fatal "could not read ELF dynamic section: ${artifact}"
dyn_symbols=$("${readelf_bin}" --wide --dyn-syms "${artifact}") \
    || fatal "could not read ELF dynamic symbols: ${artifact}"

LC_ALL=C grep -aF "${cache_witness}" "${artifact}" >/dev/null \
    || fatal 'compiled Zink shader-cache witness is absent'
printf '%s\n' "${dynamic}" | grep -F 'Shared library: [libzstd.so.1]' >/dev/null \
    || fatal 'required DT_NEEDED entry is absent: libzstd.so.1'

for symbol in ZSTD_compress ZSTD_decompress; do
    printf '%s\n' "${dyn_symbols}" | awk -v wanted="${symbol}" '
        $7 == "UND" {
            name = $8
            sub(/@.*/, "", name)
            if (name == wanted)
                found = 1
        }
        END { exit(found ? 0 : 1) }
    ' || fatal "required undefined symbol is absent: ${symbol}"
done

printf '%s\n' \
    "mesa-shader-cache=PASS artifact=${artifact} cache_witness=\"${cache_witness}\" zstd_soname=libzstd.so.1 zstd_symbols=ZSTD_compress,ZSTD_decompress"
