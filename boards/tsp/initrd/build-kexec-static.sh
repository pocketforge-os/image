#!/usr/bin/env bash
# =============================================================================
# build-kexec-static.sh — static AArch64 /sbin/kexec for the dev initrd
# -----------------------------------------------------------------------------
# Builds kexec-tools from the committed upstream release tarball
# (third_party/kexec-tools, provenance in its SOURCE.md) with the build
# container's aarch64-none-linux-gnu toolchain, statically linked against its
# glibc 2.33, and installs the stripped `kexec` at --out.
#
# Called by build-initrd.sh for the dev variant only: the self-flash v3 hand-off
# (docs/SELF-FLASH-V3-HANDOFF.md) kexecs the new target when /sbin/kexec exists.
# BusyBox has no kexec applet.
#
# Pins, both checked on every build:
#   KEXEC_TOOLS_SOURCE_SHA256  the tarball (= kernel.org sha256sums.asc entry)
#   KEXEC_STATIC_SHA256        the stripped binary from the pinned container
# A different output means the toolchain or flags changed: re-derive the pin
# in the new container on its own bead, never by editing it to match.
#
# Network-free and path-independent (-ffile-prefix-map; nothing date-stamped).
#
# Usage: build-kexec-static.sh --out FILE [--src DIR] [--tarball FILE] [--jobs N]
# bd: tsp-624ea955036f01d58629
# =============================================================================
set -euo pipefail

KEXEC_TOOLS_VERSION=2.0.32
KEXEC_TOOLS_SOURCE_SHA256=8f81422a5fd2362cf6cb001b511e535565ed0f32c2f4451fb5eb68fed6710a5d
KEXEC_STATIC_SHA256=09b191b07a4d24e7ccf3546199b68368cf02931706db67b3305662c00fd098c2

SRC_DIR="${SRC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
TARBALL=""
OUT=""
JOBS="$(nproc 2>/dev/null || echo 1)"
while [ $# -gt 0 ]; do
    case "$1" in
        --out)     OUT="$2"; shift 2 ;;
        --src)     SRC_DIR="$2"; shift 2 ;;
        --tarball) TARBALL="$2"; shift 2 ;;
        --jobs)    JOBS="$2"; shift 2 ;;
        *) echo "build-kexec-static.sh: unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "${OUT}" ] || { echo "build-kexec-static.sh: --out is required" >&2; exit 2; }
TARBALL="${TARBALL:-${SRC_DIR}/third_party/kexec-tools/kexec-tools-${KEXEC_TOOLS_VERSION}.tar.xz}"

[ -f "${TARBALL}" ] || { echo "FATAL: kexec-tools source ${TARBALL} not found" >&2; exit 1; }
got="$(sha256sum "${TARBALL}" | cut -d' ' -f1)"
[ "${got}" = "${KEXEC_TOOLS_SOURCE_SHA256}" ] \
    || { echo "FATAL: kexec-tools source sha256 mismatch: ${got} != ${KEXEC_TOOLS_SOURCE_SHA256}" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
tar -xJf "${TARBALL}" -C "${WORK}"
KT="${WORK}/kexec-tools-${KEXEC_TOOLS_VERSION}"
[ -x "${KT}/configure" ] || { echo "FATAL: ${TARBALL} has no kexec-tools-${KEXEC_TOOLS_VERSION}/configure" >&2; exit 1; }

echo "=== building static kexec-tools ${KEXEC_TOOLS_VERSION} ==="
( cd "${KT}"
  ./configure --host=aarch64-none-linux-gnu --build=x86_64-linux-gnu --prefix=/ \
      --without-zlib --without-lzma --without-xen --without-booke \
      CFLAGS="-O2 -ffile-prefix-map=${KT}/=" LDFLAGS=-static >"${WORK}/configure.log" 2>&1 \
      || { tail -n 30 "${WORK}/configure.log" >&2; exit 1; }
  make -j"${JOBS}" build/sbin/kexec >"${WORK}/make.log" 2>&1 \
      || { tail -n 30 "${WORK}/make.log" >&2; exit 1; } )
aarch64-none-linux-gnu-strip -o "${WORK}/kexec" "${KT}/build/sbin/kexec"

aarch64-linux-gnu-readelf -h "${WORK}/kexec" | grep -q 'AArch64' \
    || { echo "FATAL: kexec is not AArch64" >&2; exit 1; }
if aarch64-linux-gnu-readelf -l "${WORK}/kexec" | grep -q -E 'INTERP|DYNAMIC'; then
    echo "FATAL: kexec is not statically linked" >&2; exit 1
fi
got="$(sha256sum "${WORK}/kexec" | cut -d' ' -f1)"
[ "${got}" = "${KEXEC_STATIC_SHA256}" ] \
    || { echo "FATAL: static kexec sha256 ${got} != pinned ${KEXEC_STATIC_SHA256} (toolchain or flags changed?)" >&2; exit 1; }

install -D -m 0755 "${WORK}/kexec" "${OUT}"
echo "  kexec: $(stat -c%s "${OUT}") bytes sha256=${got} (static AArch64, stripped)"
