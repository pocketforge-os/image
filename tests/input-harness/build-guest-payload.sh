#!/usr/bin/env bash
# Build the test-only Bookworm arm64 squashfs attachment. This script runs in
# the digest-pinned PocketForge build container; it never touches a device.
set -euo pipefail

repo=
sdl_source=
gamescope_source=
libei_source=
build_tar=
runtime_tar=
output=
while (($#)); do
    case "$1" in
        --repo) repo=${2-}; shift 2 ;;
        --sdl-source) sdl_source=${2-}; shift 2 ;;
        --gamescope-source) gamescope_source=${2-}; shift 2 ;;
        --libei-source) libei_source=${2-}; shift 2 ;;
        --build-tar) build_tar=${2-}; shift 2 ;;
        --runtime-tar) runtime_tar=${2-}; shift 2 ;;
        --output) output=${2-}; shift 2 ;;
        *) echo "guest payload: unknown argument: $1" >&2; exit 64 ;;
    esac
done
[[ -d "$repo/tests/input-harness" && -d "$sdl_source/sdl3" \
    && -f "$gamescope_source/protocol/gamescope-control.xml" \
    && -f "$libei_source/meson.build" && -f "$build_tar" \
    && -f "$runtime_tar" && -n "$output" ]] || {
    echo "guest payload: required source input is absent" >&2; exit 64;
}
[[ ! -e "$output" ]] || { echo "guest payload: output exists: $output" >&2; exit 73; }

# shellcheck disable=SC1091
source "$repo/tests/input-harness/guest-payload.pins"
export SNAPSHOT_DATE SDL_URL SDL_COMMIT GAMESCOPE_URL GAMESCOPE_COMMIT \
    LIBEI_URL LIBEI_COMMIT SOURCE_DATE_EPOCH
[[ "$(cat "$sdl_source/.pf-source-revision")" == "$SDL_COMMIT" ]]
[[ "$(cat "$gamescope_source/.pf-source-revision")" == "$GAMESCOPE_COMMIT" ]]
[[ "$(cat "$libei_source/.pf-source-revision")" == "$LIBEI_COMMIT" ]]
[[ "$(cat "$repo/snapshot-date.txt")" == "$SNAPSHOT_DATE" ]]

parent=$(dirname "$output")
name=$(basename "$output")
mkdir -p "$parent"
stage=$(mktemp -d "$parent/.${name}.XXXXXX")
cleanup() {
    if [[ -d "$stage" ]]; then
        find "$stage" -mindepth 1 -delete
        rmdir "$stage"
    fi
}
trap cleanup EXIT INT TERM

mkdir "$stage/build-root"
tar -xf "$build_tar" -C "$stage/build-root" --no-same-owner
install -d "$stage/build-root/src" "$stage/build-root/out/bin" "$stage/build-root/out/lib"
cp -a "$repo/tests/input-harness/tools" "$stage/build-root/src/tools"
cp -a "$repo/tests/input-harness/clients" "$stage/build-root/src/clients"
cp -a "$sdl_source/sdl3" "$stage/build-root/src/sdl3"
cp -a "$libei_source" "$stage/build-root/src/libei"
cp "$gamescope_source/protocol/gamescope-control.xml" "$stage/build-root/src/gamescope-control.xml"
cp "$repo/tests/input-harness/guest/build-tools.sh" "$stage/build-root/build-tools.sh"
# The former in-BuildKit clones stamped their checkouts with wall-clock mtimes,
# while the network-free git archives carry commit mtimes. Neither metadata
# source may influence compiler output or build IDs.
find "$stage/build-root/src" -print0 | LC_ALL=C sort -z | \
    xargs -0 touch -h --date="@${SOURCE_DATE_EPOCH}"
touch -h --date="@${SOURCE_DATE_EPOCH}" "$stage/build-root/build-tools.sh"
chroot "$stage/build-root" /bin/bash /build-tools.sh

mkdir "$stage/payload"
tar -xf "$runtime_tar" -C "$stage/payload" --no-same-owner --exclude='./dev/*'
install -d "$stage/payload/dev" "$stage/payload/bin" "$stage/payload/lib" \
    "$stage/payload/guest" "$stage/payload/session" "$stage/payload/report" \
    "$stage/payload/validate"
cp -a "$stage/build-root/out/bin/." "$stage/payload/bin/"
cp -a "$stage/build-root/out/lib/." "$stage/payload/lib/"
cp "$repo/tests/input-harness/guest/agent.py" "$stage/payload/guest/agent.py"
cp "$repo/tests/input-harness/run-guest.sh" "$stage/payload/run-guest.sh"
cp -a "$repo/tests/input-harness/session/." "$stage/payload/session/"
cp -a "$repo/tests/input-harness/report/." "$stage/payload/report/"
cp -a "$repo/tests/input-harness/validate/." "$stage/payload/validate/"
chmod 0755 "$stage/payload/guest/agent.py" "$stage/payload/run-guest.sh" \
    "$stage/payload/session/entry-guest.sh" "$stage/payload/session/driver.py"

# mmdebstrap deliberately creates a usable root, which includes producer-host
# identity, logs, caches and bytecode. None is a harness input; canonicalize it
# before recording or packing the payload.
"$repo/tests/input-harness/tools/normalize-guest-payload-root.sh" "$stage/payload"
"$repo/tests/input-harness/tools/regenerate-guest-ld-cache.sh" "$stage/payload"

# Query the target package database with the builder's dpkg-query; no arm64
# code is executed. This is the exact installed package/version set.
dpkg-query --admindir="$stage/payload/var/lib/dpkg" --show \
    --showformat='${binary:Package}\t${Architecture}\t${Version}\n' | \
    LC_ALL=C sort > "$stage/payload/guest/runtime-packages.tsv"

{
    printf 'snapshot=%s\n' "$SNAPSHOT_DATE"
    printf 'mirror=http://snapshot.debian.org/archive/debian/%s/\n' "$SNAPSHOT_DATE"
    while IFS= read -r -d '' apt_source; do
        relative=${apt_source#"$stage/payload/"}
        printf -- '--- %s ---\n' "$relative"
        cat "$apt_source"
        printf '\n'
    done < <(find "$stage/payload/etc/apt" -type f \
        \( -name '*.list' -o -name '*.sources' \) -print0 | LC_ALL=C sort -z)
} > "$stage/apt-sources.txt"

python3 -B "$repo/tests/input-harness/tools/inventory-guest-payload.py" \
    "$stage/payload" "$stage/payload-files.tsv"

# The payload is a test sysroot. Product gamescope is intentionally neither
# copied nor installed; entry-guest.sh executes /usr/bin/gamescope outside it.
if find "$stage/payload" -type f -name gamescope -print -quit | grep -q .; then
    echo "guest payload: product gamescope must not be included" >&2
    exit 65
fi
find "$stage/payload" -print0 | LC_ALL=C sort -z | \
    xargs -0 touch -h --date="@${SOURCE_DATE_EPOCH}"
# Build twice from the same normalized tree. A mismatch is a producer failure;
# only the first byte-identical copy is published.
for copy in one two; do
    env -u SOURCE_DATE_EPOCH \
    mksquashfs "$stage/payload" "$stage/input-harness-${copy}.squashfs" \
        -noappend -all-root -no-xattrs -all-time "$SOURCE_DATE_EPOCH" \
        -mkfs-time "$SOURCE_DATE_EPOCH" -comp zstd -Xcompression-level 15 \
        -processors 1 -no-progress >/dev/null
done
cmp "$stage/input-harness-one.squashfs" "$stage/input-harness-two.squashfs"
mv "$stage/input-harness-one.squashfs" "$stage/input-harness.squashfs"
rm "$stage/input-harness-two.squashfs"

payload_sha=$(sha256sum "$stage/input-harness.squashfs" | awk '{print $1}')
payload_bytes=$(stat -c %s "$stage/input-harness.squashfs")
harness_sources_sha=$(
    cd "$repo"
    find tests/input-harness -type f ! -path '*/__pycache__/*' ! -name '*.pyc' \
        ! -name 'guest-payload.lock' -print0 | \
        LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
)
PF_PAYLOAD_SHA="$payload_sha" PF_PAYLOAD_BYTES="$payload_bytes" \
PF_RECIPE_SHA="$(sha256sum "$repo/tests/input-harness/build-guest-payload.sh" | awk '{print $1}')" \
PF_PACKAGES_SHA="$(sha256sum "$stage/payload/guest/runtime-packages.tsv" | awk '{print $1}')" \
PF_INVENTORY_SHA="$(sha256sum "$stage/payload-files.tsv" | awk '{print $1}')" \
PF_APT_SOURCES_SHA="$(sha256sum "$stage/apt-sources.txt" | awk '{print $1}')" \
PF_HARNESS_SOURCES_SHA="$harness_sources_sha" \
python3 - "$stage/manifest.json" <<'PY'
import json, os, sys
value = {
    "schema": "pocketforge.input-harness-payload/v1",
    "architecture": "arm64",
    "distribution": "debian-bookworm",
    "snapshot": os.environ["SNAPSHOT_DATE"],
    "format": "squashfs",
    "sha256": os.environ["PF_PAYLOAD_SHA"],
    "bytes": int(os.environ["PF_PAYLOAD_BYTES"]),
    "recipe_sha256": os.environ["PF_RECIPE_SHA"],
    "harness_sources_sha256": os.environ["PF_HARNESS_SOURCES_SHA"],
    "runtime_packages": {
        "path": "guest/runtime-packages.tsv",
        "sha256": os.environ["PF_PACKAGES_SHA"],
    },
    "file_inventory": {
        "path": "payload-files.tsv",
        "sha256": os.environ["PF_INVENTORY_SHA"],
    },
    "apt_sources": {
        "path": "apt-sources.txt",
        "sha256": os.environ["PF_APT_SOURCES_SHA"],
    },
    "sources": {
        "sdl": {"url": os.environ["SDL_URL"], "commit": os.environ["SDL_COMMIT"]},
        "gamescope_protocol_only": {"url": os.environ["GAMESCOPE_URL"], "commit": os.environ["GAMESCOPE_COMMIT"]},
        "libei": {"url": os.environ["LIBEI_URL"], "commit": os.environ["LIBEI_COMMIT"]},
    },
    "contains_product_gamescope": False,
    "reproducibility_copies": 2,
}
with open(sys.argv[1], "w", encoding="utf-8", newline="\n") as out:
    json.dump(value, out, sort_keys=True, separators=(",", ":"))
    out.write("\n")
PY
mkdir "$stage/result"
mv "$stage/input-harness.squashfs" "$stage/result/"
mv "$stage/manifest.json" "$stage/result/"
cp "$stage/payload/guest/runtime-packages.tsv" "$stage/result/runtime-packages.tsv"
mv "$stage/payload-files.tsv" "$stage/result/payload-files.tsv"
mv "$stage/apt-sources.txt" "$stage/result/apt-sources.txt"
mv "$stage/result" "$output"
trap - EXIT INT TERM
find "$stage" -mindepth 1 -delete
rmdir "$stage"
echo "guest-payload=PASS sha256=$payload_sha bytes=$payload_bytes"
