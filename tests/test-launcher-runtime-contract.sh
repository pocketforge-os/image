#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
guard="${repo_root}/scripts/check-launcher-runtime-contract.sh"
dockerfile="${repo_root}/build/Dockerfile.pf"
crates="pf-scene pf-ports pf-render pf-framehost pf-framehost-wayland pf-theme pf-input-map pf-prefs pf-prefs-port pf-session-client pf-session-authority pf-wire"

for crate in $crates; do
    grep -qw "$crate" "$dockerfile"
done
grep -q 'COPY --from=runtime-src . /work/runtime-contract' "$dockerfile"
grep -q 'FATAL: launcher/runtime contract drift:' "$guard"

scratch=$(mktemp -d)
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT HUP INT TERM

for crate in $crates; do
    mkdir -p "$scratch/launcher/vendor/$crate/src" "$scratch/runtime/crates/$crate/src"
    printf 'contract-%s\n' "$crate" > "$scratch/launcher/vendor/$crate/src/lib.rs"
    cp "$scratch/launcher/vendor/$crate/src/lib.rs" "$scratch/runtime/crates/$crate/src/lib.rs"
done

"$guard" "$scratch/launcher" "$scratch/runtime" $crates

printf 'drift\n' >> "$scratch/launcher/vendor/pf-wire/src/lib.rs"
if output=$("$guard" "$scratch/launcher" "$scratch/runtime" $crates 2>&1); then
    echo "FAIL: differing fixture passed the launcher/runtime contract guard" >&2
    exit 1
fi
printf '%s\n' "$output" | grep -qx 'FATAL: launcher/runtime contract drift: pf-wire'

echo "PASS: launcher/runtime contract guard accepts identical trees and rejects drift"
