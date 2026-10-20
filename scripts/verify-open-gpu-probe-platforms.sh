#!/bin/sh
# Verify that every EGL platform named by the shipped probe is implemented by
# the Mesa EGL vendor that the producer is about to package.
set -eu

if [ "$#" -ne 2 ]; then
    echo 'usage: verify-open-gpu-probe-platforms.sh PROBE_SOURCE MESA_EGL_VENDOR' >&2
    exit 2
fi

probe=$1
vendor=$2

fatal() {
    echo "FATAL: open GPU probe platform contract: $*" >&2
    exit 1
}

[ -f "$probe" ] || fatal "probe source is missing: $probe"
[ -f "$vendor" ] || fatal "Mesa EGL vendor is missing: $vendor"

platforms=$(LC_ALL=C grep -oE 'EGL_PLATFORM_[A-Z0-9_]+' "$probe" | LC_ALL=C sort -u || :)
[ -n "$platforms" ] || fatal 'probe requests no recognized EGL platform'

checked=0
for platform in $platforms; do
    case "$platform" in
        EGL_PLATFORM_SURFACELESS_MESA)
            extension=EGL_MESA_platform_surfaceless
            ;;
        *)
            fatal "$platform has no Mesa capability mapping"
            ;;
    esac
    if ! strings "$vendor" | grep -F "$extension" >/dev/null; then
        fatal "$platform requires $extension in $(basename "$vendor")"
    fi
    checked=$((checked + 1))
done

echo "open-gpu-probe-platforms=PASS platforms=$checked vendor=$(basename "$vendor")"
