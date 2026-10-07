#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-a133-cma-test.XXXXXX")"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT

python3 "${repo}/tests/helpers/make-cma-test-dtb.py" \
    --output "${scratch}/default-cma.dtb" --default-cma
python3 "${repo}/tests/helpers/make-cma-test-dtb.py" \
    --output "${scratch}/no-default-cma.dtb"
head -c 20 "${scratch}/default-cma.dtb" > "${scratch}/truncated.dtb"

printf 'cmdline=console=ttyS0 cma=64M rootwait\n' > "${scratch}/bad-cmdline.txt"
printf 'cmdline=console=ttyS0 rootwait\n' > "${scratch}/clean-cmdline.txt"
python3 - "${scratch}/clean-env.img" "${scratch}/cma-env.img" <<'PY'
from pathlib import Path
import struct
import sys
import zlib

def write_env(path, records):
    payload = (b"\0".join(records) + b"\0\0").ljust(4092, b"\0")
    Path(path).write_bytes(struct.pack("<I", zlib.crc32(payload)) + payload)

write_env(sys.argv[1], [b"bootcmd=booti 0x44000000 - 0x49000000"])
write_env(
    sys.argv[2],
    [
        b"cma=64M",
        b"setargs_nand=setenv bootargs console=ttyS0 cma=${cma} rootwait",
        b"setargs_mmc=setenv bootargs console=ttyS0 cma=${cma} rootwait",
        b"bootcmd=booti 0x44000000 - 0x49000000",
    ],
)
PY
cp "${scratch}/cma-env.img" "${scratch}/bad-crc-env.img"
printf '\001' | dd of="${scratch}/bad-crc-env.img" bs=1 seek=7 conv=notrunc status=none

guard=(python3 "${repo}/scripts/check-a133-cma-bootargs.py")

# Positive control: DT-owned CMA with no override is accepted.
"${guard[@]}" \
    --dtb "${scratch}/default-cma.dtb" \
    --cmdline "${scratch}/clean-cmdline.txt" \
    --env-img "${scratch}/clean-env.img"

# The failure under test: an effective cmdline override must lose to the DT's
# owned default pool instead of silently disabling that pool.
if "${guard[@]}" \
    --dtb "${scratch}/default-cma.dtb" \
    --cmdline "${scratch}/bad-cmdline.txt" \
    --env-img "${scratch}/clean-env.img"; then
    echo "FAIL: guard accepted cma= from the effective cmdline" >&2
    exit 1
fi

# The shipped environment is a bootargs source too. The guard rejects its
# vendor-era cma variable/scripts before the deterministic transform.
if "${guard[@]}" \
    --dtb "${scratch}/default-cma.dtb" \
    --cmdline "${scratch}/clean-cmdline.txt" \
    --env-img "${scratch}/cma-env.img"; then
    echo "FAIL: guard accepted cma= from the environment partition" >&2
    exit 1
fi

python3 "${repo}/scripts/remove-a133-env-cma.py" \
    --input "${scratch}/cma-env.img" \
    --output "${scratch}/sanitized-env.img"
"${guard[@]}" \
    --dtb "${scratch}/default-cma.dtb" \
    --cmdline "${scratch}/clean-cmdline.txt" \
    --env-img "${scratch}/sanitized-env.img"

# Corrupt input is an error, not a negative result.
if python3 "${repo}/scripts/remove-a133-env-cma.py" \
    --input "${scratch}/bad-crc-env.img" \
    --output "${scratch}/unused-env.img"; then
    echo "FAIL: environment transform accepted a corrupt CRC" >&2
    exit 1
fi

if "${guard[@]}" \
    --dtb "${scratch}/truncated.dtb" \
    --cmdline "${scratch}/clean-cmdline.txt" \
    --env-img "${scratch}/clean-env.img"; then
    echo "FAIL: guard treated a partial DTB read as a negative result" >&2
    exit 1
fi

# Negative control in the same invocation: cma= is allowed when the DTB does
# not claim the default CMA pool.
"${guard[@]}" \
    --dtb "${scratch}/no-default-cma.dtb" \
    --cmdline "${scratch}/bad-cmdline.txt" \
    --env-img "${scratch}/clean-env.img"

# The repository input is the red/green assertion. It fails before cma= is
# removed from the open-stack cmdline and passes afterward.
repo_args=(
    --dtb "${scratch}/default-cma.dtb"
    --cmdline "${repo}/boards/tsp/cmdline.txt"
    --env-img "${scratch}/clean-env.img"
)
if [ -n "${UBOOT_CONFIG_UNDER_TEST:-}" ]; then
    repo_args+=(--uboot-config "${UBOOT_CONFIG_UNDER_TEST}")
fi
"${guard[@]}" "${repo_args[@]}"

grep -qxF 'cmdline=console=ttyS0,115200 earlyprintk=sunxi-uart,0x05000000 rdinit=/init root=PARTLABEL=userdata rootwait init=/sbin/init loglevel=8 cma=64M gpt=1 androidboot.hardware=sun50iw10p1' \
    "${repo}/boards/tsp/cmdline-vendor-4.9.txt" || {
    echo "FAIL: vendor 4.9 cmdline changed" >&2
    exit 1
}

echo "PASS: A133 CMA bootargs guard controls and repository input"
