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

gpu_um_negative="$tmpdir/gpu-um-source-pin-negative.log"
if python3 "$root/build/tests/test_gpu_um_toolchain_drift.py" \
  --source-sha 0dc9d15a >"$gpu_um_negative" 2>&1; then
  printf 'FAIL: gpu-um toolchain guard accepted the superseded source identity\n' >&2
  exit 1
fi
grep -Fx \
  "FAIL: live source pin: expected '0dc9d15a', got 'fd904962ec4726d038cf5b5e895598ac48081cce'" \
  "$gpu_um_negative" >/dev/null
grep -Fx \
  "FAIL: fixture source pin: expected '0dc9d15a', got 'fd904962ec4726d038cf5b5e895598ac48081cce'" \
  "$gpu_um_negative" >/dev/null
printf 'PASS: gpu-um toolchain guard rejects superseded live and fixture source identities\n'
