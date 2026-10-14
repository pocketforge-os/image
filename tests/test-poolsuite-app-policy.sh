#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: test-poolsuite-app-policy.sh <pf-app-policy-render> <poolsuite-app.toml>" >&2
    exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renderer="$1"
manifest="$2"
inventory="${root}/build/app-policy-a133-open-v1.json"
platform="${root}/tests/fixtures/app-policy/platform-capabilities-a133-open.toml"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/poolsuite-policy.XXXXXX")"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT

python3 - "${manifest}" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    manifest = tomllib.load(handle)
expected = ["input", "audio", "egress:tcp/80@*", "egress:tcp/443@*"]
actual = manifest["app"]["use"]
if actual != expected:
    raise SystemExit(f"Poolsuite egress contract differs: {actual!r}")
PY

common=(
    --platform-contract "${platform}"
    --resource-inventory "${inventory}"
    --app-dir /opt/pocketforge/apps/org.pocketforge.poolsuite
    --platform-runtime /usr
    --xdg-config /var/lib/pocketforge/apps/org.pocketforge.poolsuite/config
    --xdg-state /var/lib/pocketforge/apps/org.pocketforge.poolsuite/state
    --xdg-cache /var/cache/pocketforge/apps/org.pocketforge.poolsuite
)
"${renderer}" --manifest "${manifest}" "${common[@]}" \
    --format systemd-dropin > "${tmp}/positive.conf"
grep -Fx 'SupplementaryGroups=audio input video' "${tmp}/positive.conf"
grep -Fx 'RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6' "${tmp}/positive.conf"
grep -Fx 'PrivateNetwork=no' "${tmp}/positive.conf"
grep -Fx '# egress tcp * 80' "${tmp}/positive.conf"
grep -Fx '# egress tcp * 443' "${tmp}/positive.conf"
grep -Fx '# derived dns tcp udp 53' "${tmp}/positive.conf"
if grep -F '# egress udp ' "${tmp}/positive.conf"; then
    echo 'Poolsuite gained application UDP egress' >&2
    exit 1
fi

sed 's/needs_network = true/needs_network = false/' "${manifest}" \
    > "${tmp}/network-mismatch.toml"
if "${renderer}" --manifest "${tmp}/network-mismatch.toml" "${common[@]}" \
    --format systemd-dropin > "${tmp}/negative.conf" 2> "${tmp}/negative.err"; then
    echo 'networked manifest with needs_network=false unexpectedly passed' >&2
    exit 1
fi
grep -F 'launch.needs_network must match explicit egress authorities' \
    "${tmp}/negative.err"

echo 'poolsuite exact-manifest app policy: PASS (positive and negative controls)'
