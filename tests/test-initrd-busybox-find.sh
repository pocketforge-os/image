#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="$root/boards/tsp/initrd/self-flash-v3.sh"
init="$root/boards/tsp/initrd/init"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-initrd-busybox-find.XXXXXX")"
trap '/usr/bin/find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# BusyBox 1.35, the binary shipped in this initrd, does not implement GNU
# find's -delete action. Keep this contract over every shared TSP initrd path.
if grep -Eq 'find[[:space:]].*-delete' "$engine" "$init"; then
    fail 'TSP initrd still invokes find -delete, which the shipped BusyBox rejects'
fi

# Exercise the cleanup function with a fake find that fails closed if a caller
# tries to use the unsupported action. A stale work entry must still be removed.
fakebin="$tmp/bin"
work="$tmp/work"
mkdir -p "$fakebin" "$work/nested"
printf stale >"$work/nested/entry"
cat >"$fakebin/find" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *' -delete '*)
        printf 'fake-busybox-find: unsupported -delete\n' >&2
        exit 2
        ;;
esac
exec /usr/bin/find "$@"
EOF
chmod 0755 "$fakebin/find"

PATH="$fakebin:$PATH"
export PATH

SF_V3_WORK="$work"
export SF_V3_WORK
# shellcheck source=/dev/null
. "$engine"
sf_v3_clean_work || fail 'cleanup rejected a stale work directory'
[[ -d "$work" ]] || fail 'cleanup removed the work directory itself'
if /usr/bin/find "$work" -mindepth 1 -print -quit | grep -q .; then
    fail 'cleanup left stale work entries'
fi

printf 'INITRD_BUSYBOX_FIND_TEST result=PASS unsupported_delete=refused cleanup=pass\n'
