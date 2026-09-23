#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
    echo "usage: $0 LAUNCHER_DIR RUNTIME_DIR CRATE..." >&2
    exit 2
fi

launcher_dir=$1
runtime_dir=$2
shift 2

status=0
for crate in "$@"; do
    if ! diff -qr \
        "${launcher_dir}/vendor/${crate}/src" \
        "${runtime_dir}/crates/${crate}/src" >/dev/null; then
        echo "FATAL: launcher/runtime contract drift: ${crate}" >&2
        status=1
    fi

    if ! python3 - "${launcher_dir}/vendor" "${runtime_dir}/crates" "$crate" <<'PY'
import os
import re
import sys
import tomllib
from pathlib import Path

vendor = Path(sys.argv[1]).resolve()
runtime_crates = Path(sys.argv[2]).resolve()
crate = sys.argv[3]
crate_dir = vendor / crate
runtime_crate_dir = runtime_crates / crate
trace = os.environ.get("PF_CONTRACT_TRACE_REFERENCES") == "1"
failed = False
checked = set()
unrecognized = set()


def check(source: Path, line: int, target_text: str) -> None:
    global failed
    key = (source, line, target_text)
    if key in checked:
        return
    checked.add(key)
    target = (source.parent / target_text).resolve()
    try:
        target.relative_to(vendor)
        inside_vendor = True
    except ValueError:
        inside_vendor = False

    source_name = source.relative_to(vendor)
    if inside_vendor and target.exists():
        if trace:
            print(
                f"RESOLVED: {crate}: {source_name}:{line}: {target_text}",
                file=sys.stderr,
            )
        return

    print(
        f"FATAL: unresolved vendored reference: {crate}: "
        f"{source_name}:{line}: {target_text}",
        file=sys.stderr,
    )
    failed = True


def skip_block_comment(text: str, start: int) -> int:
    depth = 1
    cursor = start + 2
    while cursor < len(text) and depth:
        if text.startswith("/*", cursor):
            depth += 1
            cursor += 2
        elif text.startswith("*/", cursor):
            depth -= 1
            cursor += 2
        else:
            cursor += 1
    return cursor


def raw_string_end(text: str, start: int):
    cursor = start
    if text.startswith("br", cursor):
        cursor += 1
    if cursor >= len(text) or text[cursor] != "r":
        return None
    cursor += 1
    hashes = 0
    while cursor < len(text) and text[cursor] == "#":
        hashes += 1
        cursor += 1
    if cursor >= len(text) or text[cursor] != '"':
        return None
    content_start = cursor + 1
    terminator = '"' + "#" * hashes
    content_end = text.find(terminator, content_start)
    if content_end < 0:
        return len(text), text[content_start:]
    return content_end + len(terminator), text[content_start:content_end]


def normal_string_end(text: str, start: int):
    quote = start + (1 if text.startswith('b"', start) else 0)
    if quote >= len(text) or text[quote] != '"':
        return None
    cursor = quote + 1
    value = []
    escapes = {
        "0": "\0",
        "t": "\t",
        "n": "\n",
        "r": "\r",
        '"': '"',
        "'": "'",
        "\\": "\\",
    }
    while cursor < len(text):
        char = text[cursor]
        if char == '"':
            return cursor + 1, "".join(value)
        if char != "\\":
            value.append(char)
            cursor += 1
            continue
        cursor += 1
        if cursor >= len(text):
            break
        escape = text[cursor]
        if escape in escapes:
            value.append(escapes[escape])
            cursor += 1
        elif escape == "x" and cursor + 2 < len(text):
            value.append(chr(int(text[cursor + 1:cursor + 3], 16)))
            cursor += 3
        elif escape == "u" and cursor + 1 < len(text) and text[cursor + 1] == "{":
            end = text.find("}", cursor + 2)
            if end < 0:
                break
            value.append(chr(int(text[cursor + 2:end].replace("_", ""), 16)))
            cursor = end + 1
        elif escape == "\n":
            cursor += 1
            while cursor < len(text) and text[cursor] in " \t\n\r":
                cursor += 1
        else:
            # Invalid Rust is left to rustc; retaining the escaped character makes
            # this audit fail closed instead of silently discarding the reference.
            value.extend(("\\", escape))
            cursor += 1
    return len(text), "".join(value)


def char_literal_end(text: str, start: int):
    quote = start + (1 if text.startswith("b'", start) else 0)
    if quote >= len(text) or text[quote] != "'":
        return None
    cursor = quote + 1
    if cursor >= len(text):
        return None
    if text[cursor] == "\\":
        cursor += 2
        if cursor <= len(text) and text[cursor - 1] == "u" and cursor < len(text) and text[cursor] == "{":
            end = text.find("}", cursor + 1)
            if end < 0:
                return None
            cursor = end + 1
        elif cursor <= len(text) and text[cursor - 1] == "x":
            cursor += 2
    else:
        cursor += 1
    if cursor < len(text) and text[cursor] == "'":
        return cursor + 1
    return None


def skip_trivia(text: str, start: int) -> int:
    cursor = start
    while cursor < len(text):
        if text[cursor].isspace():
            cursor += 1
        elif text.startswith("//", cursor):
            newline = text.find("\n", cursor + 2)
            cursor = len(text) if newline < 0 else newline + 1
        elif text.startswith("/*", cursor):
            cursor = skip_block_comment(text, cursor)
        else:
            break
    return cursor


# Recognised Rust syntax: direct include_bytes!/include_str! invocations using
# balanced (), [] or {} delimiters and exactly one ordinary or raw string literal,
# optionally followed by one trailing comma. Ordinary strings include escapes;
# raw strings allow any hash count; both forms may be byte strings. Whitespace,
# comments, newlines and nested delimiter groups are handled while finding the
# invocation boundary. The scanner excludes line comments, nested block comments,
# string/byte-string and character/byte-character literals; apostrophes that are
# not complete character literals are treated as lifetimes. Direct literal
# includes inside macro_rules! bodies and cfg-gated code are intentionally still
# checked because vendoring must preserve every source reference, regardless of
# whether this build expands it.
#
# Not recognised: paths constructed by concat!/env!/stringify!, include macros
# reached through an alias or re-export, #[path] attributes, or other generated
# syntax. Those direct include invocations fail as unverifiable rather than being
# silently treated as clean or falsely labelled unresolved. Resolving them
# requires macro expansion/a Rust compiler, which is not available at this
# pre-toolchain build stage. A legitimate generated include must therefore be
# made directly resolvable or the scanner must be extended; the counter must not
# be silenced.
def balanced_group_end(text: str, opener: int):
    closers = {"(": ")", "[": "]", "{": "}"}
    stack = [closers[text[opener]]]
    cursor = opener + 1
    while cursor < len(text):
        if text.startswith("//", cursor):
            newline = text.find("\n", cursor + 2)
            cursor = len(text) if newline < 0 else newline + 1
            continue
        if text.startswith("/*", cursor):
            cursor = skip_block_comment(text, cursor)
            continue
        raw = raw_string_end(text, cursor)
        if raw is not None:
            cursor = raw[0]
            continue
        normal = normal_string_end(text, cursor)
        if normal is not None:
            cursor = normal[0]
            continue
        char_end = char_literal_end(text, cursor)
        if char_end is not None:
            cursor = char_end
            continue
        if text[cursor] in closers:
            stack.append(closers[text[cursor]])
        elif text[cursor] == stack[-1]:
            stack.pop()
            if not stack:
                return cursor
        cursor += 1
    return None


def rust_includes(text: str):
    cursor = 0
    while cursor < len(text):
        if text.startswith("//", cursor):
            newline = text.find("\n", cursor + 2)
            cursor = len(text) if newline < 0 else newline + 1
            continue
        if text.startswith("/*", cursor):
            cursor = skip_block_comment(text, cursor)
            continue

        raw = raw_string_end(text, cursor)
        if raw is not None:
            cursor = raw[0]
            continue
        normal = normal_string_end(text, cursor)
        if normal is not None:
            cursor = normal[0]
            continue

        if text[cursor].isalpha() or text[cursor] == "_":
            identifier_start = cursor
            cursor += 1
            while cursor < len(text) and (text[cursor].isalnum() or text[cursor] == "_"):
                cursor += 1
            identifier = text[identifier_start:cursor]
            if identifier not in ("include_bytes", "include_str"):
                continue
            after_name = skip_trivia(text, cursor)
            if after_name >= len(text) or text[after_name] != "!":
                continue
            after_bang = skip_trivia(text, after_name + 1)
            if after_bang >= len(text) or text[after_bang] not in "([{":
                continue
            group_end = balanced_group_end(text, after_bang)
            if group_end is None:
                yield identifier_start, None
                cursor = after_bang + 1
                continue
            literal_start = skip_trivia(text, after_bang + 1)
            literal = raw_string_end(text, literal_start)
            if literal is None:
                literal = normal_string_end(text, literal_start)
            if literal is not None:
                literal_end = skip_trivia(text, literal[0])
                if literal_end < group_end and text[literal_end] == ",":
                    literal_end = skip_trivia(text, literal_end + 1)
            if literal is not None and literal_end == group_end:
                yield identifier_start, literal[1]
            else:
                yield identifier_start, None
            cursor = group_end + 1
            continue

        # Character literals can contain comment delimiters. A Rust lifetime
        # also starts with an apostrophe, so only skip a lexically complete char.
        char_end = char_literal_end(text, cursor)
        if char_end is not None:
            cursor = char_end
            continue
        cursor += 1


# Check both the materialized vendor source and the canonical runtime source at
# its corresponding vendor location. The latter proves that an include survives
# vendoring without relying on a refresh-time path rewrite to hide an escape.
for source_root in (crate_dir, runtime_crate_dir):
    for original_source in sorted(source_root.rglob("*.rs")):
        source = crate_dir / original_source.relative_to(source_root)
        text = original_source.read_text(encoding="utf-8")
        for offset, target_text in rust_includes(text):
            line = text.count("\n", 0, offset) + 1
            if target_text is None:
                key = (source, line)
                if key not in unrecognized:
                    unrecognized.add(key)
                    print(
                        f"FATAL: unverifiable vendored include form: {crate}: "
                        f"{source.relative_to(vendor)}:{line}",
                        file=sys.stderr,
                    )
                    failed = True
            else:
                check(source, line, target_text)

print(
    f"INFO: unrecognized vendored include forms: {crate}: {len(unrecognized)}",
    file=sys.stderr,
)

def dependencies(table: object):
    if not isinstance(table, dict):
        return
    for value in table.values():
        if isinstance(value, dict) and isinstance(value.get("path"), str):
            yield value["path"]


for source_root in (crate_dir, runtime_crate_dir):
    original_cargo_toml = source_root / "Cargo.toml"
    cargo_toml = crate_dir / "Cargo.toml"
    with original_cargo_toml.open("rb") as stream:
        manifest = tomllib.load(stream)
    manifest_lines = original_cargo_toml.read_text(encoding="utf-8").splitlines()

    path_values = list(dependencies(manifest.get("dependencies")))
    path_values += list(dependencies(manifest.get("dev-dependencies")))
    path_values += list(dependencies(manifest.get("build-dependencies")))
    for target_table in manifest.get("target", {}).values():
        path_values += list(dependencies(target_table.get("dependencies")))
        path_values += list(dependencies(target_table.get("dev-dependencies")))
        path_values += list(dependencies(target_table.get("build-dependencies")))

    for target_text in path_values:
        path_re = re.compile(
            r'\bpath\s*=\s*["\']' + re.escape(target_text) + r'["\']'
        )
        line = next(
            (
                number
                for number, text in enumerate(manifest_lines, 1)
                if path_re.search(text)
            ),
            1,
        )
        check(cargo_toml, line, target_text)

raise SystemExit(1 if failed else 0)
PY
    then
        status=1
    fi
done

exit "$status"
