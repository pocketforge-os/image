# Launcher-independent recovery entry

The image builds `pocketforge-recovery-entry` against `pocketforge-os/recovery`
commit `7044d4980524c1d1f64e179760cbbd55c30899da` (F15, recovery PR #8). The
`recovery-src` named build context and `PF_RECOVERY_SHA` must both be resolved
from `platform.lock`; the build rejects any other ref. Recovery PR #9
(`492a16935726397c96d9517e95e57b7b19c4527d`) added CI to that unchanged
surface.

`pocketforge-recovery.path` watches the durable
`/var/lib/pocketforge/recovery/required.json` `RecoveryRequired` record and
starts `pocketforge-recovery.service`. Neither unit names, orders against, or
depends on a launcher artifact. The executable assumes no network capability;
it renders the upstream CPU surface, preserves the RGBA frame as out-of-band
evidence, and attempts to present it on fb0. If panel presentation fails, it
persists customer-readable FEL fallback evidence in
`presentation-failure.json` rather than claiming a panel success.

`tests/test-recovery-entry.sh` performs the committed offline dependency-closure
gate. `tests/recovery-service-cases.toml` defines the later device/simulator
campaign for a missing launcher binary, absent launcher service, crash-looping
launcher, and failed panel presentation.

This bead is the F16 authoring half only. Boot/service and panel proof await the
GPU campaign's device availability and must not be inferred from these offline
checks.
