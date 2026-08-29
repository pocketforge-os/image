#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE="$ROOT/rootfs-overlay/etc/systemd/system/pocketforge-recovery.service"
PATH_UNIT="$ROOT/rootfs-overlay/etc/systemd/system/pocketforge-recovery.path"
CASES="$ROOT/tests/recovery-service-cases.toml"

# Offline dependency-closure gate: parse systemd dependency directives and
# reject every launcher artifact, rather than relying on a substring comment.
deps=$(sed -n -E 's/^(Requires|Requisite|Wants|BindsTo|PartOf|Upholds|Conflicts|Before|After)=//p' \
    "$SERVICE" "$PATH_UNIT" | tr ' ' '\n' | sed '/^$/d' | sort -u)
if printf '%s\n' "$deps" | grep -Eq 'pocketforge-(menu|launcher)|launcher'; then
    echo "FAIL: recovery dependency closure contains a launcher artifact" >&2
    exit 1
fi

grep -qx 'ConditionPathExists=/var/lib/pocketforge/recovery/required.json' "$SERVICE"
grep -qx 'PathExists=/var/lib/pocketforge/recovery/required.json' "$PATH_UNIT"
grep -q 'launcher-binary-missing' "$CASES"
grep -q 'launcher-service-absent' "$CASES"
grep -q 'launcher-crash-looping' "$CASES"
grep -q 'panel-presentation-failure' "$CASES"
grep -q 'Use FEL recovery when OTA is unavailable.' "$CASES"
grep -q 'PF_RECOVERY_SHA=7044d4980524c1d1f64e179760cbbd55c30899da' "$ROOT/build/Dockerfile.pf"
grep -q 'COPY --from=recovery-src' "$ROOT/build/Dockerfile.pf"
echo "PASS: recovery entry is launcher-independent and all deferred service cases are defined"
