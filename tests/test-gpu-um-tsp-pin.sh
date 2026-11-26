#!/usr/bin/env bash
set -euo pipefail
EXPECTED_SHA="6d641070c7725389ab3e3f9db94d20109f5a0962"
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
