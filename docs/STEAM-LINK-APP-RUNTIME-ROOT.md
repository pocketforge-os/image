# Per-app Bookworm runtime roots for `pf-app@`

Status: offline design and host-QEMU prototype for `tsp-mc9m.41.996.1`.
This document does not claim an A133 result, redistribution permission, or a
production implementation. The production schema, parser, reason-code, and
unit changes are intentionally deferred while the governing `tsp-f3fm.202`
dependency remains in progress; this work uses its already-landed
one-launch-path source contract without forking it.

## Decision and repository home

The design and prototype belong in `pocketforge-os/image`. Image owns the
`pf-app@.service` template, rootfs assembly, and the existing cross-repository
app-contract design precedent. Runtime must eventually own the canonical
parser and reason codes; launcher should only consume the resulting runtime
pin. Keeping this PR in image permits review of the image-facing contract and
offline artifact transform without creating a competing parser, launcher, or
unit.

The invariant is one `app.toml`, one shared runtime parser, one
`pf-app-launch <id>` helper, and one `pf-app@<id>.service` launch path. A
runtime root changes the mount namespace of that same unit. It is not an OCI
image, daemon, package manager, privileged wrapper, or second launcher.

## Verified baseline

The following evidence was read at the exact fetched `origin/main` commits on
2026-10-03. Paths and line numbers refer to those commits, not this branch.

### Image `652b0b3a63781d54fc8ec8ce11a63fc70d5dc8a6`

- `rootfs-overlay/etc/systemd/system/pf-app@.service:10-28` runs as `gamer`,
  fixes the working directory and two XDG paths, invokes only
  `/usr/bin/pf-app-launch %i`, hardens the host filesystem, and grants the app
  state directory. It has no `RootImage`, `PrivateUsers`, `PrivateDevices`, or
  device allow-list.
- `scripts/build-rootfs.sh:1097-1105` calls the single default-app installer
  for the A133 open profile. `scripts/install-default-app-support.sh:25-35`
  takes the helper, capability contract, launcher, broker, and unit from the
  pinned runtime/image stages; `scripts/install-default-app-support.sh:77-96`
  validates and installs that atomic set, including exactly the one unit
  template.
- `scripts/install-default-app-support.sh:98-112` proves the app template and
  input broker are installed but never boot-enabled. Runtime activation owns
  their lifecycle.
- `docs/APP-DESCRIPTOR.md:10-31` records the single-descriptor intent and the
  existing `[runtime]` pin, while `docs/APP-DESCRIPTOR.md:47-59` points parser
  and public-capability authority back to runtime/platform rather than image.

### Runtime `7536aa1f5af76f0220b582ee68e29e254251fd76`

- `crates/pf-app-manifest/src/lib.rs:13-31` fixes the production app root and
  current capability vocabulary. `crates/pf-app-manifest/src/lib.rs:66-128`
  defines the strict, `deny_unknown_fields` manifest. `Runtime` currently has
  only `family`, `abi`, and optional `platform-version`; therefore a
  `[runtime.root]` table is currently rejected rather than ignored.
- `crates/pf-app-manifest/src/lib.rs:189-257` is the shared strict parser and
  validator. `crates/pf-app-manifest/src/lib.rs:645-753` resolves only beneath
  the fixed app root, rejects symlinks/escapes, and parses that same
  descriptor. `crates/pf-app-manifest/src/lib.rs:840-884` checks the device
  platform pin and declared capabilities.
- `crates/pf-app-manifest/src/lib.rs:526-600` is the current exhaustive reason
  vocabulary. It has no runtime-root or platform-runtime artifact reasons.
- `crates/pf-app-launch/src/main.rs:4-31` accepts only one app id and uses the
  fixed resolver. `crates/pf-app-launch/src/lib.rs:64-91` re-resolves the app,
  creates its authorized XDG directories, and directly `execve`s the resolved
  executable. There is no alternate app-root path.
- `crates/pf-session-authority/src/lib.rs:347-365` starts, stops, and kills
  `pf-app@{item_id}.service`. `crates/pf-session-authority/src/lib.rs:1604-1658`
  resolves the request before starting that same unit and records a typed
  start failure.

### Launcher `e27f2c45271fb6b9d695b36c0163e7ade051583a`

- `Cargo.toml:26-40` pins the parser, launch helper, ports, and session
  authority to the runtime commit above.
- `crates/pf-shell/src/main.rs:287-324` builds the installed-app catalog using
  the runtime-backed provider with the device runtime/capability contract.
- `crates/pf-shell/src/main.rs:1941-1965` sends the existing launch effect to
  the session client. No root choice or executable path crosses that port.

These facts confirm the one-path premise. They also define the present merge
blocker: adding a production root table in image alone cannot work because the
strict runtime parser rejects it, the runtime reason enum cannot represent its
failures, and the authority currently has no pre-start sandbox-render step.
Implementing those pieces here would fork `tsp-f3fm.202`.

## Descriptor extension

The canonical runtime parser gains one optional field:

```toml
[app]
id = "org.pocketforge.steamlink"
name = "Steam Link"
category = "stream"
version = "1.3.32.316"
use = ["audio", "input", "vibration", "video-decode"]

[runtime]
family = "pocketforge/a133-powervr"
abi = "1"
platform-version = "20"

[runtime.root]
schema = 1
format = "squashfs"
digest = "sha256:<64 lowercase hex>"
platform-runtime = "pocketforge/bookworm-aarch64"
platform-runtime-abi = "1"
platform-runtime-version = "sha256:<64 lowercase hex>"
library-paths = ["lib", "Qt-5.14.1/lib"]

[launch]
exec = "bin/shell"
needs_network = true
takes_display = true
audio = true
```

`runtime.root` is `Option<RuntimeRoot>` with `#[serde(default)]`; omission
selects the exact existing resolver, helper, working directory, and host-root
unit with no generated drop-in. This is the compatibility default and is
covered by a byte-independent “action=unchanged” test. Poolsuite therefore
continues on the verified host root.

When present, every field above is required except `library-paths`, whose
default is an empty array. Unknown fields are refused. `schema` is exactly 1;
`format` is exactly `squashfs`; both identities use lowercase SHA-256. Library
paths must be unique canonical relative paths: no empty, absolute, `.`, `..`,
or normalized-different value. They are expanded only below the fixed app
directory inside the mounted image. Existing `app.id`, `use`, optional-marker,
modifier, launch-path, platform-pin, and symlink rules remain owned by the
shared runtime parser; the renderer consumes its validated result and must not
reimplement them.

`platform-version` and `platform-runtime-version` are intentionally different:
the former remains the device-wide PocketForge platform contract; the latter
is the exact content identity of the Bookworm userspace slice mounted into a
rooted app. `video-decode` is a proposed addition to the canonical capability
vocabulary and platform contract. Until the runtime parser and target platform
both advertise it, Steam Link must refuse rather than silently receive codec
devices.

## Artifact layout and compatibility

Installed content is root-owned, non-symlinked, and content addressed:

```text
/opt/pocketforge/apps/<app-id>/app.toml
/var/lib/pocketforge/app-roots/<app-id>/sha256-<root-digest>.raw
/usr/lib/pocketforge/platform-runtimes/
  pocketforge-bookworm-aarch64/sha256-<manifest-digest>/
    .manifest-sha256
    usr/local/lib/...
    usr/lib/aarch64-linux-gnu/...
```

The host-root app directory is a thin, root-owned metadata anchor containing
the one canonical descriptor. Session authority resolves it before unit start;
the same file is then bound read-only over its canonical path inside the app
root so `pf-app-launch` re-resolves identical bytes. It is not a second
descriptor or executable tree.

The app-root digest covers the stored squashfs bytes. The platform-runtime
version is the SHA-256 of a sorted `SHA256  relative/path` manifest; the
content-addressed directory contains a matching immutable identity marker.
Neither identity is a mutable symlink or package version label. Installers
verify the descriptor, regular-file/directory types, ownership, mode, digest,
and platform manifest before making a descriptor visible. Before rendering a
unit, the source-owned contract prototype also recomputes that canonical
manifest over every regular platform file (excluding the identity marker) and
refuses symlinks, special objects, or a content mismatch. A marker alone is
not accepted as proof of the installed tree.

Compatibility requires all of the following:

1. The existing device `family`, `abi`, and `platform-version` checks pass.
2. Root `schema` and `format` are supported and its image digest matches.
3. Platform-runtime id and ABI match an installed entry exactly.
4. The descriptor's platform-runtime version equals that entry's manifest
   digest exactly. There is no “newer is probably compatible” fallback.
5. All required capabilities have concrete resources in the trusted host
   inventory. Optional capabilities retain the existing parser semantics and
   receive resources only when advertised by the device contract.

An update installs and verifies new content-addressed objects first, then
atomically publishes the descriptor/index that references them. Existing
processes retain their already-mounted objects. Rollback republishes the prior
reference; garbage collection removes only objects that are unreferenced by
installed descriptors, rollback history, and running units. A partially
installed version is never selected.

## Same-unit rendering and refusal behavior

After the governing default-app work lands, session authority should ask the
shared resolver for a validated `SandboxPlan` before its existing
`systemctl start pf-app@<id>.service` call. A privileged, fixed-function image
component atomically writes or removes only:

```text
/run/systemd/system/pf-app@<systemd-escaped-id>.service.d/50-runtime-root.conf
```

It fsyncs and renames the file, runs `daemon-reload`, and then the authority
starts the same unit. Requests remain serialized by the authority. An omitted
root removes a stale per-instance file and produces the unchanged template;
there is no second helper or service. The descriptor and static
`pf-app-launch` are bound read-only at their canonical paths inside the root,
so the existing helper re-resolves the same `app.toml` and directly execs the
same `[launch].exec`.

The deterministic drop-in contains, at minimum:

```ini
[Service]
RootImage=/var/lib/pocketforge/app-roots/<id>/sha256-<digest>.raw
RootImageOptions=ro
PrivateUsers=yes
PrivateDevices=yes
DevicePolicy=closed
SupplementaryGroups=
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/pocketforge/apps/<id>
BindReadOnlyPaths=<platform-version-dir>:/run/pocketforge/platform-runtime
```

The renderer then adds only validated, sorted binds and `DeviceAllow` entries.
It never interpolates an app-provided absolute host path. `PrivateNetwork=yes`
is emitted when `launch.needs_network` is false; true retains the host network
namespace but does not promise domain-level egress filtering. The existing
memory limit and foreground lifecycle remain on the template.

Proposed new reason codes extend, rather than replace, runtime's current enum:

| Reason | Exit class | Meaning |
| --- | ---: | --- |
| `runtime_root_invalid` | 65 | unknown field, schema/format/id, or malformed identity |
| `runtime_root_invalid_library_path` | 65 | non-canonical, escaping, or duplicate library path |
| `runtime_root_missing` | 66 | selected root is absent, non-regular, or a symlink |
| `runtime_root_digest_mismatch` | 65 | stored root bytes differ from the descriptor |
| `platform_runtime_missing` | 66 | selected platform runtime/identity marker is absent |
| `platform_runtime_incompatible` | 65 | id, ABI, or exact version is incompatible |
| `platform_runtime_digest_mismatch` | 65 | installed platform identity differs from its version |
| `required_resource_missing` | 66 | trusted inventory cannot satisfy a required grant |
| `sandbox_render_failed` | 74 | atomic write, reload, or unit materialization failed |

Refusal occurs before unit start. Logs use the existing
`launch_refused reason=<stable-code> item_id=<JSON string>` shape and do not
include host paths supplied by an app. The source-owned renderer in this PR is
an executable contract prototype, not the production parser or installer.

## Capabilities and least privilege

The host, not the app, owns the resource inventory. Each entry is a sorted list
of exact paths selected from enumerated prefixes; wildcard device grants are
forbidden. Socket binds are similarly exact and are created/ACL'd for the app
service identity by the owning platform service. The renderer starts with a
private `/dev` and a closed device policy.

Per the 2026-10-03 session-contract reconciliation, display and audio resources
come only from the compositor-neutral publication under
`/run/pocketforge/session`. The environment file and canonical
`/run/pocketforge/session/wayland-0` are mounted read-only/exactly; any
Xwayland or audio endpoint is an exact inventory path named by that environment,
not a guessed `/run/user` implementation detail. This design does not choose
the compositor or implement that publication.

| Declaration | Resources granted | Explicitly not granted |
| --- | --- | --- |
| `launch.takes_display=true` | session environment, canonical Wayland socket, an inventory-named Xwayland socket when present, and selected `/dev/dri/renderD*` read-write | DRM card/scanout nodes, tty, fb, input interception |
| `launch.audio=true` or `use=["audio"]` | session environment, its exact inventory-named audio socket, and minimum `/dev/snd` control/playback nodes read-write | unrelated capture devices and all other sound cards |
| `use=["input"]` | selected evdev nodes read-only plus the input-broker socket | writes, unrelated event nodes, hidraw |
| `use=["vibration"]` or `use=["rumble"]` | only the selected controller evdev nodes read-write | other input nodes and hidraw |
| `use=["video-decode"]` | selected stateless-codec `/dev/video*` and matching `/dev/media*` nodes read-write | camera nodes, encoders, unrelated media graphs, DRM scanout |
| `accelerometer`, `gyroscope`, `magnetometer`, `imu` | PocketForge broker socket only | raw IIO/input/sysfs nodes |
| `location`, `gnss` | PocketForge broker socket only | raw UART/GNSS device |
| `leds` | PocketForge broker socket only | `/sys` writes |
| `settings` | per-app XDG state/data only | another app's state or host configuration |
| `entropy` | private namespace `/dev/urandom` | host RNG control/ioctl surfaces |

An unavailable required resource is a refusal, not a partial launch. Existing
optional-capability semantics may omit an unavailable optional resource.
Controller permissions come from platform udev/ACL policy and user-namespace
mapping, never app-time sudo. On-device work must verify the selected systemd
`PrivateUsers` mode and device ACL mapping before enabling real device grants;
this host-QEMU prototype cannot establish that kernel/udev fact.

The compositor continues to own scanout and input interception. Apps are only
Wayland/Xwayland/audio clients. This design does not implement a compositor,
Cedrus userspace, FFmpeg/libva, codec policy, or pairing.

## State and filesystem ownership

The one per-app `StateDirectory=pocketforge/apps/<id>` remains the only
persistent writable host subtree and is mode 0700. The production template
sets four children owned for the service identity:

```text
XDG_CONFIG_HOME=/var/lib/pocketforge/apps/<id>/config
XDG_STATE_HOME=/var/lib/pocketforge/apps/<id>/state
XDG_CACHE_HOME=/var/lib/pocketforge/apps/<id>/cache
XDG_DATA_HOME=/var/lib/pocketforge/apps/<id>/data
```

The root image, platform runtime, descriptor, helper, platform contract, and
host root are read-only. `/tmp` is private and ephemeral. No app can write
another id's state. “Root” inside the private user namespace maps to an
unprivileged host identity; the application still runs as `gamer`, with
supplementary groups reset and no-new-privileges. PID 1 performs the image
mount; the app receives no mount or namespace capability.

## Reproducible Steam Link prototype

The prototype uses preserved originals and writes all derived/vendor bytes to
a caller-selected directory outside git:

```sh
out="$(mktemp -d -t pf-steamlink-output.XXXXXXXX)"
scripts/build-steamlink-app-root-prototype.sh --output "$out"
scripts/measure-steamlink-app-root-prototype.py \
  --prototype "$out" \
  --output /tmp/pf-steamlink-measurement.json \
  --runs 5 --timeout 25
```

The builder verifies these complete identities before reading an input:

| Preserved input | SHA-256 |
| --- | --- |
| Valve `steamlink-rpi-bookworm-arm64-1.3.32.316.tar.gz` | `6e1e431265da01b85a7a2fb2ef652f822eb16c5b78aca03f0d0d500dc29b93d3` |
| Detached signature | `a88e79b66550f7740158f2d80385bfd794706683b023cf0ec28dc4e2cf608868` |
| Vendor source receipt | `c69a789967a2383fdb8fc64db67c984b164e8e320523eebf2474cbca74fbeeba` |
| Vendor `SHA256SUMS` | `5b5889991d4f84cae076f878b886f692f223cca062fca7393a7af9ea1ac9b926` |
| RB2g `ImageSource.json` | `6e39f7de189dcd009f6cf34e7c2c1784cddf4e02532e68fa8f46bd5396d54e2f` |
| RB2g compressed image | `8d01225721a7a276a241e273f748a1d97a9e59b1abad1d40b50af767bc13d49c` |
| RB2g raw image | `5a8eb206755d3e3d1fc41f190396d04e3fb6c6ededf8afccf7a280944bb456d7` |
| RB2g userdata image | `ea8d2977c5408168e0e5457d66423c73ba9c7be55ce850a991a43cbe3d8fd2cb` |
| Preserved 112-path loader list | `ee60863ae48260e8703b870a0def98e9ffbaa07a784dd6af822060d5503098c5` |
| 216-file sysroot subset manifest | `4f20616be1dcdba99e5140b3781197f101b26a1542321242c4caad2e436f08a9` |

The preserved source receipt records a good Valve signature but also states
that the key is not independently trust-certified. This is provenance
evidence, not a stronger trust claim. The current vendor `steamlinkdeps.txt`
contains **49** package entries, not the work order's earlier lead of 47. The
builder treats 49 as the re-verified value. The sysroot-subset identity covers
each selected relative path, dereferenced file mode, and SHA-256, so a modified
pre-extracted tree refuses even when the preserved raw image remains present.

No package is installed at runtime. The builder extracts the pinned vendor
archive, consumes the preserved 112-path loader closure from the pinned RB2g
sysroot, separates the graphics/media platform slice, normalizes modes and
timestamps, and creates single-threaded zstd squashfs with no xattrs and all
root ownership. It bypasses Valve's installation script because that script
would invoke apt/sudo, mutate udev, and create app-local temporary state. It
does not decide whether Valve bytes may be redistributed; the archive remains
a preserved local input until licensing policy is separately resolved.

Two fresh output directories produced byte-identical root images and platform
manifests:

| Prototype artifact | Identity / size |
| --- | --- |
| App root squashfs | `c4df188387a07b3905f746283d117295ad2716b3730a68658599cbaf12a8f2b1`; 75,923,456 bytes stored |
| App root unpacked tree | 185,190,901 bytes |
| Platform-runtime manifest | `75ae78207603d5a4ee7b1fef4d7bcf399037cc603387cf50c2add9e36e263e1d` |
| Platform-runtime unpacked tree | 115,605,944 bytes, shared rather than charged to the app root |
| Preserved vendor archive | 32,086,587 bytes |

The QEMU harness verifies the descriptor, receipt, squashfs digest, stored
platform manifest, and platform tree before execution. It copies the squashfs
into private measurement scratch, verifies that private copy against the
descriptor and receipt, and extracts only that copy. It also copies the
platform tree there, recomputes and verifies the copy's manifest, and executes
only those private inputs. Unprivileged bubblewrap provides the sandbox-equivalent: a
read-only extracted root, a separately read-only verified platform mount,
private `/dev`, `/tmp` and `/proc`, fresh per-run state, and no Steam
credentials. The host QEMU executable is mounted inside the ephemeral `/tmp`;
the extracted root is not changed to add a harness executable. Both the
direct RB2g-sysroot baseline and app-root variant reach the bounded marker
`Connected to Remote Client service`. Every process group is terminated and
reaped after the sample. An altered-platform negative control, made by
changing a copied library while retaining its original manifest, refuses
before extraction or execution.

## Measurements

**Measurement class: `QEMU/host-development; not A133 performance`.** These
numbers must not be used as A133 latency, memory, graphics, audio, or streaming
claims.

Five runs per variant alternated which variant ran first in each pair and used
the same preserved client binary,
`qemu-aarch64-static`, host network, offscreen Qt, and fresh empty XDG state.
Startup is monotonic time from process creation to the bounded connection
marker. RSS/PSS is summed from `smaps_rollup` for the bubblewrap/QEMU process
tree 100 ms after that marker. The baseline uses the complete preserved RB2g
sysroot; the candidate uses the minimal app root plus read-only platform slice.
The measured host used QEMU 8.2.2
(`e4f8d99e9ff69c3cefffab71cee358ce2af1ecba1282d04c3eeb44ef76f5a71e`)
and bubblewrap 0.9.0
(`e318903862396f96de3df57264e0158682b952fd3fb53ac23d876413e7b30f71`).
Squashfs extraction used unsquashfs 4.6.1
(`b305985eb764b6d0ef757571e3e44044ebf71c827c4263efe576e9e14b4abcfb`).

| Median (n=5 each) | Direct RB2g sysroot | App root | App root minus baseline |
| --- | ---: | ---: | ---: |
| Startup | 1,603.3 ms | 1,608.2 ms | +4.9 ms |
| RSS | 114,076 KiB | 102,584 KiB | -11,492 KiB |
| PSS | 110,804 KiB | 99,313 KiB | -11,491 KiB |

There is no observed positive RSS/PSS cost attributable to duplicated
app-root libraries in this host-QEMU probe; the measured delta is negative
because the candidate exposes and maps a smaller dependency closure than the
full sysroot baseline. Network endpoint/cache variability also dominates the
startup comparison. Repetition is reported to show that variability, not to
imply device precision.

Known prototype limitations are deliberate: offscreen Qt cannot create the
target OpenGL context; the minimal root reports absent `libsndio.so.7`; no
compositor, real ALSA device, controller, codec node, PowerVR host stack, Steam
account, or stream is exercised. Reaching the same remote-client idle marker
demonstrates loader/startup closure only.

## Security boundary and residual attack surface

The boundary is a systemd mount/user/device namespace around an unprivileged
process, not a VM. It limits filesystem persistence and ambient device/socket
authority, but the app still shares the host kernel. Granted GPU, media,
input, sound, compositor, audio, broker, and network interfaces remain attack
surfaces; drivers and protocol peers must validate hostile input. A
`needs_network=true` app receives general host-network egress until a separate
broker/firewall contract exists. A content digest proves identity, not safety
or license.

Fail-closed artifact checks, private devices, exact binds, closed device
policy, user namespace, `NoNewPrivileges`, the current memory limit, and a
single state subtree reduce authority. They do not replace kernel hardening,
signed update policy, SBOM/vulnerability handling, or later physical-device
validation. QEMU/bubblewrap does not prove systemd `RootImage` loop setup,
PowerVR/Cedrus ioctl compatibility, udev ACL mapping, compositor socket
ownership, or A133 performance.

## Hermetic evidence

`tests/test-app-runtime-root.sh` covers:

- exact legacy behavior when `runtime.root` is omitted;
- deterministic root drop-in rendering and fail-closed hardening directives;
- every current canonical capability plus proposed `video-decode` having an
  explicit resource or no-direct-device outcome;
- input read-only versus vibration/rumble read-write escalation;
- undeclared DRM, input, video, and media nodes absent from a private device
  namespace;
- host root and platform runtime write refusal with only per-app state
  persistent;
- invalid schema/digest/library metadata, incompatible platform identity,
  unsupported capability, missing inventory, missing artifacts, changed
  artifact identities, and changed platform content behind an unchanged
  identity marker.

The baseline negative control was run from a fresh archive of the exact image
`origin/main` SHA named above, with only the candidate test module copied in:

```sh
red="$(mktemp -d)"
git archive origin/main | tar -x -C "$red"
cp tests/test_app_runtime_root.py "$red/tests/"
(cd "$red" && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  -v tests.test_app_runtime_root)
```

It exited 1 with `FAILED (errors=13)` because
`scripts/render-app-runtime-root.py` was absent. The initial namespace negative
control also failed until the writable state bind was isolated beneath a
read-only host view. The committed suite is the GREEN regression gate.

## Landing plan and current blocker

1. `tsp-f3fm.202` lands and is reviewed: one strict parser, fixed root,
   helper, unit template, session authority start, platform capability file,
   and launcher pin.
2. Runtime extends that same parser with optional `RuntimeRoot`, the exact
   reason codes and validated `SandboxPlan`, plus `video-decode`. It tests that
   omitted root serializes/resolves exactly as today.
3. Image adds the fixed-function renderer, trusted resource inventory,
   content-addressed stores, platform-runtime assembly, four XDG paths, and
   same-unit drop-in integration. Device/ACL behavior waits for serialized
   physical-device validation.
4. Launcher advances its single runtime pin after runtime merges. The launch
   port remains `item_id`; it gains no root/executable choice.
5. A later Steam Link packaging change consumes a legally permitted preserved
   input, then a separate device plan validates display/audio/controller/codec
   and owner pairing. This design does not ship that tile or client.

The precise merge blocker for production code is the current strict runtime
shape and ownership: `Runtime` rejects `root`, `ReasonCode` has no artifact or
sandbox failures, and session authority starts the unit without a render
transaction. Those are upstream-owned changes overlapping an in-progress
dependency. This PR therefore contains only the design, offline source-owned
prototype/harness, and hermetic contract tests; it does not alter the
production schema, helper, unit, or launcher.
