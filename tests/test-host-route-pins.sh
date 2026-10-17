#!/usr/bin/env bash
# Prove every vendored host-route file still matches the pin its .SOURCE records.
#
# The canonical host-route policy, its conformance cases, the runner-host map and
# its schema, and the inventory scanner itself are copies of files owned by
# another repository. A copy that drifts from its recorded pin silently weakens
# the check, so this test binds each one: the file's sha256 must equal the
# fixture_sha256 in its .SOURCE, and that .SOURCE must name the exact source
# repository, commit and path this repository is pinned to. Re-pinning is a
# deliberate act that has to change the accepted commits below.
#
# Positive and negative controls run in the same invocation: an untouched copy of
# the tree passes, and six corrupted copies (one mutated fixture byte, one mutated
# recorded sha, a superseded source commit, a dropped key, a wrong source path and
# an absent .SOURCE) are each refused for the stated reason. Nothing here opens a
# device, a display, a clipboard or a container.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/image-host-route-pins.XXXXXX")"
cleanup() {
    find "$tmp" -mindepth 1 -delete
    rmdir "$tmp"
}
trap cleanup EXIT

# The commits this repository is pinned to. input-coord sends these; changing one
# is a re-pin and belongs in a reviewed commit together with the new fixtures.
runtime_commit=75f9081d9a3acfa110e8b4d1fe01aa229bfa481f
automation_commit=e064842f7e514fd525290da6ff4352b2c1c02573

# relpath|source_repo|source_path|source_pin_relpath
# A pin file replaces the vendored file's extension, except for the scanner,
# whose own .SOURCE is appended; both spellings are this repository's convention.
pins=(
    "tests/uinput_inventory.py|runtime|tests/uinput_inventory.py|tests/uinput_inventory.py.SOURCE"
    "tests/fixtures/host-route-policy-v1.json|runtime|tests/fixtures/host-route-policy-v1.json|tests/fixtures/host-route-policy-v1.SOURCE"
    "tests/fixtures/host-route-cases-v1.jsonl|runtime|tests/fixtures/host-route-cases-v1.jsonl|tests/fixtures/host-route-cases-v1.SOURCE"
    "tests/fixtures/input-runner-host-map-v1.schema.json|runtime|tests/fixtures/input-runner-host-map-v1.schema.json|tests/fixtures/input-runner-host-map-v1.schema.SOURCE"
    "tests/fixtures/input-runner-host-map-v1.json|pocketforge-automation|config/input-runner-host-map-v1.json|tests/fixtures/input-runner-host-map-v1.SOURCE"
)

source_value() { # source_value <key> <file>
    sed -n "s/^$1=//p" "$2" | sed -n 1p
}

max_bytes=1048576 # every vendored canonical file is far below one MiB

# A pinned input is read and hashed here, so require a bounded regular file
# first: a symlink or a device node would let a tree-controlled name stand in
# for the vendored bytes, and an unbounded one would be read to exhaustion.
bounded_read() { # bounded_read <path> <missing_reason>
    local path="$1" missing="$2" size
    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
        echo "reason=symlink_or_nonregular path=$path" >&2
        return 1
    fi
    if [ ! -f "$path" ]; then
        echo "reason=$missing path=$path" >&2
        return 1
    fi
    size="$(wc -c <"$path" | tr -d ' ')"
    if [ "$size" -gt "$max_bytes" ]; then
        echo "reason=oversized_fixture path=$path size=$size limit=$max_bytes" >&2
        return 1
    fi
    return 0
}

pin_check() { # pin_check <root>: refuse the first pin that does not hold
    local root="$1" entry rel rest repo spath pin source want have key
    for entry in "${pins[@]}"; do
        rel="${entry%%|*}"
        rest="${entry#*|}"
        repo="${rest%%|*}"
        rest="${rest#*|}"
        spath="${rest%%|*}"
        pin="${rest#*|}"
        source="$root/$pin"
        bounded_read "$root/$rel" missing_fixture || return 1
        bounded_read "$source" missing_source || return 1
        for key in source_repo source_commit source_path fixture_sha256; do
            if [ -z "$(source_value "$key" "$source")" ]; then
                echo "reason=missing_key key=$key path=$pin" >&2
                return 1
            fi
        done
        if [ "$(source_value source_repo "$source")" != "$repo" ]; then
            echo "reason=wrong_source_repo path=$pin" >&2
            return 1
        fi
        if [ "$(source_value source_path "$source")" != "$spath" ]; then
            echo "reason=wrong_source_path path=$pin" >&2
            return 1
        fi
        case "$repo" in
        runtime) want="$runtime_commit" ;;
        pocketforge-automation) want="$automation_commit" ;;
        *)
            echo "reason=unknown_source_repo repo=$repo path=$pin" >&2
            return 1
            ;;
        esac
        have="$(source_value source_commit "$source")"
        if [ "$have" != "$want" ]; then
            echo "reason=unexpected_source_commit have=$have want=$want path=$pin" >&2
            return 1
        fi
        have="$(sha256sum "$root/$rel" | cut -d' ' -f1)"
        want="$(source_value fixture_sha256 "$source")"
        if [ "$have" != "$want" ]; then
            echo "reason=fixture_sha_mismatch path=$rel" >&2
            return 1
        fi
    done
    return 0
}

copy_pins() { # copy_pins <dir>: lay out an untouched copy of the pinned pairs
    local dir="$1" entry rel pin
    mkdir -p "$dir"
    for entry in "${pins[@]}"; do
        rel="${entry%%|*}"
        pin="${entry##*|}"
        mkdir -p "$dir/$(dirname "$rel")" "$dir/$(dirname "$pin")"
        cp "$repo_root/$rel" "$dir/$rel"
        cp "$repo_root/$pin" "$dir/$pin"
    done
}

mutant() { # mutant <name> <expected reason> <mutator>
    local name="$1" want="$2" mutator="$3" dir out
    dir="$tmp/$name"
    copy_pins "$dir"
    (cd "$dir" && "$mutator")
    if out="$(pin_check "$dir" 2>&1)"; then
        echo "FAIL: mutant $name passed the pin check" >&2
        exit 1
    fi
    case "$out" in
    *"$want"*) ;;
    *)
        echo "FAIL: mutant $name reported '$out', expected $want" >&2
        exit 1
        ;;
    esac
}

mut_fixture_byte() { printf 'x' >>tests/fixtures/host-route-policy-v1.json; }
mut_source_sha() {
    sed -i 's/^fixture_sha256=.*/fixture_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
        tests/fixtures/host-route-cases-v1.SOURCE
}
mut_stale_commit() {
    sed -i 's/^source_commit=.*/source_commit=0b1b5d094e173cee3b96399e489d0bf549fdb706/' \
        tests/uinput_inventory.py.SOURCE
}
mut_missing_key() { sed -i '/^fixture_sha256=/d' tests/fixtures/input-runner-host-map-v1.schema.SOURCE; }
mut_wrong_path() {
    sed -i 's|^source_path=.*|source_path=docs/host-route-policy.md|' \
        tests/fixtures/host-route-policy-v1.SOURCE
}
mut_absent_source() { find tests/fixtures -maxdepth 1 -name 'input-runner-host-map-v1.SOURCE' -delete; }
mut_symlink_device() {
    find tests/fixtures -maxdepth 1 -name host-route-policy-v1.json -delete
    ln -s /dev/zero tests/fixtures/host-route-policy-v1.json
}
mut_oversized() {
    head -c "$((max_bytes + 1))" /dev/zero | tr '\0' 'x' >tests/fixtures/host-route-cases-v1.jsonl
}

pin_check "$repo_root"

good="$tmp/good"
copy_pins "$good"
pin_check "$good"

mutant fixture-byte reason=fixture_sha_mismatch mut_fixture_byte
mutant source-sha reason=fixture_sha_mismatch mut_source_sha
mutant stale-commit reason=unexpected_source_commit mut_stale_commit
mutant missing-key reason=missing_key mut_missing_key
mutant wrong-path reason=wrong_source_path mut_wrong_path
mutant absent-source reason=missing_source mut_absent_source
mutant symlink-device reason=symlink_or_nonregular mut_symlink_device
mutant oversized reason=oversized_fixture mut_oversized

echo "host-route-pins: PASS pairs=${#pins[@]} repo_tree=green good_copy=green" \
    "fixture_byte=red source_sha=red stale_commit=red missing_key=red" \
    "wrong_path=red absent_source=red symlink_device=red oversized=red"
