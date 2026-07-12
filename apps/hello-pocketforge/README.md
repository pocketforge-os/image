# apps/hello-pocketforge — the first real PocketForge app example

The **canonical `app.toml`** for a real PocketForge app, wired here as the first entry in the
image's `apps/` install-tree layer (see [`../../docs/APP-DESCRIPTOR.md`](../../docs/APP-DESCRIPTOR.md)).
It is the exact descriptor emitted by:

```sh
pf-app new "Hello PocketForge" --device a523 --id com.pocketforge.hello
```

- **Source + build + sim proof:** [`pocketforge-os/pf-app`](https://github.com/pocketforge-os/pf-app)
  (`pf-app new` scaffold; `docs/BUILD-YOUR-OWN-APP.md`). The app itself — a rectangle that
  turns green while a button is held — is not vendored here; the image composes the *installed*
  bundle, and packaging (`mmdebstrap → tar → OCI-by-digest → cosign → syft → grype`) is the E8
  packaging path (`tsp-ziac.3`), landed in `pf-app`'s `oci/` kit.
- **Descriptor contract:** `[runtime].family = "pocketforge/a523-mali"`, `abi = "1"`,
  `platform-version = "1"`; `use = ["input", "vibration?"]`. Validate with
  `pf app-validate app.toml` from a `pocketforge-os/platform` checkout.

## Committed vs generated siblings

This directory commits the packaging path's **inputs** and the app's **on-device** siblings:

| file | role | committed? |
|---|---|---|
| `app.toml` | the canonical descriptor | ✅ |
| `launch` | Phase-2 on-device launch (verify `oci.sig` → `systemd-run` + `crun`) | ✅ |
| `slice.conf` | per-app systemd transient-slice resource limits | ✅ |
| `oci/` | the OCI image-layout (addressed **by digest**) | ❌ generated + published by digest ([`.gitignore`](.gitignore)) |
| `oci.sig` | cosign signature over `oci/index.json` (by digest) | ❌ CI-signed |
| `app.toml.sig` | minisign signature over `app.toml` | ❌ CI-signed |
| `sbom.spdx.json` / `grype-report.json` | syft SBOM / grype scan (advisory) | ❌ CI-generated |

Release signing happens in [`.github/workflows/sign-and-scan.yml`](../../.github/workflows/sign-and-scan.yml)
with the **real release keys via GitHub OIDC** (the `sign` environment) — never committed,
never agent-readable (see that workflow's HONEST BOUNDARY header). The **on-silicon**
supervisor verify+exec (both sigs, WITHOUT a reflash) is a separate, owner-gated hardware phase.
