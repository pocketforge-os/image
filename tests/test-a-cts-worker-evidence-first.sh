#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec "$ROOT/tools/a-cts-recovery/test-worker-evidence-first.sh"
