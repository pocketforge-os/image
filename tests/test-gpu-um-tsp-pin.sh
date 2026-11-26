#!/usr/bin/env bash
set -euo pipefail
EXPECTED_SHA="bd2d7a745cfad6efa4071ede99fe6fe91f4d95f7"
LOCK_FILE="platform.lock"
if [ ! -f "$LOCK_FILE" ]; then
  LOCK_FILE="platform/platform.lock"
fi
ACTUAL_SHA=$(grep -A1 'name.*=.*"gpu-um-tsp"' "$LOCK_FILE" | grep 'sha' | sed 's/.*"\([0-9a-f]*\)".*/\1/')
if [ -z "$ACTUAL_SHA" ]; then
  echo "FAIL: gpu-um-tsp sha not found in $LOCK_FILE"
  exit 1
fi
if [ "${ACTUAL_SHA:0:10}" != "${EXPECTED_SHA:0:10}" ]; then
  echo "FAIL: gpu-um-tsp sha is $ACTUAL_SHA, expected $EXPECTED_SHA"
  exit 1
fi
echo "PASS: gpu-um-tsp pinned at ${ACTUAL_SHA:0:10}"
exit 0
