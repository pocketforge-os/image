#!/usr/bin/env bash
#
# check-glibc-symver.sh — verify aarch64 ELF binaries reference no glibc 2.34+ symbols.
#
# WHY
#   TSP runs glibc 2.33. Binaries built with stock Ubuntu 24.04
#   gcc-aarch64-linux-gnu (gcc-13) embed GLIBC_2.34 versioned symbol references
#   and fail at startup on TSP with `version 'GLIBC_2.34' not found`. The fix is
#   the pinned ARM A-Profile Toolchain 10.3-2021.07 (gcc 10.3.1 / glibc 2.33).
#   This script is the CI gate: it runs `readelf -V` and refuses any ELF
#   carrying a GLIBC_2.34, GLIBC_2.35, ... symver.
#
# USAGE
#   check-glibc-symver.sh <binary> [<binary>...]
#
# EXIT CODES
#   0   all binaries clean
#   1   at least one binary references GLIBC_2.34 or newer
#   2   usage error or a referenced binary doesn't exist / isn't ELF
#
# IMPLEMENTATION NOTES
#   - Uses `readelf -V` from binutils (host or aarch64 cross-binutils both work
#     because version-needed/version-defined sections are arch-agnostic in the
#     ELF format; the symver text is the same regardless of which readelf reads
#     it). Inside the container we install `binutils-aarch64-linux-gnu` for the
#     authoritative reading, but plain `readelf` works on x86_64 hosts too.
#   - We grep the *Version needs section* (`Required` / `.gnu.version_r`) and
#     the *Version definitions* (`.gnu.version_d`). For dynamic executables the
#     needs section is the relevant one; for shared libraries that themselves
#     define a version, defs matter too. Catching both is cheap.
#   - The accept range is GLIBC_2.0 through GLIBC_2.33 inclusive. Anything
#     >= 2.34 fails. We match the symver tag literally because parsing
#     `readelf -V` output as structured data is more brittle than a strict
#     line-pattern match.
#
# REFERENCES
#   - hardware-firmware-probes.md §11.5  (the failed-workaround inventory:
#     .symver wrapping, musl static, bundled glibc — all do not work)
#   - build-integration-reference.md §3.6  (toolchain pin rationale + URL)

set -eu

usage() {
    cat >&2 <<'EOF'
Usage: check-glibc-symver.sh <binary> [<binary>...]

Fails (exit 1) if any binary references a GLIBC_2.34+ symbol version.
TSP runs glibc 2.33 and rejects 2.34-versioned binaries at startup.
EOF
    exit 2
}

if [ "$#" -lt 1 ]; then
    usage
fi

# Pick a readelf. Prefer the cross-binutils inside the container; fall back to
# the host's readelf since the symver tags are textually identical.
READELF=""
for candidate in aarch64-linux-gnu-readelf aarch64-none-linux-gnu-readelf readelf; do
    if command -v "$candidate" >/dev/null 2>&1; then
        READELF="$candidate"
        break
    fi
done

if [ -z "$READELF" ]; then
    echo "check-glibc-symver: no readelf found on PATH" >&2
    exit 2
fi

# The forbidden-symver pattern. We catch GLIBC_2.34 .. GLIBC_2.99 and
# GLIBC_3.x. Constructed deliberately not to match GLIBC_2.0 .. GLIBC_2.33.
#
# Strict regex breakdown:
#   GLIBC_2\.(3[4-9]|[4-9][0-9])    matches 2.34 .. 2.99
#   GLIBC_[3-9]\.[0-9]+             matches 3.0 .. 9.x (future-proof)
FORBIDDEN_RE='GLIBC_2\.(3[4-9]|[4-9][0-9])|GLIBC_[3-9]\.[0-9]+'

# Optional sanity-check pattern: did we see any glibc symver at all?
# A statically-linked binary will not. We don't fail on absence — just note it.
ANY_GLIBC_RE='GLIBC_[0-9]+\.[0-9]+'

EXIT_CODE=0

for bin in "$@"; do
    if [ ! -e "$bin" ]; then
        echo "check-glibc-symver: $bin: file not found" >&2
        EXIT_CODE=2
        continue
    fi

    # `file` may not be installed; we use `readelf -h` which fails non-zero on
    # non-ELF input. Suppress its stderr so our own message is the only one.
    if ! "$READELF" -h "$bin" >/dev/null 2>&1; then
        echo "check-glibc-symver: $bin: not a valid ELF file" >&2
        EXIT_CODE=2
        continue
    fi

    # Pull both the version-needs and version-defs sections. Either may be
    # empty/absent. -V handles both. We pipe through grep -E with extended
    # regex; -q would suffice but we want the offending line for diagnostics.
    forbidden_lines="$("$READELF" -V "$bin" 2>/dev/null | grep -E "$FORBIDDEN_RE" || true)"

    if [ -n "$forbidden_lines" ]; then
        echo "check-glibc-symver: FAIL: $bin references forbidden glibc symver(s):" >&2
        echo "$forbidden_lines" | sed 's/^/  /' >&2
        EXIT_CODE=1
        continue
    fi

    # Informational: did we see any glibc symver? Static binaries won't.
    any_glibc_lines="$("$READELF" -V "$bin" 2>/dev/null | grep -E "$ANY_GLIBC_RE" || true)"
    if [ -z "$any_glibc_lines" ]; then
        echo "check-glibc-symver: OK:   $bin (no glibc symver references — static or non-libc?)"
    else
        # Highest-numbered symver, for the operator-friendly summary.
        max_symver="$(echo "$any_glibc_lines" | grep -oE "$ANY_GLIBC_RE" | sort -V | tail -1)"
        echo "check-glibc-symver: OK:   $bin (max glibc symver: ${max_symver})"
    fi
done

exit "$EXIT_CODE"
