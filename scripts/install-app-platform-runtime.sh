#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: install-app-platform-runtime.sh CONFIG HOST_ROOT ROOTFS" >&2
    exit 2
fi

CONFIG=$1
HOST_ROOT=$2
ROOTFS=$3
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILDER="${PF_APP_RUNTIME_BUILDER:-${SCRIPT_DIR}/build-app-platform-runtime.py}"
READELF="${PF_APP_RUNTIME_READELF:-readelf}"

for path in "$CONFIG" "$HOST_ROOT" "$ROOTFS" "$BUILDER"; do
    [ -e "$path" ] || {
        echo "app-platform-runtime: missing path: $path" >&2
        exit 66
    }
done
[ -f "$CONFIG" ] || { echo "app-platform-runtime: config is not a regular file" >&2; exit 66; }
[ -d "$HOST_ROOT" ] || { echo "app-platform-runtime: host root is not a directory" >&2; exit 66; }
[ -d "$ROOTFS" ] || { echo "app-platform-runtime: rootfs is not a directory" >&2; exit 66; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pf-app-platform-runtime.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM

OUTPUT="$WORK/platform-runtime"
python3 "$BUILDER" \
    --host-root "$HOST_ROOT" \
    --config "$CONFIG" \
    --output "$OUTPUT" \
    --readelf "$READELF"

DIGEST=$(python3 - "$OUTPUT" <<'PY'
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
digest = hashlib.sha256()
entries = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
for path in entries:
    relative = path.relative_to(root).as_posix()
    if path.is_symlink():
        raise SystemExit(f"app-platform-runtime: symlink in staged runtime: {relative}")
    if path.is_dir():
        continue
    if not path.is_file():
        raise SystemExit(f"app-platform-runtime: non-regular staged runtime file: {relative}")
    if relative == ".manifest-sha256":
        continue
    digest.update(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {relative}\n".encode())
print(digest.hexdigest())
PY
)

STORE="$ROOTFS/usr/lib/pocketforge/platform-runtimes/pocketforge-bookworm-aarch64"
TARGET="$STORE/sha256-$DIGEST"

for path in \
    "$ROOTFS/usr" \
    "$ROOTFS/usr/lib" \
    "$ROOTFS/usr/lib/pocketforge" \
    "$ROOTFS/usr/lib/pocketforge/platform-runtimes" \
    "$STORE" \
    "$TARGET"; do
    if [ -L "$path" ]; then
        echo "FATAL: refusing symlinked runtime path: $path" >&2
        exit 2
    fi
done

mkdir -p "$STORE"
# mkdir -p inherits the build caller's umask. Normalize the complete published
# path, including the filesystem root that becomes the app's mounted root.
for path in \
    "$ROOTFS" \
    "$ROOTFS/usr" \
    "$ROOTFS/usr/lib" \
    "$ROOTFS/usr/lib/pocketforge" \
    "$ROOTFS/usr/lib/pocketforge/platform-runtimes" \
    "$STORE"; do
    chmod a+rx "$path"
done
[ ! -e "$TARGET" ] && [ ! -L "$TARGET" ] || {
    echo "app-platform-runtime: refusing content-address collision: $TARGET" >&2
    exit 73
}
mv "$OUTPUT" "$TARGET"
printf '%s\n' "$DIGEST" >"$TARGET/.manifest-sha256"
chmod -R a-w "$TARGET"
# The builder stages under mkdtemp, so the moved top-level directory starts
# as 0700, and a restrictive build umask can also leave regular files 0600.
# Keep the immutable store readable and traversable by the unprivileged app.
find "$TARGET" -type d -exec chmod a+rx {} +
find "$TARGET" -type f -exec chmod a+r {} +
chmod 0444 "$TARGET/.manifest-sha256"

printf 'app-platform-runtime=PASS store=%s digest=sha256:%s\n' \
    "/usr/lib/pocketforge/platform-runtimes/pocketforge-bookworm-aarch64" "$DIGEST"
