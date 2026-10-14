#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-payload-repro.XXXXXX")
fixed_epoch=1780272000
fixed_epoch_days=$((fixed_epoch / 86400))
cleanup() {
    find "$work" -mindepth 1 -delete
    rmdir "$work"
}
trap cleanup EXIT INT TERM

make_fixture() {
    tree=$1
    variant=$2
    mkdir -p "$tree/etc/ssh" "$tree/var/lib/dbus" "$tree/var/lib/apt/lists" \
        "$tree/var/lib/systemd/catalog" "$tree/var/lib/dpkg" \
        "$tree/var/log/apt" "$tree/var/cache/ldconfig" "$tree/var/cache/debconf" \
        "$tree/var/cache/fontconfig" "$tree/usr/lib/python3/test/__pycache__" \
        "$tree/usr/share/icons/Adwaita" "$tree/tmp" "$tree/var/tmp" "$tree/opt"
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
    printf 'catalog-%s\n' "$variant" > "$tree/var/lib/systemd/catalog/database"
    printf 'root:*:%s:0:99999:7:::\n' "$variant" > "$tree/etc/shadow"
    printf 'shadow-backup-%s\n' "$variant" > "$tree/etc/shadow-"
    printf 'passwd-backup-%s\n' "$variant" > "$tree/etc/passwd-"
    printf 'group-backup-%s\n' "$variant" > "$tree/etc/group-"
    printf 'gshadow-backup-%s\n' "$variant" > "$tree/etc/gshadow-"
    printf 'status-backup-%s\n' "$variant" > "$tree/var/lib/dpkg/status-old"
    printf 'diversions-backup-%s\n' "$variant" > "$tree/var/lib/dpkg/diversions-old"
    printf 'debconf-config-%s\n' "$variant" > "$tree/var/cache/debconf/config.dat-old"
    printf 'debconf-templates-%s\n' "$variant" > "$tree/var/cache/debconf/templates.dat-old"
    printf 'ld-cache-%s\n' "$variant" > "$tree/etc/ld.so.cache"
    printf 'icon-cache-%s\n' "$variant" > "$tree/usr/share/icons/Adwaita/icon-theme.cache"
    printf 'tmp-%s\n' "$variant" > "$tree/tmp/work"
    printf 'host-%s\n' "$variant" > "$tree/etc/hostname"
    printf 'nameserver 192.0.2.%s\n' "$variant" > "$tree/etc/resolv.conf"
}

make_fixture "$work/one" 1
make_fixture "$work/two" 2
find "$work/two/etc/resolv.conf" -maxdepth 0 -delete
ln -s /run/producer-specific-resolv.conf "$work/two/etc/resolv.conf"
SOURCE_DATE_EPOCH=$fixed_epoch "$root/tools/normalize-guest-payload-root.sh" "$work/one"
SOURCE_DATE_EPOCH=$fixed_epoch "$root/tools/normalize-guest-payload-root.sh" "$work/two"
python3 -B "$root/tools/inventory-guest-payload.py" "$work/one" "$work/one.tsv"
python3 -B "$root/tools/inventory-guest-payload.py" "$work/two" "$work/two.tsv"
if ! cmp "$work/one.tsv" "$work/two.tsv"; then
    diff -u "$work/one.tsv" "$work/two.tsv"
    exit 1
fi
[[ $(cut -d: -f3 "$work/one/etc/shadow") == "$fixed_epoch_days" ]]
[[ $fixed_epoch_days -gt 0 ]]
for relative in \
    etc/shadow- etc/passwd- etc/group- etc/gshadow- etc/ld.so.cache \
    var/lib/dpkg/status-old var/lib/dpkg/diversions-old \
    var/cache/debconf/config.dat-old var/cache/debconf/templates.dat-old \
    var/lib/systemd/catalog/database usr/share/icons/Adwaita/icon-theme.cache; do
    [[ ! -e "$work/one/$relative" && ! -L "$work/one/$relative" ]]
done

# Stable content remains a meaningful negative control after volatile state is
# removed: a real payload difference must still change the inventory.
printf 'different stable content\n' > "$work/two/opt/stable.txt"
python3 -B "$root/tools/inventory-guest-payload.py" "$work/two" "$work/two-negative.tsv"
if cmp -s "$work/one.tsv" "$work/two-negative.tsv"; then
    echo 'payload-repro=FAIL reason=stable_difference_hidden' >&2
    exit 1
fi

mkdir "$work/not-a-root"
if SOURCE_DATE_EPOCH=$fixed_epoch "$root/tools/normalize-guest-payload-root.sh" "$work/not-a-root" \
    >"$work/refusal.out" 2>&1; then
    echo 'payload-repro=FAIL reason=invalid_root_accepted' >&2
    exit 1
fi
grep -q 'reason=invalid_payload_root' "$work/refusal.out"

make_fixture "$work/invalid-epoch" 3
if SOURCE_DATE_EPOCH=0 "$root/tools/normalize-guest-payload-root.sh" "$work/invalid-epoch" \
    >"$work/epoch-refusal.out" 2>&1; then
    echo 'payload-repro=FAIL reason=zero_epoch_accepted' >&2
    exit 1
fi
grep -q 'reason=invalid_source_date_epoch' "$work/epoch-refusal.out"
if env -u SOURCE_DATE_EPOCH "$root/tools/normalize-guest-payload-root.sh" "$work/invalid-epoch" \
    >"$work/missing-epoch-refusal.out" 2>&1; then
    echo 'payload-repro=FAIL reason=missing_epoch_accepted' >&2
    exit 1
fi
grep -q 'reason=invalid_source_date_epoch' "$work/missing-epoch-refusal.out"
echo 'payload-repro=PASS volatile=normalized stable_difference=visible invalid_root=refused invalid_epoch=refused'
