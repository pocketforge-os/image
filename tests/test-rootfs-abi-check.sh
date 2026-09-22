#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT
mkdir -p "$tmp/root/lib" "$tmp/artifacts"

cat >"$tmp/abi.c" <<'EOF'
void abi_symbol(void) {}
EOF
cat >"$tmp/root.map" <<'EOF'
GLIBC_2.36 { global: abi_symbol; };
EOF
cc -shared -fPIC "$tmp/abi.c" -Wl,--version-script="$tmp/root.map" -Wl,-soname,libc.so.6 -o "$tmp/root/lib/libc.so.6"

cat >"$tmp/good.c" <<'EOF'
extern void abi_symbol(void);
__asm__(".symver abi_symbol,abi_symbol@GLIBC_2.36");
void call_abi(void) { abi_symbol(); }
EOF
cc -shared -fPIC "$tmp/good.c" -L"$tmp/root/lib" -Wl,--no-as-needed -l:libc.so.6 -o "$tmp/artifacts/good"

good_output=$(READELF=readelf "$root/build/check-rootfs-abi.sh" "$tmp/root" "$tmp/artifacts")
printf '%s\n' "$good_output"
printf '%s\n' "$good_output" | grep -F 'abi_check=ok max_glibc=GLIBC_2.36 rootfs_glibc=GLIBC_2.36' >/dev/null

cp "$tmp/artifacts/good" "$tmp/artifacts/bad"
sed -i 's/GLIBC_2\.36/GLIBC_2.38/g' "$tmp/artifacts/bad"
if READELF=readelf "$root/build/check-rootfs-abi.sh" "$tmp/root" "$tmp/artifacts/bad" >"$tmp/out" 2>"$tmp/err"; then
    echo 'FAIL: synthetic GLIBC_2.38 requirement was accepted' >&2
    exit 1
fi
grep -F 'FATAL: abi_check' "$tmp/err" >/dev/null
grep -F 'requires=GLIBC_2.38 rootfs_max=GLIBC_2.36' "$tmp/err" >/dev/null
echo 'rootfs-abi-check=PASS'
