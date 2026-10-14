#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-payload-repro.XXXXXX")
cleanup() {
    find "$work" -mindepth 1 -delete
    rmdir "$work"
}
trap cleanup EXIT INT TERM

make_fixture() {
    tree=$1
    variant=$2
    mkdir -p "$tree/etc/ssh" "$tree/var/lib/dbus" "$tree/var/lib/apt/lists" \
        "$tree/var/lib/systemd" "$tree/var/log/apt" "$tree/var/cache/ldconfig" \
        "$tree/var/cache/fontconfig" "$tree/usr/lib/python3/test/__pycache__" \
        "$tree/tmp" "$tree/var/tmp" "$tree/opt"
    printf 'stable\n' > "$tree/opt/stable.txt"
    printf 'machine-%s\n' "$variant" > "$tree/etc/machine-id"
    printf 'dbus-%s\n' "$variant" > "$tree/var/lib/dbus/machine-id"
    printf 'key-%s\n' "$variant" > "$tree/etc/ssh/ssh_host_ed25519_key"
    printf 'log-%s\n' "$variant" > "$tree/var/log/dpkg.log"
    printf 'apt-log-%s\n' "$variant" > "$tree/var/log/apt/history.log"
    printf 'list-%s\n' "$variant" > "$tree/var/lib/apt/lists/example"
    printf 'cache-%s\n' "$variant" > "$tree/var/cache/ldconfig/aux-cache"
    printf 'font-%s\n' "$variant" > "$tree/var/cache/fontconfig/cache"
    printf 'pyc-%s\n' "$variant" > "$tree/usr/lib/python3/test/__pycache__/test.pyc"
    printf 'seed-%s\n' "$variant" > "$tree/var/lib/systemd/random-seed"
    printf 'tmp-%s\n' "$variant" > "$tree/tmp/work"
    printf 'host-%s\n' "$variant" > "$tree/etc/hostname"
    printf 'nameserver 192.0.2.%s\n' "$variant" > "$tree/etc/resolv.conf"
}

make_fixture "$work/one" 1
make_fixture "$work/two" 2
find "$work/two/etc/resolv.conf" -maxdepth 0 -delete
ln -s /run/producer-specific-resolv.conf "$work/two/etc/resolv.conf"
"$root/tools/normalize-guest-payload-root.sh" "$work/one"
"$root/tools/normalize-guest-payload-root.sh" "$work/two"
python3 -B "$root/tools/inventory-guest-payload.py" "$work/one" "$work/one.tsv"
python3 -B "$root/tools/inventory-guest-payload.py" "$work/two" "$work/two.tsv"
cmp "$work/one.tsv" "$work/two.tsv"

# Stable content remains a meaningful negative control after volatile state is
# removed: a real payload difference must still change the inventory.
printf 'different stable content\n' > "$work/two/opt/stable.txt"
python3 -B "$root/tools/inventory-guest-payload.py" "$work/two" "$work/two-negative.tsv"
if cmp -s "$work/one.tsv" "$work/two-negative.tsv"; then
    echo 'payload-repro=FAIL reason=stable_difference_hidden' >&2
    exit 1
fi

mkdir "$work/not-a-root"
if "$root/tools/normalize-guest-payload-root.sh" "$work/not-a-root" \
    >"$work/refusal.out" 2>&1; then
    echo 'payload-repro=FAIL reason=invalid_root_accepted' >&2
    exit 1
fi
grep -q 'reason=invalid_payload_root' "$work/refusal.out"
echo 'payload-repro=PASS volatile=normalized stable_difference=visible invalid_root=refused'
