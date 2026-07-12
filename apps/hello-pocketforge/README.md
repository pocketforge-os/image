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
  bundle, and packaging (`mmdebstrap → OCI → cosign → syft → grype`) is the E8 packaging path
  (`tsp-ziac.3`), which will drop the built payload + sibling files (`app.toml.sig`, `oci/`,
  `oci.sig`, `sbom.spdx.json`, `slice.conf`) alongside this `app.toml`.
- **Descriptor contract:** `[runtime].family = "pocketforge/a523-mali"`, `abi = "1"`,
  `platform-version = "1"`; `use = ["input", "vibration?"]`. Validate with
  `pf app-validate app.toml` from a `pocketforge-os/platform` checkout.

This directory currently carries the descriptor only; the launch supervisor + packaged
payload land with `tsp-ziac.3`.
