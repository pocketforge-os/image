#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: test-steamlink-app-policy.sh <pf-app-policy-render>" >&2
    exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
renderer=$1
manifest=${root}/apps/steamlink/app.toml
inventory=${root}/build/app-policy-a133-open-g1-v1.json
platform=${root}/tests/fixtures/app-policy/platform-capabilities-a133-open.toml
producer=${root}/scripts/build-steamlink-app-root-prototype.sh
fragment=${root}/build/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf
tmp=$(mktemp -d "${RUNNER_TEMP:-/tmp}/steamlink-policy.XXXXXX")
trap 'find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT HUP INT TERM

python3 - "$manifest" "$inventory" "$producer" <<'PY'
import json
import pathlib
import sys
import tomllib

manifest_path, inventory_path, producer_path = map(pathlib.Path, sys.argv[1:])
with manifest_path.open("rb") as source:
    manifest = tomllib.load(source)
inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
expected = ["audio", "input", "x11", "egress:tcp/443@*"]
if manifest["app"]["use"] != expected:
    raise SystemExit(f"Steam Link capability policy differs: {manifest['app']['use']!r}")
if manifest["launch"]["needs_network"] is not True:
    raise SystemExit("Steam Link network policy is disabled")
resources = inventory["resources"]
canonical = {
    "x11-socket": ["/run/pocketforge/x11/.X11-unix/X0"],
    "x11-environment": ["/run/pocketforge/x11/policy/environment"],
}
for name, paths in canonical.items():
    if resources.get(name) != paths:
        raise SystemExit(f"Steam Link {name} policy differs: {resources.get(name)!r}")
producer = producer_path.read_text(encoding="utf-8")
literal = "'use = [\"audio\", \"input\", \"x11\", \"egress:tcp/443@*\"]'"
if literal not in producer:
    raise SystemExit("Steam Link app-root producer capability policy differs")
PY

common="--platform-contract $platform --resource-inventory $inventory --app-dir /opt/pocketforge/apps/org.pocketforge.steamlink --platform-runtime /usr --xdg-config /var/lib/pocketforge/apps/org.pocketforge.steamlink/config --xdg-state /var/lib/pocketforge/apps/org.pocketforge.steamlink/state --xdg-cache /var/cache/pocketforge/apps/org.pocketforge.steamlink"
# Deliberate word splitting keeps this POSIX-shell test runnable under /bin/sh.
# shellcheck disable=SC2086
"$renderer" --manifest "$manifest" $common --format systemd-dropin >"$tmp/positive.conf"
grep -Fx 'SupplementaryGroups=audio input pf-session video' \
    "$tmp/positive.conf" >/dev/null
grep -Fx 'BindPaths=/run/pocketforge/x11/.X11-unix/X0:/tmp/.X11-unix/X0' \
    "$tmp/positive.conf" >/dev/null
grep -Fx '# egress tcp * 443' "$tmp/positive.conf" >/dev/null
cmp "$fragment" "$tmp/positive.conf"

sed 's/, "x11"//' "$manifest" >"$tmp/non-x11.toml"
# shellcheck disable=SC2086
"$renderer" --manifest "$tmp/non-x11.toml" $common \
    --format systemd-dropin >"$tmp/non-x11.conf"
grep -Fx 'SupplementaryGroups=audio input video' "$tmp/non-x11.conf" >/dev/null
if grep -Fq 'pf-session' "$tmp/non-x11.conf"; then
    echo 'Steam Link non-X11 policy retained pf-session socket authority' >&2
    exit 1
fi
if grep -Fq '/run/pocketforge/x11' "$tmp/non-x11.conf"; then
    echo 'Steam Link non-X11 policy retained an X11 path' >&2
    exit 1
fi

sed 's/, "egress:tcp\/443@\*"//' "$manifest" >"$tmp/network-without-authority.toml"
# shellcheck disable=SC2086
if "$renderer" --manifest "$tmp/network-without-authority.toml" $common \
    --format systemd-dropin >"$tmp/negative.conf" 2>"$tmp/negative.err"; then
    echo 'Steam Link network policy passed without an egress authority' >&2
    exit 1
fi
grep -F 'launch.needs_network must match explicit egress authorities' \
    "$tmp/negative.err" >/dev/null

echo 'Steam Link exact app policy: PASS (positive and negative controls)'
