#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dockerfile="$root/build/Dockerfile.pf"
tmpdir=$(mktemp -d)
trap 'find "$tmpdir" -mindepth 1 -delete; rmdir "$tmpdir"' EXIT
fixture="$tmpdir/install-mesa-buildenv.sh"

cat >"$fixture" <<'EOF'
#!/usr/bin/env bash
if [[ ${MESA_UBUNTU_SNAPSHOT:-none} == none ]]; then
  rm -f /etc/apt/apt.conf.d/50mesa-snapshot
else
  printf 'snapshot configured\n'
fi

llvm_key=$(mktemp)
trap 'rm -f -- "${llvm_key}"' EXIT

if [[ -e /etc/apt/preferences.d/50mesa-snapshot ]]; then
  rm -f /etc/apt/preferences.d/50mesa-snapshot
fi
EOF

transform=$(
  grep 'sed -i .* /usr/local/src/install-mesa-buildenv\.sh$' "$dockerfile" |
    sed -n "s/^[[:space:]]*sed -i '\([^']*\)' \/usr\/local\/src\/install-mesa-buildenv\.sh$/\1/p"
)

if [[ -z $transform || $transform == *$'\n'* ]]; then
  printf 'FAIL: expected exactly one install-mesa-buildenv.sh sed transform\n' >&2
  exit 1
fi

sed -i "$transform" "$fixture"
bash -n "$fixture"

if grep -q "^trap 'rm -f -- " "$fixture"; then
  printf 'FAIL: LLVM key EXIT trap survived transform\n' >&2
  exit 1
fi

grep -q '^  rm -f /etc/apt/apt.conf.d/50mesa-snapshot$' "$fixture"
grep -q '^  rm -f /etc/apt/preferences.d/50mesa-snapshot$' "$fixture"

printf 'PASS: Dockerfile preserves conditional cleanup bodies and strips only the LLVM key EXIT trap\n'

python3 "$root/build/tests/test_gpu_um_toolchain_drift.py"

target_gpu_um_sha=299d52947864fd42aa9a153aaaf5a14f6e23c1ce
stale_gpu_um_sha=1d8056548b79b236e45d3ba0b0dec94a25660930
stale_dockerfile="$tmpdir/gpu-um-stale.Dockerfile"
stale_fixture="$tmpdir/gpu-um-stale-fixture.Dockerfile"
sed "s/$target_gpu_um_sha/$stale_gpu_um_sha/g" "$dockerfile" >"$stale_dockerfile"
sed "s/$target_gpu_um_sha/$stale_gpu_um_sha/g" \
  "$root/build/tests/fixtures/gpu-um-toolchain-299d5294.Dockerfile" >"$stale_fixture"

gpu_um_stale="$tmpdir/gpu-um-stale-source-pin.log"
if python3 "$root/build/tests/test_gpu_um_toolchain_drift.py" \
  --dockerfile "$stale_dockerfile" \
  --fixture "$stale_fixture" >"$gpu_um_stale" 2>&1; then
  printf 'FAIL: gpu-um toolchain guard accepted stale live and fixture identities\n' >&2
  exit 1
fi
grep -Fx \
  "FAIL: live source pin: expected '$target_gpu_um_sha', got '$stale_gpu_um_sha'" \
  "$gpu_um_stale" >/dev/null
grep -Fx \
  "FAIL: fixture source pin: expected '$target_gpu_um_sha', got '$stale_gpu_um_sha'" \
  "$gpu_um_stale" >/dev/null
printf 'PASS: gpu-um toolchain guard rejects stale live and fixture source identities\n'
