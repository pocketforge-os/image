#!/bin/sh
# Reject logs containing bytes produced while constructing the rootfs. Empty
# placeholders and directories needed by runtime logging remain permitted.
set -eu

[ "$#" -eq 1 ] || {
    echo 'usage: check-rootfs-build-logs.sh ROOTFS' >&2
    exit 2
}

rootfs=$1
log_dir=$rootfs/var/log
[ -d "$log_dir" ] || {
    echo 'FATAL: rootfs is missing var/log' >&2
    exit 1
}

logs=$(find "$log_dir" -type f -size +0c -print | LC_ALL=C sort)
if [ -n "$logs" ]; then
    echo 'FATAL: rootfs contains build-run log content:' >&2
    printf '%s\n' "$logs" | sed "s#^$rootfs/##" >&2
    exit 1
fi

echo 'rootfs_build_logs=ok'
