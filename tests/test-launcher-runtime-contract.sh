#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
guard="${repo_root}/scripts/check-launcher-runtime-contract.sh"
dockerfile="${repo_root}/build/Dockerfile.pf"
crates="pf-app-launch pf-app-manifest pf-scene pf-ports pf-render pf-framehost pf-framehost-wayland pf-theme pf-input-map pf-prefs pf-prefs-port pf-session-client pf-session-authority pf-wire"

guard_call=$(sed -n \
    '/^check-launcher-runtime-contract \/work\/launcher \/work\/runtime-contract/,/pf-session-authority pf-wire$/p' \
    "$dockerfile" | tr -d '\\')
set -- $guard_call
test "$1 $2 $3" = "check-launcher-runtime-contract /work/launcher /work/runtime-contract"
shift 3
test "$*" = "$crates"
grep -q 'COPY --from=runtime-src . /work/runtime-contract' "$dockerfile"
grep -q 'FATAL: launcher/runtime contract drift:' "$guard"
# tsp-f3fm.223 moves the launcher alone: launcher#148 (merged d26dfa11 -> ca22de0e)
# changed only pf-shell (the d-pad hat, ABS_HAT0X/Y, now navigates); its vendored
# runtime crates are byte-identical to d26dfa11's, so runtime 7536aa1f stays the
# co-pin. The previous image guard accepted (7536aa1f, d26dfa11). The new guard
# refuses the old launcher (it ignores the d-pad hat), the pre-#147 launcher (it
# drops the first A after a return), the pre-#146, pre-#145 and older launchers,
# and the pre-tsp-f3fm.219 runtime 0955d8a8.
expected_runtime=7536aa1f5af76f0220b582ee68e29e254251fd76
expected_launcher=ca22de0ed3cec46c73f2de44aa6e570e109695d8
old_launcher=d26dfa1162e601100c3a18956b5ce4a2ddc7427f
pre147_launcher=7a2b792d0813fc8fb5c2915bdc00ef976b0cc986
prior_runtime=0955d8a83ee59df89eaba79ffee9e99e4f52384c
pre146_launcher=96feb08c110b090f85d822c9f69e52b407103ad5
pre145_launcher=1e5a3d971ec7e8d425deea4bf0d8cbed39ba0c77
older_launcher=bb8c9bc8c9ea15238d08cfee5376049bf67cf855

runtime_guard=$(sed -n 's/^\[ "${PF_RUNTIME_SHA}" = "\([0-9a-f]\{40\}\)" \].*/\1/p' "$dockerfile")
launcher_guard=$(sed -n 's/^\[ "${PF_LAUNCHER_SHA}" = "\([0-9a-f]\{40\}\)" \].*/\1/p' "$dockerfile")
test "$runtime_guard" = "$expected_runtime"
test "$launcher_guard" = "$expected_launcher"

new_guard_accepts() {
    test "$1" = "$runtime_guard" && test "$2" = "$launcher_guard"
}
old_guard_accepts() {
    test "$1" = "$expected_runtime" && test "$2" = "$old_launcher"
}

# Each guard accepts exactly its own (runtime, launcher) pair: the new image
# refuses the old launcher, the pre-#147, pre-#146, pre-#145 and older launchers,
# and the pre-tsp-f3fm.219 runtime; the old image refuses the new launcher. So the
# lock must move image and launcher together.
new_guard_accepts "$expected_runtime" "$expected_launcher"
! new_guard_accepts "$expected_runtime" "$old_launcher"
! new_guard_accepts "$prior_runtime" "$expected_launcher"
! new_guard_accepts "$expected_runtime" "$pre147_launcher"
! new_guard_accepts "$expected_runtime" "$pre146_launcher"
! new_guard_accepts "$expected_runtime" "$pre145_launcher"
! new_guard_accepts "$expected_runtime" "$older_launcher"
old_guard_accepts "$expected_runtime" "$old_launcher"
! old_guard_accepts "$expected_runtime" "$expected_launcher"
! old_guard_accepts "$prior_runtime" "$old_launcher"
! old_guard_accepts "$expected_runtime" "$pre147_launcher"
! old_guard_accepts "$expected_runtime" "$pre146_launcher"
! old_guard_accepts "$expected_runtime" "$pre145_launcher"
! old_guard_accepts "$expected_runtime" "$older_launcher"

grep -F -- '--no-default-features -p pf-shell' "$dockerfile" >/dev/null
if grep -E 'cargo build .*--features[ =][^#]*(desktop-sim)' "$dockerfile"; then
    echo 'FAIL: production launcher build enables the test-only desktop-sim feature' >&2
    exit 1
fi

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

# A missing vendored crate must fail cleanly at the shell boundary. In
# particular, do not enter the reference scanner with absent Cargo/source paths
# and leak a Python traceback before the remaining crates are audited.
mv "$scratch/launcher/vendor/pf-app-launch" "$scratch/pf-app-launch-missing"
if output=$("$guard" "$scratch/launcher" "$scratch/runtime" $crates 2>&1); then
    echo "FAIL: missing vendored crate passed the launcher/runtime contract guard" >&2
    exit 1
fi
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: launcher/runtime contract drift: pf-app-launch'
if printf '%s\n' "$output" | grep -Fq 'Traceback'; then
    echo "FAIL: missing vendored crate leaked a Python traceback" >&2
    exit 1
fi
mv "$scratch/pf-app-launch-missing" "$scratch/launcher/vendor/pf-app-launch"

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

# Raw Rust strings are live include syntax, while identical-looking text in line,
# nested block comments, and strings is not. Exercise both verdicts together.
printf '%s\n' \
    'const RAW_MISSING: &str = include_str!(r"../raw-missing");' \
    'const HASHED_RAW_MISSING: &str = include_str!(r#"../hashed-raw-missing"#);' \
    'const ESCAPED_MISSING: &str = include_str!("..\x2fescaped-missing");' \
    'const BRACE_MISSING: &str = include_str!{"../brace-missing"};' \
    'const BRACKET_MISSING: &[u8] = include_bytes!["../bracket-missing"];' \
    'const COMMA_MISSING: &str = include_str!("../comma-missing",);' \
    'const MULTILINE_MISSING: &str = include_str!(' \
    '  "../multiline-missing"' \
    ');' \
    '// include_str!("../line-comment-missing")' \
    '/* outer /* include_str!("../nested-comment-missing") */ still comment */' \
    'const EXAMPLE: &str = "include_str!(\\"../string-missing\\")";' \
    >> "$scratch/launcher/vendor/pf-scene/src/lib.rs"
cp "$scratch/launcher/vendor/pf-scene/src/lib.rs" "$scratch/runtime/crates/pf-scene/src/lib.rs"
if output=$("$guard" "$scratch/launcher" "$scratch/runtime" pf-scene 2>&1); then
    echo "FAIL: dangling raw-string includes passed the launcher/runtime contract guard" >&2
    exit 1
fi
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: unresolved vendored reference: pf-scene: pf-scene/src/lib.rs:2: ../raw-missing'
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: unresolved vendored reference: pf-scene: pf-scene/src/lib.rs:3: ../hashed-raw-missing'
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: unresolved vendored reference: pf-scene: pf-scene/src/lib.rs:4: ../escaped-missing'
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: unresolved vendored reference: pf-scene: pf-scene/src/lib.rs:5: ../brace-missing'
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: unresolved vendored reference: pf-scene: pf-scene/src/lib.rs:6: ../bracket-missing'
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: unresolved vendored reference: pf-scene: pf-scene/src/lib.rs:7: ../comma-missing'
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: unresolved vendored reference: pf-scene: pf-scene/src/lib.rs:8: ../multiline-missing'
printf '%s\n' "$output" | grep -Fqx \
    'INFO: unrecognized vendored include forms: pf-scene: 0'
test "$(printf '%s\n' "$output" | grep -c '^FATAL: unresolved vendored reference:')" -eq 7
test "$(printf '%s\n' "$output" | grep -c '^FATAL: unverifiable vendored include form:')" -eq 0

# Removing the seven live macros leaves only non-code lookalikes, which must pass.
sed -i '2,10d' "$scratch/launcher/vendor/pf-scene/src/lib.rs"
cp "$scratch/launcher/vendor/pf-scene/src/lib.rs" "$scratch/runtime/crates/pf-scene/src/lib.rs"
"$guard" "$scratch/launcher" "$scratch/runtime" pf-scene

# An otherwise clean generated include must fail on the true proposition that it
# cannot be verified. A direct resolvable literal beside it remains independently
# traced as resolved and must not contaminate the failure reason.
printf '%s\n' \
    'const GENERATED: &str = include_str!(concat!("../", "outside.txt"));' \
    'const PRESENT: &str = include_str!("../present.txt");' \
    >> "$scratch/launcher/vendor/pf-theme/src/lib.rs"
cp "$scratch/launcher/vendor/pf-theme/src/lib.rs" "$scratch/runtime/crates/pf-theme/src/lib.rs"
printf 'present\n' > "$scratch/launcher/vendor/pf-theme/present.txt"
if output=$(PF_CONTRACT_TRACE_REFERENCES=1 \
    "$guard" "$scratch/launcher" "$scratch/runtime" pf-theme 2>&1); then
    echo "FAIL: unverifiable generated include passed the launcher/runtime contract guard" >&2
    exit 1
fi
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: unverifiable vendored include form: pf-theme: pf-theme/src/lib.rs:2'
printf '%s\n' "$output" | grep -Fqx \
    'RESOLVED: pf-theme: pf-theme/src/lib.rs:3: ../present.txt'
printf '%s\n' "$output" | grep -Fqx \
    'INFO: unrecognized vendored include forms: pf-theme: 1'
test "$(printf '%s\n' "$output" | grep -c '^FATAL: unverifiable vendored include form:')" -eq 1
test "$(printf '%s\n' "$output" | grep -c '^FATAL: unresolved vendored reference:')" -eq 0

# Existing nodes are not sufficient: Rust includes require readable regular
# files, while Cargo path dependencies require crate directories with manifests.
printf '%s\n' \
    'const DIRECTORY: &str = include_str!("../fixtures/directory.bin");' \
    'const PRESENT: &str = include_str!("../fixtures/present.txt");' \
    >> "$scratch/launcher/vendor/pf-prefs/src/lib.rs"
cp "$scratch/launcher/vendor/pf-prefs/src/lib.rs" "$scratch/runtime/crates/pf-prefs/src/lib.rs"
mkdir -p \
    "$scratch/launcher/vendor/pf-prefs/fixtures/directory.bin" \
    "$scratch/launcher/vendor/not-a-crate"
printf 'present\n' > "$scratch/launcher/vendor/pf-prefs/fixtures/present.txt"
printf 'not a crate\n' > "$scratch/launcher/vendor/path-is-file"
printf '%s\n' \
    '[dependencies]' \
    'file = { path = "../path-is-file" }' \
    'no_manifest = { path = "../not-a-crate" }' \
    'present = { path = "../pf-scene" }' \
    >> "$scratch/launcher/vendor/pf-prefs/Cargo.toml"
cp "$scratch/launcher/vendor/pf-prefs/Cargo.toml" "$scratch/runtime/crates/pf-prefs/Cargo.toml"
if output=$(PF_CONTRACT_TRACE_REFERENCES=1 \
    "$guard" "$scratch/launcher" "$scratch/runtime" pf-prefs 2>&1); then
    echo "FAIL: wrong-type vendored targets passed the launcher/runtime contract guard" >&2
    exit 1
fi
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: invalid vendored include target: pf-prefs: pf-prefs/src/lib.rs:2: ../fixtures/directory.bin: resolves to a directory, not a readable file'
printf '%s\n' "$output" | grep -Fqx \
    'RESOLVED: pf-prefs: pf-prefs/src/lib.rs:3: ../fixtures/present.txt'
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: invalid vendored Cargo path dependency: pf-prefs: pf-prefs/Cargo.toml:5: ../path-is-file: resolves to a file, not a crate directory'
printf '%s\n' "$output" | grep -Fqx \
    'FATAL: invalid vendored Cargo path dependency: pf-prefs: pf-prefs/Cargo.toml:6: ../not-a-crate: resolves to a directory with no Cargo.toml'
printf '%s\n' "$output" | grep -Fqx \
    'RESOLVED: pf-prefs: pf-prefs/Cargo.toml:7: ../pf-scene'
test "$(printf '%s\n' "$output" | grep -c '^FATAL: invalid vendored include target:')" -eq 1
test "$(printf '%s\n' "$output" | grep -c '^FATAL: invalid vendored Cargo path dependency:')" -eq 2
test "$(printf '%s\n' "$output" | grep -c '^FATAL: unresolved vendored reference:')" -eq 0

echo "PASS: launcher/runtime contract guard accepts identical trees, rejects drift, and distinguishes resolved from dangling references"
