# Decision: the `runtime` build stage uses a digest-pinned external Rust image

**Bead:** `tsp-e1b.11` — package the E2 runtime layer into the image (pin `runtime` in
`platform.lock`; install + enable `pf-input-decode`).
**Ruling:** `tsp-e1b-coord`, 2026-07-26 — **Option A** (digest-pinned external Rust builder
stage), with the four conditions recorded below.
**Status:** this is the **first external base image in `build/Dockerfile.pf`**. Every other
stage is `FROM ${PF_CONTAINER}` (the owned, digest-pinned build container, `container.pin`).
This note exists so that precedent is set **deliberately and visibly**, not by silent drift.

## What was decided

The `runtime` stage in `build/Dockerfile.pf` cross-compiles `pf-input-decode` (the A133
gamepad-MCU decoder daemon) to a static `aarch64-unknown-linux-musl` binary. The owned build
container carries a GCC aarch64 cross-toolchain but **no Rust**, so the stage is:

```
FROM rust:1.83-slim-bookworm@sha256:540c902e99c384163b688bbd8b5b8520e94e7731b27f7bd0eaa56ae1960627ab AS runtime
```

It is a **build-time-only, multi-stage, discarded** builder. Only the built static binary and
the crate's committed systemd unit are `COPY --from=runtime`'d forward into the rootfs stage;
the Rust toolchain, std, and shell never ship. A digest pin is content-addressed — the **same
reproducibility class as `container.pin`** — so determinism is unchanged; only *where a
build-time tool comes from* widens.

## Why Option A (and why the alternatives were rejected)

**A — digest-pinned external Rust image (CHOSEN).** Lean, discarded, zero blast radius on
other stages or lanes. Cost: it is the first un-owned base in `Dockerfile.pf`.

**B — bake Rust into the owned base container (`container.pin` re-pin). REJECTED for now.**
Provenance-pure (every stage stays `FROM ${PF_CONTAINER}`), but a base re-pin lands on **every
lane and every build**, growing the shared container by hundreds of MB to serve one small
daemon. Disproportionate blast radius when the provenance difference is this thin. Blast radius
is the deciding axis here.

**C — keep `FROM ${PF_CONTAINER}` and install Rust via a rustup shell install + checksum.
REJECTED.** It preserves the *letter* of "no external base" but not its substance: it still
reaches an un-owned external host (`static.rust-lang.org`) and trades one clean
content-addressed dependency for a messier shell-install-plus-checksum one. Preserving the
letter of an invariant while making the actual dependency worse is not a win.

Why the provenance objection is thinner than it looks: our provenance rules
(`.claude/rules/provenance.md`) govern what **ships** — every image artifact is source-built
from a committed repo or a committed reproducible transform over a preserved vendor original.
A discarded multi-stage builder ships **nothing**. And the owned base's GCC cross-toolchain is
itself a distro toolchain, not owned source — so "every stage from the owned container" was
always a build-hygiene statement, not a provenance-purity one.

## The four conditions on Option A

1. **DIGEST, never a tag.** `FROM rust:<ver>-slim@sha256:...`. A tag would silently break the
   reproducibility argument this decision rests on. *(Met: pinned index digest above.)*
2. **Provably discarded.** Nothing leaves the stage except the built aarch64 binary (and the
   committed unit file). No libraries, no toolchain, no shell helpers copied forward. *(Met:
   the only `COPY --from=runtime` is `/out`, which contains just `bin/pf-input-decode`,
   `systemd/pf-input-decode.service`, and the provenance marker.)*
3. **Record the precedent explicitly** — in the PR body and this note: first external base in
   `Dockerfile.pf`, build-time-only + discarded, with the reasoning. *(This note + the PR.)*
4. **State the migration path** (this note): if we ever decide we want **zero** external bases,
   the answer is **B** — bake Rust into the owned container at the next natural `container.pin`
   re-pin — **NOT** a rustup shell install (option C). A future worker should inherit the
   reasoning, not just the outcome.

## Convention for future runtime components

`pf-input-decode` is the first `runtime`-layer component packaged into the image, so this stage
is the template every future runtime component follows:

- `runtime` is pinned in `platform.lock` at a real merged SHA (`pf build` resolves on `sha`,
  never the `ref` tracking branch — the `tsp-tnpp` trap).
- `core/profile.py` emits `PF_RUNTIME_SHA` (literal-name lookup, not per-device); `core/pf-build.sh`
  stages the `runtime-src` context and passes the SHA build-arg.
- The stage builds **only the crates it ships** (`cargo build --locked -p <crate>`), so parallel
  in-flight `runtime` work carried in the pinned archive stays inert.
- Reproducibility anchor: the digest-pinned toolchain + `Cargo.lock` (`--locked`) + a single
  checksummed dependency, same pin-not-airgap model as `mmdebstrap`'s Debian snapshot.

To add another runtime binary later: extend the `runtime` stage's `cargo build` to name the new
crate, stage its artifact into `/out`, and install it from `build-rootfs.sh` — no new external
base and no new build-context wiring needed.
