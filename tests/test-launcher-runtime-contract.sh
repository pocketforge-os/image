#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
guard="${repo_root}/scripts/check-launcher-runtime-contract.sh"
dockerfile="${repo_root}/build/Dockerfile.pf"
crates="pf-scene pf-ports pf-render pf-framehost pf-framehost-wayland pf-theme pf-input-map pf-prefs pf-prefs-port pf-session-client pf-session-authority pf-wire"

guard_call=$(sed -n \
    '/^check-launcher-runtime-contract \/work\/launcher \/work\/runtime-contract/,/pf-session-authority pf-wire$/p' \
    "$dockerfile" | tr -d '\\')
set -- $guard_call
test "$1 $2 $3" = "check-launcher-runtime-contract /work/launcher /work/runtime-contract"
shift 3
test "$*" = "$crates"
grep -q 'COPY --from=runtime-src . /work/runtime-contract' "$dockerfile"
grep -q 'FATAL: launcher/runtime contract drift:' "$guard"
grep -F '[ "${PF_LAUNCHER_SHA}" = "bb8c9bc8c9ea15238d08cfee5376049bf67cf855" ] || { echo "FATAL: F13 launcher pin drift: ${PF_LAUNCHER_SHA}"; exit 1; }' "$dockerfile" >/dev/null
grep -F '[ "${PF_RUNTIME_SHA}" = "a2f149caef326215ce0bff7d0d076bac292595d4" ] || { echo "FATAL: runtime pin drift: ${PF_RUNTIME_SHA}"; exit 1; }' "$dockerfile" >/dev/null

scratch=$(mktemp -d)
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT HUP INT TERM

for crate in $crates; do
    mkdir -p "$scratch/launcher/vendor/$crate/src" "$scratch/runtime/crates/$crate/src"
    printf 'contract-%s\n' "$crate" > "$scratch/launcher/vendor/$crate/src/lib.rs"
    printf '[package]\nname = "%s"\nversion = "0.0.0"\n' "$crate" > "$scratch/launcher/vendor/$crate/Cargo.toml"
    cp "$scratch/launcher/vendor/$crate/src/lib.rs" "$scratch/runtime/crates/$crate/src/lib.rs"
    cp "$scratch/launcher/vendor/$crate/Cargo.toml" "$scratch/runtime/crates/$crate/Cargo.toml"
done

"$guard" "$scratch/launcher" "$scratch/runtime" $crates

printf 'drift\n' >> "$scratch/launcher/vendor/pf-wire/src/lib.rs"
if output=$("$guard" "$scratch/launcher" "$scratch/runtime" $crates 2>&1); then
    echo "FAIL: differing fixture passed the launcher/runtime contract guard" >&2
    exit 1
fi
printf '%s\n' "$output" | grep -qx 'FATAL: launcher/runtime contract drift: pf-wire'

# Exercise both reference outcomes in one guard invocation: one real file must
# resolve while a missing file must fail with actionable source coordinates.
cp "$scratch/runtime/crates/pf-wire/src/lib.rs" "$scratch/launcher/vendor/pf-wire/src/lib.rs"
printf '%s\n' \
    'const PRESENT: &str = include_str!("../tests/fixtures/present.txt");' \
    'const MISSING: &[u8] = include_bytes!("../tests/fixtures/missing.bin");' \
    >> "$scratch/launcher/vendor/pf-wire/src/lib.rs"
cp "$scratch/launcher/vendor/pf-wire/src/lib.rs" "$scratch/runtime/crates/pf-wire/src/lib.rs"
mkdir -p "$scratch/launcher/vendor/pf-wire/tests/fixtures"
printf 'present\n' > "$scratch/launcher/vendor/pf-wire/tests/fixtures/present.txt"
printf '%s\n' \
    '[dependencies]' \
    'present = { path = "../pf-scene" }' \
    'missing = { path = "../missing-crate" }' \
    >> "$scratch/launcher/vendor/pf-session-client/Cargo.toml"
printf '%s\n' \
    '[dependencies]' \
    'present = { path = "../pf-scene" }' \
    'missing = { path = "../../../outside" }' \
    >> "$scratch/runtime/crates/pf-wire/Cargo.toml"
if output=$(PF_CONTRACT_TRACE_REFERENCES=1 \
    "$guard" "$scratch/launcher" "$scratch/runtime" $crates 2>&1); then
    echo "FAIL: dangling include fixture passed the launcher/runtime contract guard" >&2
    exit 1
fi
printf '%s\n' "$output" | grep -Fqx \
    'RESOLVED: pf-wire: pf-wire/src/lib.rs:2: ../tests/fixtures/present.txt'
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: unresolved vendored reference: pf-wire: pf-wire/src/lib.rs:3: ../tests/fixtures/missing.bin'
printf '%s\n' "$output" | grep -Fqx \
    'RESOLVED: pf-session-client: pf-session-client/Cargo.toml:5: ../pf-scene'
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: unresolved vendored reference: pf-session-client: pf-session-client/Cargo.toml:6: ../missing-crate'
printf '%s\n' "$output" | grep -Fqx \
    'RESOLVED: pf-wire: pf-wire/Cargo.toml:5: ../pf-scene'
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: unresolved vendored reference: pf-wire: pf-wire/Cargo.toml:6: ../../../outside'
test "$(printf '%s\n' "$output" | grep -c '^FATAL: unresolved vendored reference:')" -eq 3

echo "PASS: launcher/runtime contract guard accepts identical trees, rejects drift, and distinguishes resolved from dangling references"
