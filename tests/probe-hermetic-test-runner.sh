#!/bin/sh
set -eu

blocked()
{
    printf 'BLOCKED: missing %s\n' "$1" >&2
    exit 75
}

for tool in bwrap inotifywait systemd; do
    command -v "$tool" >/dev/null 2>&1 || blocked "$tool"
done

printf '%s\n' \
    'hermetic_runner_probe=PASS tools=bwrap,inotifywait,systemd'
