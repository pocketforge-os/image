#!/bin/sh
# Install the application-scoped GLES 3.2 qualification policy only in the CTS image.
set -eu

die() {
    printf 'gles32-candidate-install=FAIL %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 4 ] || die 'reason=usage expected=policy,rootfs,variant,device'
source_policy=$1
rootfs=$2
variant=$3
device=$4
policy_name=99-pocketforge-gles32-candidate.conf
policy_path="$rootfs/usr/share/drirc.d/$policy_name"
mesa_route="$rootfs/usr/local/share/drirc.d/$policy_name"

if [ ! -d "$rootfs" ] || [ -L "$rootfs" ]; then
    die 'reason=rootfs_invalid'
fi
case "$variant" in
    dev|release) ;;
    *) die 'reason=variant_invalid' ;;
esac
[ -n "$device" ] || die 'reason=device_missing'

if [ "$variant:$device" != dev:a133-open-7x-gpu-cts ]; then
    if [ -e "$policy_path" ] || [ -L "$policy_path" ] || \
       [ -e "$mesa_route" ] || [ -L "$mesa_route" ]; then
        die "reason=policy_present_outside_cts path=/usr/share/drirc.d/$policy_name"
    fi
    printf 'gles32-candidate-install=PASS mode=off variant=%s device=%s\n' \
        "$variant" "$device"
    exit 0
fi

if [ ! -f "$source_policy" ] || [ -L "$source_policy" ]; then
    die 'reason=source_policy_invalid'
fi
if [ -e "$policy_path" ] || [ -L "$policy_path" ]; then
    die 'reason=policy_collision'
fi
if [ -e "$mesa_route" ] || [ -L "$mesa_route" ]; then
    die 'reason=mesa_route_collision'
fi

install -D -m 0644 "$source_policy" "$policy_path"
install -d -m 0755 "$(dirname "$mesa_route")"
ln -s "../../../share/drirc.d/$policy_name" "$mesa_route"

printf '%s\n' \
    "gles32-candidate-install=PASS mode=cts variant=$variant device=$device policy=/usr/share/drirc.d/$policy_name mesa_route=/usr/local/share/drirc.d/$policy_name"
