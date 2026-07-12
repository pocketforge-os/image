# App descriptor + Platform ABI contract (pointer)

> Where an image / launch-supervisor author finds the **canonical `app.toml`** an installed app
> ships and the **per-SoC-family Platform ABI** it pins. The image composes the `apps/` install
> trees (README) and the kiosk supervisor launches them against this contract. Established by
> **E8 `tsp-ziac.1`**; the `apps/` monorepo integration + the launch supervisor land in
> **`tsp-ziac.2`** (scaffold) / **`tsp-ziac.3`** (packaging) — this doc is the contract they build
> to, not those deliverables.

## The canonical descriptor

An installed app carries **one `app.toml`** (one descriptor, three consumers: the on-device
broker/supervisor at launch, packaging at build/sign, the SDK at scaffold). It reconciles the
three pre-E8 schemas (Phase-1 plan §9.3/§9.4, Phase-2 OCI build-integration-reference §18,
pf-broker `manifest.rs`) and adds the `[runtime]` per-SoC-family Platform pin:

```toml
[app]
id       = "com.example.spinner"
category = "game"
use      = ["input", "vibration", "imu?", "entropy", "egress:scores.example.com"]

[runtime]                                    # the per-SoC-family Platform ABI pin (E8)
family           = "pocketforge/a523-mali"   # a133-powervr | a523-mali (or an accepted alias)
abi              = "1"                        # frozen libpocketforge/PFW1 contract version
platform-version = "1"                        # the frozen {kernel,gpu,sdl} SHA-set for this family

[launch]
exec = "./launch"; needs_network = true; takes_display = true; audio = true
# [health], [fetch] optional. Sibling files (packaging): app.toml.sig, oci/, oci.sig,
# sbom.spdx.json, slice.conf — see the schema below. Phase-2 `launch` invokes crun.
```

Note the per-app first-boot **`[fetch]`** (HTTPS binary, plan §9.4) is a **different mechanism**
from this image's vendor-**blob** `[fetch]` (`scripts/ipfs-fetch.sh`, `manifest.toml` `[[blobs]]`,
IPFS/CID — `tsp-iby`): same word, different trust anchor. They are not unified.

## Authoritative sources (do not fork these here)

- **Machine schema:** `platform` repo → `abi/app.schema.json`
- **Reference examples:** `platform/abi/examples/app-{a133-powervr,a523-mali}.toml`
- **Static validator:** `platform` repo → `pf app-validate <app.toml>` (`core/appmanifest.py`)
- **Named per-family Platform ABI + freeze/deprecation policy + provenance caveat:**
  `platform/docs/PLATFORM-ABI-CONTRACT.md`; the E8 spec →
  `mission-control/.planning/infra/infra-107.1-platform-abi-and-app-descriptor.md`
- **Public capability facade (frozen v1):** `runtime` repo → `include/pocketforge.h`,
  `abi/libpocketforge.v1.abi`, `wire/WIRE-PROTOCOL.md`, `STABILITY.md`,
  `docs/RUNTIME-SDK-SPLIT.md`

## Per-family provenance (honest, not blanket)

- `pocketforge/a133-powervr` — SHA-pinned **and reproducible-from-clean** (`tsp-1dl.4.5`,
  `tsp-cv7.6.1`); owned `libsdl3-sunxifb`.
- `pocketforge/a523-mali` — SHA-pinned, **not yet reproducible** (`tsp-jet`); **no owned SDL fork
  yet** (`libsdl3-sunxifb` links the PowerVR UM ⇒ a133-only). No bit-for-bit *app* claim.
