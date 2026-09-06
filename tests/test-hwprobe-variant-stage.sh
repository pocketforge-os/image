#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="$root/build/Dockerfile.pf"

grep -Fx 'ARG PF_HWPROBE_STAGE=dev' "$dockerfile" >/dev/null
grep -Fx 'FROM ${PF_CONTAINER} AS hwprobe-dev' "$dockerfile" >/dev/null
grep -Fx 'FROM ${PF_CONTAINER} AS hwprobe-release' "$dockerfile" >/dev/null
grep -Fx 'FROM hwprobe-${PF_HWPROBE_STAGE} AS hwprobe' "$dockerfile" >/dev/null
grep -Eq '^COPY --from=hwprobe[[:space:]]+/out[[:space:]]+/work/hwprobe$' "$dockerfile"

release_body="$(sed -n '/^FROM ${PF_CONTAINER} AS hwprobe-release$/,/^FROM hwprobe-${PF_HWPROBE_STAGE} AS hwprobe$/p' "$dockerfile")"
! grep -Eq 'hwprobe-src|sim-src|PF_HWPROBE_SHA|PF_SIM_SHA' <<<"$release_body"

echo 'hwprobe variant stage contract: PASS'
