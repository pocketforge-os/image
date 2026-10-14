#!/bin/bash
# Fail closed instead of mixing a new run with evidence from an older run.
set -euo pipefail

out="${1:?usage: require-empty-output.sh OUT}"

if [ -e "$out" ] && [ ! -d "$out" ]; then
	echo "FAIL: input-harness reason=output_not_directory hint=$out exists and is not a directory"
	exit 1
fi
if [ -d "$out" ] && [ -n "$(find "$out" -mindepth 1 -print -quit)" ]; then
	echo "FAIL: input-harness reason=output_not_empty hint=$out contains prior artifacts"
	exit 1
fi

mkdir -p "$out/transcripts" "$out/screenshots"
