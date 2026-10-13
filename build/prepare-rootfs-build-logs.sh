#!/bin/sh
# Remove the one known package-configuration log, then fail closed on any
# other build-run log content before the extracted rootfs is assembled.
set -eu

[ "$#" -eq 1 ] || {
    echo 'usage: prepare-rootfs-build-logs.sh ROOTFS' >&2
    exit 2
}

rootfs=$1
find "$rootfs/var/log" -maxdepth 1 -type f -name fontconfig.log -delete
"$(dirname "$0")/check-rootfs-build-logs.sh" "$rootfs"
