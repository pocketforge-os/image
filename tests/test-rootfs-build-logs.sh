#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${RUNNER_TEMP:-/tmp}/image-rootfs-build-logs.XXXXXX")
trap 'find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT
mkdir -p "$tmp/rootfs/var/log/journal"
: >"$tmp/rootfs/var/log/runtime-placeholder.log"

"$root/build/check-rootfs-build-logs.sh" "$tmp/rootfs"

printf '%s\n' 'Fontconfig error: Cannot load default config file' \
    >"$tmp/rootfs/var/log/fontconfig.log"
if "$root/build/check-rootfs-build-logs.sh" "$tmp/rootfs" \
    >"$tmp/negative.out" 2>"$tmp/negative.err"; then
    echo 'FAIL: planted fontconfig.log build content was accepted' >&2
    exit 1
fi
grep -Fq 'var/log/fontconfig.log' "$tmp/negative.err"

find "$tmp/rootfs/var/log" -type f -size +0c -delete
"$root/build/check-rootfs-build-logs.sh" "$tmp/rootfs"

grep -Fq 'check-rootfs-build-logs.sh' "$root/scripts/build-rootfs.sh"
echo 'rootfs-build-logs-test=PASS'
