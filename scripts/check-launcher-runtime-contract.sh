#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
    echo "usage: $0 LAUNCHER_DIR RUNTIME_DIR CRATE..." >&2
    exit 2
fi

launcher_dir=$1
runtime_dir=$2
shift 2

for crate in "$@"; do
    if ! diff -qr \
        "${launcher_dir}/vendor/${crate}/src" \
        "${runtime_dir}/crates/${crate}/src" >/dev/null; then
        echo "FATAL: launcher/runtime contract drift: ${crate}" >&2
        exit 1
    fi
done
