#!/usr/bin/env bash
# =============================================================================
# ipfs-fetch.sh -- fetch vendor blobs from local kubo by CID, verify SHA-256
# -----------------------------------------------------------------------------
# Reads a TOML manifest (pocketforge-os/vendor-manifest format), fetches each
# blob from the local kubo daemon by its CID, verifies file size and SHA-256,
# and populates an output directory that mirrors the old blobs repo layout.
#
# This script runs OUTSIDE the build container, on the host. The output dir
# (work/blobs/ by default) is bind-mounted into the container at /work/blobs:ro.
# No kubo inside the container. No socket forwarding. No API exposure.
#
# Trust model (three gates):
#   1. Manifest signature (manifest.toml.sig, minisign Ed25519) -- checked if
#      present; gracefully skipped if absent (release key not yet generated).
#   2. IPFS CID verification (automatic -- content-addressed fetch).
#   3. SHA-256 verification (application-layer, independent of kubo).
#
# Usage:
#   ipfs-fetch.sh <manifest.toml> <output-dir>
#
# Requires: python3 (3.11+ for tomllib), ipfs CLI, sha256sum, stat
# Optional: minisign (for manifest signature verification)
#
# Exit codes:
#   0  success (all blobs fetched and verified)
#   1  usage / missing dependency
#   2  manifest signature verification failed
#   3  blob fetch failed (kubo unreachable, CID not found)
#   4  blob integrity failed (size or SHA-256 mismatch)
#
# bd: tsp-iby.3
# =============================================================================
set -euo pipefail

# ---- args -------------------------------------------------------------------
if [ $# -lt 2 ]; then
    echo "Usage: ipfs-fetch.sh <manifest.toml> <output-dir>" >&2
    exit 1
fi

MANIFEST="$1"
OUTPUT_DIR="$2"
IPFS_API="${IPFS_API:-/ip4/127.0.0.1/tcp/5001}"

# ---- dependency checks ------------------------------------------------------
for cmd in python3 ipfs sha256sum stat; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command '$cmd' not found in PATH." >&2
        exit 1
    fi
done

# Verify python3 has tomllib (3.11+)
if ! python3 -c "import tomllib" 2>/dev/null; then
    echo "ERROR: python3 tomllib module not available (requires Python 3.11+)." >&2
    exit 1
fi

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: manifest not found: $MANIFEST" >&2
    exit 1
fi

# ---- manifest signature verification (gate 1) ------------------------------
SIG_FILE="${MANIFEST}.sig"
KEYS_DIR="$(dirname "$MANIFEST")/keys"

if [ -f "$SIG_FILE" ]; then
    if command -v minisign >/dev/null 2>&1; then
        # Look for public keys: first in keys/ dir next to manifest, then
        # fall back to MINISIGN_PUBKEY env var
        VERIFIED=0
        if [ -d "$KEYS_DIR" ]; then
            for pubkey in "$KEYS_DIR"/*.pub; do
                [ -f "$pubkey" ] || continue
                if minisign -Vm "$MANIFEST" -p "$pubkey" >/dev/null 2>&1; then
                    echo "OK: manifest signature verified against $(basename "$pubkey")"
                    VERIFIED=1
                    break
                fi
            done
        fi
        if [ "$VERIFIED" = 0 ] && [ -n "${MINISIGN_PUBKEY:-}" ] && [ -f "${MINISIGN_PUBKEY}" ]; then
            if minisign -Vm "$MANIFEST" -p "$MINISIGN_PUBKEY" >/dev/null 2>&1; then
                echo "OK: manifest signature verified against $MINISIGN_PUBKEY"
                VERIFIED=1
            fi
        fi
        if [ "$VERIFIED" = 0 ]; then
            echo "ERROR: Manifest signature verification failed. Aborting." >&2
            echo "  sig:  $SIG_FILE" >&2
            echo "  keys: ${KEYS_DIR}/ or \$MINISIGN_PUBKEY" >&2
            exit 2
        fi
    else
        echo "WARN: manifest.toml.sig exists but minisign is not installed. Cannot verify signature." >&2
        echo "  Install minisign to enable signature verification." >&2
        echo "  SHA-256 verification is still active." >&2
    fi
else
    echo "WARN: manifest signature not verified (manifest.toml.sig absent)."
    echo "  Expected during Phase A/B before M1.D generates the release key."
    echo "  SHA-256 verification is active."
fi

# ---- check kubo daemon reachability ----------------------------------------
if ! ipfs --api "$IPFS_API" id >/dev/null 2>&1; then
    echo "ERROR: kubo daemon not reachable at ${IPFS_API}." >&2
    echo "  Run 'sudo systemctl start ipfs' or check IPFS_API env var." >&2
    exit 3
fi

# ---- parse manifest and fetch blobs ----------------------------------------
echo "=== ipfs-fetch.sh ==="
echo "  manifest: $MANIFEST"
echo "  output:   $OUTPUT_DIR"
echo "  ipfs api: $IPFS_API"
echo ""

# Extract blob entries from TOML manifest using Python's tomllib.
# Output format: one line per blob: path\tsize\tsha256\tcid
BLOB_LIST=$(python3 -c "
import tomllib, sys

with open(sys.argv[1], 'rb') as f:
    m = tomllib.load(f)

for b in m.get('blobs', []):
    path = b['path']
    size = b['size']
    sha256 = b['sha256']
    cid = b['cid']
    print(f'{path}\t{size}\t{sha256}\t{cid}')
" "$MANIFEST")

TOTAL=$(echo "$BLOB_LIST" | wc -l)
CURRENT=0
FAILED=0

echo "Fetching $TOTAL blobs..."
echo ""

while IFS=$'\t' read -r path size sha256 cid; do
    CURRENT=$((CURRENT + 1))
    dest="${OUTPUT_DIR}/${path}"
    dest_dir="$(dirname "$dest")"

    # Skip if already present and verified (idempotent re-runs)
    if [ -f "$dest" ]; then
        actual_size=$(stat -c%s "$dest" 2>/dev/null || echo 0)
        if [ "$actual_size" = "$size" ]; then
            actual_sha=$(sha256sum "$dest" | cut -d' ' -f1)
            if [ "$actual_sha" = "$sha256" ]; then
                printf "  [%d/%d] %-60s CACHED\n" "$CURRENT" "$TOTAL" "$path"
                continue
            fi
        fi
        # Present but wrong -- remove and re-fetch
        rm -f "$dest"
    fi

    mkdir -p "$dest_dir"

    # Fetch by CID from local kubo
    printf "  [%d/%d] %-60s " "$CURRENT" "$TOTAL" "$path"

    if ! ipfs --api "$IPFS_API" cat "$cid" > "$dest" 2>/dev/null; then
        rm -f "$dest"
        echo "FAILED"
        echo "" >&2
        echo "ERROR: CID not found locally: $cid" >&2
        echo "  path: $path" >&2
        echo "  Run 'make warm-cache' to pin all CIDs first." >&2
        exit 3
    fi

    # Verify size (gate: truncation defense)
    actual_size=$(stat -c%s "$dest")
    if [ "$actual_size" != "$size" ]; then
        rm -f "$dest"
        echo "FAILED"
        echo "" >&2
        echo "ERROR: Size mismatch for $path" >&2
        echo "  Expected: $size bytes" >&2
        echo "  Got:      $actual_size bytes" >&2
        echo "  CID:      $cid" >&2
        exit 4
    fi

    # Verify SHA-256 (gate 3: application-layer integrity, independent of kubo)
    actual_sha=$(sha256sum "$dest" | cut -d' ' -f1)
    if [ "$actual_sha" != "$sha256" ]; then
        rm -f "$dest"
        echo "FAILED"
        echo "" >&2
        echo "ERROR: SHA-256 mismatch for $path" >&2
        echo "  Expected: $sha256" >&2
        echo "  Got:      $actual_sha" >&2
        echo "  CID:      $cid" >&2
        echo "  This is a security event -- do NOT proceed." >&2
        exit 4
    fi

    echo "OK"
done <<< "$BLOB_LIST"

# ---- generate per-group SHA-256 manifest files ------------------------------
# The old blobs repo shipped KERNEL.SHA256, BLOBS.SHA256, BOOTCHAIN.SHA256.
# build-initrd.sh uses KERNEL.SHA256 for module integrity checks.
# Generate these from the manifest data so the rest of the pipeline is unchanged.
echo ""
echo "Generating per-group SHA-256 manifests..."

python3 -c "
import tomllib, sys, os

with open(sys.argv[1], 'rb') as f:
    m = tomllib.load(f)

output_dir = sys.argv[2]

# Map group names to their SHA-256 manifest filenames and path prefixes
group_map = {
    'kernel-4.9.191':        ('tsp/kernel-4.9.191/KERNEL.SHA256',     'tsp/kernel-4.9.191/'),
    'pvr-ddk-22.102.54.38':  ('tsp/22.102.54.38/BLOBS.SHA256',        'tsp/22.102.54.38/'),
    'boot-chain':            ('tsp/boot-chain/BOOTCHAIN.SHA256',       'tsp/boot-chain/'),
}

for group_name, (sha_file, prefix) in group_map.items():
    entries = []
    for b in m.get('blobs', []):
        if b.get('group') == group_name:
            # Relative path within the group directory
            rel_path = b['path'][len(prefix):]
            entries.append(f\"{b['sha256']}  {rel_path}\")
    if entries:
        sha_path = os.path.join(output_dir, sha_file)
        with open(sha_path, 'w') as f:
            f.write('\n'.join(sorted(entries)) + '\n')
        print(f'  {sha_file} ({len(entries)} entries)')
" "$MANIFEST" "$OUTPUT_DIR"

echo ""
echo "=== done ==="
echo "  $TOTAL blobs fetched and verified in $OUTPUT_DIR"
