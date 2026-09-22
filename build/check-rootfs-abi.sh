#!/bin/sh
# Fail when a foreign-stage ELF requires a newer C/C++ ABI than the rootfs.
set -eu

if [ "$#" -lt 2 ]; then
    echo "Usage: check-rootfs-abi.sh ROOTFS ARTIFACT_PATH..." >&2
    exit 2
fi

rootfs=$1
shift
readelf_bin=${READELF:-aarch64-linux-gnu-readelf}
command -v "$readelf_bin" >/dev/null 2>&1 || readelf_bin=readelf

version_max() {
    sed -n "s/.*\($1[0-9][0-9.]*\).*/\1/p" | LC_ALL=C sort -Vu | tail -n 1
}

root_definition_max() {
    prefix=$1
    shift
    old_ifs=$IFS
    IFS='
'
    for candidate in $(find "$rootfs" \( -type f -o -type l \) "$@" 2>/dev/null | LC_ALL=C sort); do
        if "$readelf_bin" -h "$candidate" >/dev/null 2>&1; then
            IFS=$old_ifs
            "$readelf_bin" --version-info "$candidate" 2>/dev/null | version_max "$prefix"
            return 0
        fi
    done
    IFS=$old_ifs
    return 0
}

root_glibc=$(root_definition_max 'GLIBC_' -path '*/libc.so.6')
[ -n "$root_glibc" ] || { echo "FATAL: cannot determine rootfs glibc ABI" >&2; exit 1; }
root_glibcxx=$(root_definition_max 'GLIBCXX_' -path '*/libstdc++.so.6*')
root_cxxabi=$(root_definition_max 'CXXABI_' -path '*/libstdc++.so.6*')

max_glibc=none
max_glibcxx=none
max_cxxabi=none
checked=0
for input in "$@"; do
    [ -e "$input" ] || continue
    if [ -d "$input" ]; then
        files=$(find "$input" -type f -print)
    else
        files=$input
    fi
    for file in $files; do
        "$readelf_bin" -h "$file" >/dev/null 2>&1 || continue
        checked=$((checked + 1))
        needed=$("$readelf_bin" --dyn-syms --wide "$file" 2>/dev/null | awk '$7 == "UND" { print $8 }')
        for spec in "GLIBC_:$root_glibc" "GLIBCXX_:$root_glibcxx" "CXXABI_:$root_cxxabi"; do
            prefix=${spec%%:*}
            ceiling=${spec#*:}
            required=$(printf '%s\n' "$needed" | version_max "$prefix")
            [ -n "$required" ] || continue
            [ -n "$ceiling" ] || { echo "FATAL: abi_check file=$file requires=$required rootfs_${prefix}=missing" >&2; exit 1; }
            newest=$(printf '%s\n%s\n' "$required" "$ceiling" | LC_ALL=C sort -Vu | tail -n 1)
            if [ "$newest" != "$ceiling" ]; then
                echo "FATAL: abi_check file=$file requires=$required rootfs_max=$ceiling" >&2
                exit 1
            fi
            case "$prefix" in
                GLIBC_) max_glibc=$(printf '%s\n%s\n' "$max_glibc" "$required" | grep -v '^none$' | LC_ALL=C sort -Vu | tail -n 1) ;;
                GLIBCXX_) max_glibcxx=$(printf '%s\n%s\n' "$max_glibcxx" "$required" | grep -v '^none$' | LC_ALL=C sort -Vu | tail -n 1) ;;
                CXXABI_) max_cxxabi=$(printf '%s\n%s\n' "$max_cxxabi" "$required" | grep -v '^none$' | LC_ALL=C sort -Vu | tail -n 1) ;;
            esac
        done
    done
done

echo "abi_check=ok max_glibc=$max_glibc rootfs_glibc=$root_glibc max_glibcxx=$max_glibcxx rootfs_glibcxx=${root_glibcxx:-none} max_cxxabi=$max_cxxabi rootfs_cxxabi=${root_cxxabi:-none} elfs=$checked"
