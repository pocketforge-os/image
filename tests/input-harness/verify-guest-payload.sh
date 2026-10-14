#!/usr/bin/env bash
# Verify the producer output against the committed content-addressed pin.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
payload=
manifest=
while (($#)); do
    case "$1" in
        --payload) payload=${2-}; shift 2 ;;
        --manifest) manifest=${2-}; shift 2 ;;
        *) echo "guest payload verify: unknown argument: $1" >&2; exit 64 ;;
    esac
done
[[ -f "$payload" && -f "$manifest" ]] || {
    echo "guest payload verify: payload and manifest are required" >&2
    exit 64
}
# shellcheck disable=SC1091
source "$root/guest-payload.lock"
actual_sha=$(sha256sum "$payload" | awk '{print $1}')
actual_bytes=$(stat -c %s "$payload")
actual_manifest_sha=$(sha256sum "$manifest" | awk '{print $1}')
[[ "$actual_sha" == "$PF_INPUT_HARNESS_PAYLOAD_SHA256" ]] || {
    echo "guest payload verify: sha mismatch expected=$PF_INPUT_HARNESS_PAYLOAD_SHA256 actual=$actual_sha" >&2
    exit 1
}
[[ "$actual_bytes" == "$PF_INPUT_HARNESS_PAYLOAD_BYTES" ]] || {
    echo "guest payload verify: size mismatch expected=$PF_INPUT_HARNESS_PAYLOAD_BYTES actual=$actual_bytes" >&2
    exit 1
}
[[ "$actual_manifest_sha" == "$PF_INPUT_HARNESS_MANIFEST_SHA256" ]] || {
    echo "guest payload verify: manifest sha mismatch expected=$PF_INPUT_HARNESS_MANIFEST_SHA256 actual=$actual_manifest_sha" >&2
    exit 1
}
python3 -B - "$manifest" "$actual_sha" "$actual_bytes" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    value = json.load(source)
assert value["schema"] == "pocketforge.input-harness-payload/v1"
assert value["architecture"] == "arm64"
assert value["format"] == "squashfs"
assert value["contains_product_gamescope"] is False
assert value["reproducibility_copies"] == 2
assert value["sha256"] == sys.argv[2]
assert value["bytes"] == int(sys.argv[3])
PY
echo "guest-payload-verify=PASS sha256=$actual_sha bytes=$actual_bytes manifest_sha256=$actual_manifest_sha"
