#!/usr/bin/env bash
# Assert the kubo pin is consistent across image/kubo.pin, the base Dockerfile, and the
# vendor-manifest manifest.toml. Fail-closed (tsp-1dl.3). Wire into image CI + pf build
# pre-build checks. manifest.toml reaches CI via the vendor-manifest-src build context
# (or a pinned checkout).
set -euo pipefail
PIN="${1:-image/kubo.pin}"
MANIFEST="${2:-manifest.toml}"          # vendor-manifest manifest.toml (build context)
DOCKERFILE="${3:-image/build/Dockerfile}"
val(){ sed -n "s/^$1=//p" "$PIN" | tr -d ' '; }
PIN_VER="$(val kubo_version)"; PIN_BSHA="$(val kubo_binary_sha256)"; PIN_TSHA="$(val kubo_tarball_sha512)"
[ -n "$PIN_VER" ] && [ -n "$PIN_BSHA" ] && [ -n "$PIN_TSHA" ] || { echo "lint-kubo-pin: kubo.pin missing a field" >&2; exit 1; }
MAN_VER="$(sed -n 's/^[[:space:]]*kubo_version[[:space:]]*=[[:space:]]*"\?\([^"]*\)"\?.*/\1/p' "$MANIFEST" | head -1)"
[ "$PIN_VER" = "$MAN_VER" ] || { echo "lint-kubo-pin: FAIL kubo_version drift: kubo.pin=$PIN_VER manifest.toml=$MAN_VER" >&2; exit 1; }
if [ -f "$DOCKERFILE" ]; then
  DF_VER="$(sed -n 's/^ARG KUBO_VERSION=//p' "$DOCKERFILE" | head -1)"
  DF_BSHA="$(sed -n 's/^ARG KUBO_BINARY_SHA256=//p' "$DOCKERFILE" | head -1)"
  DF_TSHA="$(sed -n 's/^ARG KUBO_TARBALL_SHA512=//p' "$DOCKERFILE" | head -1)"
  [ -z "$DF_VER"  ] || [ "$DF_VER"  = "$PIN_VER"  ] || { echo "lint-kubo-pin: FAIL Dockerfile KUBO_VERSION=$DF_VER != pin $PIN_VER" >&2; exit 1; }
  [ -z "$DF_BSHA" ] || [ "$DF_BSHA" = "$PIN_BSHA" ] || { echo "lint-kubo-pin: FAIL Dockerfile KUBO_BINARY_SHA256 != pin" >&2; exit 1; }
  [ -z "$DF_TSHA" ] || [ "$DF_TSHA" = "$PIN_TSHA" ] || { echo "lint-kubo-pin: FAIL Dockerfile KUBO_TARBALL_SHA512 != pin" >&2; exit 1; }
fi
echo "lint-kubo-pin: OK kubo_version=$PIN_VER (kubo.pin == manifest.toml == Dockerfile)"
