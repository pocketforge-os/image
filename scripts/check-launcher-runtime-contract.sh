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


include_re = re.compile(r'include_(?:bytes|str)!\s*\(\s*"([^"\\]*)"\s*\)')
# Check both the materialized vendor source and the canonical runtime source at
# its corresponding vendor location. The latter proves that an include survives
# vendoring without relying on a refresh-time path rewrite to hide an escape.
for source_root in (crate_dir, runtime_crate_dir):
    for original_source in sorted(source_root.rglob("*.rs")):
        source = crate_dir / original_source.relative_to(source_root)
        text = original_source.read_text(encoding="utf-8")
        for match in include_re.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            check(source, line, match.group(1))

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
