#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SERVICE="$ROOT/rootfs-overlay/etc/systemd/system/pocketforge-recovery.service"
PATH_UNIT="$ROOT/rootfs-overlay/etc/systemd/system/pocketforge-recovery.path"
CASES="$ROOT/tests/recovery-service-cases.toml"

# Launcher independence forbids positive launcher dependencies. Conflicts= and
# After= intentionally name optional panel owners: neither directive starts the
# named unit, so an absent launcher does not make recovery fail.
positive_deps=$(sed -n -E 's/^(Requires|Requisite|Wants|BindsTo|PartOf|Upholds)=//p' \
    "$SERVICE" "$PATH_UNIT" | tr ' ' '\n' | sed '/^$/d' | sort -u)
if printf '%s\n' "$positive_deps" | grep -Eq 'pocketforge-(menu|launcher)|launcher'; then
    echo "FAIL: recovery has a positive dependency on a launcher artifact" >&2
    exit 1
fi

# Recovery must join the foreground slot and directly serialize against every
# build-time panel-owner variant. These exact assertions keep the single-fb0-
# writer property from regressing if the unit is edited independently.
grep -qx 'Requires=pocketforge-foreground.target' "$SERVICE"
grep -qx 'Conflicts=pocketforge-boot-animator.service pocketforge-menu.service pocketforge-placeholder.service' "$SERVICE"
grep -qx 'After=local-fs.target dev-fb0.device pocketforge-foreground.target pocketforge-boot-animator.service pocketforge-menu.service pocketforge-placeholder.service' "$SERVICE"

grep -qx 'ConditionPathExists=/var/lib/pocketforge/recovery/required.json' "$SERVICE"
grep -qx 'PathExists=/var/lib/pocketforge/recovery/required.json' "$PATH_UNIT"
grep -q 'launcher-binary-missing' "$CASES"
grep -q 'launcher-service-absent' "$CASES"
grep -q 'launcher-crash-looping' "$CASES"
grep -q 'panel-presentation-failure' "$CASES"
grep -q 'Use FEL recovery when OTA is unavailable.' "$CASES"
grep -q 'PF_RECOVERY_SHA=7044d4980524c1d1f64e179760cbbd55c30899da' "$ROOT/build/Dockerfile.pf"
grep -q 'COPY --from=recovery-src' "$ROOT/build/Dockerfile.pf"
echo "PASS: recovery entry has an exclusive fb0 handoff, remains launcher-independent, and defines all deferred service cases"
