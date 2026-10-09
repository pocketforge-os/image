#!/bin/sh
# Select the Gamescope pipeline-cache producer from the resolved profile mode.
set -eu

if [ "$#" -ne 6 ]; then
    echo 'usage: run-gamescope-pvr-cache.sh MODE PRODUCER GPU_UM_SOURCE BUILD_DIR OUTPUT_ROOT GAMESCOPE_SHA' >&2
    exit 2
fi

mode=$1
producer=$2
source_root=$3
build_dir=$4
output_root=$5
gamescope_sha=$6

case "$mode" in
    g1)
        case "$gamescope_sha" in
            *[!0-9a-f]*|'')
                echo "PF_GAMESCOPE_SHA must be exactly 40 lowercase hex characters for mode g1: ${gamescope_sha:-empty}" >&2
                exit 2
                ;;
        esac
        if [ "${#gamescope_sha}" -ne 40 ]; then
            echo "PF_GAMESCOPE_SHA must be exactly 40 lowercase hex characters for mode g1: $gamescope_sha" >&2
            exit 2
        fi
        [ -x "$producer" ] || {
            echo "Gamescope PVR cache producer is missing or not executable: $producer" >&2
            exit 1
        }
        exec "$producer" "$source_root" "$build_dir" "$output_root" "$gamescope_sha"
        ;;
    not-shipped)
        [ -z "$gamescope_sha" ] || {
            echo "PF_GAMESCOPE_SHA must be absent for mode not-shipped: $gamescope_sha" >&2
            exit 2
        }
        cache_root=$output_root/usr/share/pocketforge/mesa-cache
        { [ ! -e "$cache_root" ] && [ ! -L "$cache_root" ]; } || {
            echo "Gamescope PVR cache exists for mode not-shipped: $cache_root" >&2
            exit 1
        }
        : "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set}"
        install -d -m 0755 "$output_root"
        marker=$output_root/.pf-gamescope-pvr-cache-provenance
        { [ ! -e "$marker" ] && [ ! -L "$marker" ]; } || {
            echo "Gamescope provenance output already exists: $marker" >&2
            exit 1
        }
        printf '%s\n' 'gamescope=absent cache=absent' \
            >"$marker"
        touch -d "@$SOURCE_DATE_EPOCH" \
            "$marker"
        ;;
    *)
        echo "PF_GAMESCOPE_MODE must be not-shipped or g1: $mode" >&2
        exit 2
        ;;
esac
