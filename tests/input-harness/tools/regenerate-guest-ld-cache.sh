#!/usr/bin/env bash
# Rebuild the target loader cache only after the payload tree is complete and
# volatile bootstrap state has been removed.
set -euo pipefail

root=${1-}
if [[ -z "$root" || ! -d "$root/etc" || ! -d "$root/var" ]]; then
    echo 'guest ld cache: reason=invalid_payload_root' >&2
    exit 64
fi
root=$(realpath -e "$root")
if [[ "$root" == / ]]; then
    echo 'guest ld cache: reason=invalid_payload_root' >&2
    exit 64
fi
epoch=${SOURCE_DATE_EPOCH-}
if [[ ! "$epoch" =~ ^[1-9][0-9]{0,17}$ ]]; then
    echo 'guest ld cache: reason=invalid_source_date_epoch' >&2
    exit 64
fi
if [[ ! -x "$root/usr/sbin/ldconfig" || -L "$root/usr/sbin/ldconfig" ]]; then
    echo 'guest ld cache: reason=missing_target_ldconfig' >&2
    exit 65
fi

# -i makes the result independent of ldconfig's auxiliary cache. The command
# runs inside the arm64 chroot, through the same registered binfmt path used by
# build-tools.sh, so it consumes the target loader and target configuration.
if ! LC_ALL=C chroot "$root" /usr/sbin/ldconfig -i; then
    echo 'guest ld cache: reason=target_ldconfig_failed' >&2
    exit 70
fi
if [[ ! -s "$root/etc/ld.so.cache" || -L "$root/etc/ld.so.cache" ]]; then
    echo 'guest ld cache: reason=cache_not_created' >&2
    exit 70
fi
if [[ -e "$root/var/cache/ldconfig/aux-cache" || -L "$root/var/cache/ldconfig/aux-cache" ]]; then
    find "$root/var/cache/ldconfig/aux-cache" -maxdepth 0 -delete
fi
touch -h --date="@$epoch" "$root/etc/ld.so.cache"
echo "guest-ld-cache=PASS sha256=$(sha256sum "$root/etc/ld.so.cache" | awk '{print $1}')"
