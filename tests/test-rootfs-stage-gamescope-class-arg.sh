#!/usr/bin/env bash
# Verifies that build/Dockerfile.pf declares and forwards PF_GAMESCOPE_PROFILE_CLASS
# through the rootfs stage to scripts/build-rootfs.sh. The production rootfs build
# must pass this typed build-arg into the RUN environment; otherwise the g1 profile-class
# gate inside build-rootfs.sh always sees an empty/unset value and refuses legitimate
# builds (base and resetcap-off alike).
#
# Contract:
#   1. The rootfs stage (FROM app-root-tools AS rootfs ... next FROM) declares
#      `ARG PF_GAMESCOPE_PROFILE_CLASS=` (with `=` for a default-empty value,
#      matching the pattern used by other optional PF_* build-args).
#   2. The RUN block that invokes build-rootfs.sh forwards the value as
#      `PF_GAMESCOPE_PROFILE_CLASS="${PF_GAMESCOPE_PROFILE_CLASS}"` in its
#      env-prefix. This is the SAME env-prefix that already forwards
#      PF_GAMESCOPE_MODE, PF_DEVICE_ID, etc.
#
# Both parts must hold in the rootfs stage context — a bare token elsewhere in
# the Dockerfile does NOT satisfy the contract.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
dockerfile="$root/build/Dockerfile.pf"

fail=0

# ---------------------------------------------------------------------------
# 1. Extract the rootfs stage text.
# ---------------------------------------------------------------------------
# Stage starts at `FROM app-root-tools AS rootfs` and ends at the next top-level
# FROM line. We use awk with a state flag so that `FROM` lines inside heredocs
# or comments inside the stage body are not confused with stage boundaries —
# awk's /^FROM / matches only lines that BEGIN with FROM.
rootfs_stage=$(awk '
    /^FROM app-root-tools AS rootfs/ { inside=1; print; next }
    inside && /^FROM / { exit }
    inside { print }
' "$dockerfile")

if [[ -z $rootfs_stage ]]; then
    printf 'FAIL: could not extract rootfs stage from %s\n' "$dockerfile" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Extract only the ARG declaration block of the rootfs stage.
#    The ARG block runs from the FROM line until the first non-ARG,
#    non-comment, non-blank line (typically COPY or RUN).
# ---------------------------------------------------------------------------
rootfs_args=$(printf '%s\n' "$rootfs_stage" | awk '
    NR==1 { next }                         # skip the FROM line itself
    /^[[:space:]]*$/ { next }              # skip blank lines
    /^[[:space:]]*#/ { next }              # skip comment lines
    /^ARG[[:space:]]/ { print; next }
    { exit }                               # first non-ARG instruction ends the block
')

# ---------------------------------------------------------------------------
# 3. Assert ARG PF_GAMESCOPE_PROFILE_CLASS= is declared.
#    The `=` (with optional value after) is the critical part — without `=`
#    the build-arg has no default and must always be supplied, breaking builds
#    for modes where Gamescope is not-shipped.
# ---------------------------------------------------------------------------
if ! printf '%s\n' "$rootfs_args" | grep -qE '^ARG PF_GAMESCOPE_PROFILE_CLASS='; then
    printf 'FAIL: rootfs stage does not declare ARG PF_GAMESCOPE_PROFILE_CLASS=\n' >&2
    printf '      The g1 profile-class gate requires this build-arg to reach build-rootfs.sh.\n' >&2
    fail=1
fi

# ---------------------------------------------------------------------------
# 4. Extract the RUN heredoc that invokes build-rootfs.sh and assert it
#    forwards PF_GAMESCOPE_PROFILE_CLASS in its env-prefix.
#    The rootfs stage uses `RUN --security=insecure <<'ROOTFS'` ... `ROOTFS`
#    (heredoc) rather than backslash-continuation.
# ---------------------------------------------------------------------------
rootfs_run_block=$(printf '%s\n' "$rootfs_stage" | awk '
    /^RUN --security=insecure <<'\''ROOTFS'\''$/ { collecting=1; next }
    collecting && /^ROOTFS$/ { exit }
    collecting { print }
')

if [[ -z $rootfs_run_block ]]; then
    printf 'FAIL: could not locate the RUN heredoc invoking build-rootfs.sh in the rootfs stage\n' >&2
    exit 1
fi

if ! printf '%s\n' "$rootfs_run_block" | grep -qF 'build-rootfs.sh'; then
    printf 'FAIL: RUN heredoc does not invoke build-rootfs.sh\n' >&2
    exit 1
fi

# The forwarding must appear as `PF_GAMESCOPE_PROFILE_CLASS="${PF_GAMESCOPE_PROFILE_CLASS}"`
# in the env-prefix of the RUN command (before `bash /work/src/scripts/build-rootfs.sh`).
# This is the same pattern used for PF_GAMESCOPE_MODE, PF_DEVICE_ID, etc.
if ! printf '%s\n' "$rootfs_run_block" | grep -qF 'PF_GAMESCOPE_PROFILE_CLASS="${PF_GAMESCOPE_PROFILE_CLASS}"'; then
    printf 'FAIL: rootfs RUN block does not forward PF_GAMESCOPE_PROFILE_CLASS="${PF_GAMESCOPE_PROFILE_CLASS}"\n' >&2
    printf '      to the build-rootfs.sh invocation. The g1 profile-class gate cannot\n' >&2
    printf '      see the platform-emitted value without this forwarding.\n' >&2
    fail=1
fi

# ---------------------------------------------------------------------------
# 5. Cross-check: the env-prefix block must contain at least the other
#    Gamescope-related variables we expect to see alongside the class.
# ---------------------------------------------------------------------------
for sibling in 'PF_GAMESCOPE_MODE="${PF_GAMESCOPE_MODE}"' 'GAMESCOPE_DIR=/work/gamescope-package'; do
    if ! printf '%s\n' "$rootfs_run_block" | grep -qF "$sibling"; then
        printf 'FAIL: expected sibling env forward `%s` missing from rootfs RUN block\n' "$sibling" >&2
        fail=1
    fi
done

if [[ $fail -ne 0 ]]; then
    printf 'rootfs-stage-gamescope-class-arg=FAIL\n'
    exit 1
fi

printf 'rootfs-stage-gamescope-class-arg=PASS\n'
