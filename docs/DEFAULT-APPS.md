# Default applications: discovery, launch, and return contract

Status: design confirmation for `tsp-f3fm.202`. This document fixes the interfaces and
merge order; it does not implement them.

## Evidence basis

This review used fresh GitHub `main` clones under `/tmp`, not shared checkouts. The exact
heads read were:

| Repository | Commit read |
|---|---|
| `pocketforge-os/runtime` | `a2f149caef326215ce0bff7d0d076bac292595d4` |
| `pocketforge-os/launcher` | `bb8c9bc8c9ea15238d08cfee5376049bf67cf855` |
| `pocketforge-os/image` | `e765ba2cd5d278b977cde1d7c3de4bec83de368e` |
| `pocketforge-os/platform` | `c75b33042eb663b6600ec16c91c77c0afaa4ce0a` |
| `pocketforge-os/poolsuite` | `3e1077679ed78a0fe9726cf894e807ef52b110cd` |

Platform `c75b3304` pins exactly image `e765ba2c`, runtime `a2f149ca`, launcher
`bb8c9bc8`, and Poolsuite `3e107767`; launcher remains explicitly A133-open-only.
[platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`platform.lock:60-68`, `platform.lock:190`, `platform.lock:461-501`,
`platform.lock:533-541`]

## Verdict

The central spike findings are confirmed:

1. `pf-shell` scans `/opt/pocketforge/apps`, but its production provider supplies no
   supported capabilities. Required capabilities therefore make an otherwise valid app
   unavailable. [launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
   `crates/pf-shell/src/main.rs:165-186`; launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
   `crates/pf-catalog/src/lib.rs:217-246`, `crates/pf-catalog/src/lib.rs:448-465`]
2. Activation already sends the descriptor's app id in `LaunchRequest.item_id`; the RPC
   contains only that field. [launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
   `crates/pf-shell-core/src/lib.rs:2745-2762`; runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
   `crates/pf-ports/src/lib.rs:190-200`; runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
   `crates/pf-session-authority/src/lib.rs:457-468`]
3. The device command template ignores that app id, starts `pf-foreground@<session>.service`,
   and that unit starts another `pf-shell`. [runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
   `crates/pf-session-authority/src/lib.rs:257-275`,
   `crates/pf-session-authority/src/lib.rs:358-399`; image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
   `rootfs-overlay/etc/systemd/system/pf-foreground@.service:10-17`]
4. Track A installs Poolsuite under `/opt/pocketforge/apps/org.pocketforge.poolsuite` only
   for A133 dev images; release and A523 selectors are empty, and the dedicated service is
   installed but not enabled. [image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
   `build/Dockerfile.pf:1429-1444`; image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
   `scripts/install-poolsuite.sh:17-30`, `scripts/install-poolsuite.sh:55-68`]

The proposed direction is sound with the coordinator rulings recorded below. The false
premises remain called out rather than silently redesigned.

## Premise confirmation and coordinator rulings

### 1. Trust model: refuted on current images

**REFUTED.** Current A133 and A523 initrds mount the root filesystem explicitly
`rw,noatime`; there is no read-only mount or boot-time dm-verity/signature check in these
paths. The image build records hashes and exact source pins, but that is build provenance,
not a verified read-only root at launch time. [image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`boards/tsp/initrd/init:396-407`; image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`boards/tsp-s/initrd/init:231-246`; platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`platform.lock:1-5`]

**Minimal alternative:** for this first default-app mechanism, define trust as “installed
at image-build time from the lock-selected source, root-owned, not writable by the
unprivileged app service, and path-confined at launch.” Add `ProtectSystem=strict` and an
explicit read-only app path to the unit. Do not claim resistance to a privileged runtime
rootfs modification. Per-app signing and broker-enforced third-party sandboxing remain out
of scope; verified/read-only rootfs work is a separate platform security change.

**Coordinator ruling (accepted):** the narrower statement above is the trust model for this
epic. Default-app trust does not resist privileged runtime modification of the current writable
rootfs. A verified/read-only rootfs is a separate platform security change, not part of this
epic.

### 2. Launch identity: confirmed, with a stricter shared parser required

The launcher already takes `variant.launch_target.app_id`, not the catalog namespace id,
and puts it in `LaunchRequest.item_id`. The catalog obtains that value from `[app].id`.
[launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`crates/pf-shell-core/src/lib.rs:2745-2762`; launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`crates/pf-catalog/src/lib.rs:508-525`]

The present validation is not strict reverse-DNS validation: both the platform schema and
catalog permit repeated dots, and the catalog parser is private to `pf-catalog`.
[platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`abi/app.schema.json:17-34`; launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`crates/pf-catalog/src/lib.rs:150-190`, `crates/pf-catalog/src/lib.rs:549-571`]

**Coordinator ruling (accepted):** runtime adds a small `pf-app-manifest` crate. It owns the
descriptor structs, TOML parsing, id validation, platform-support-file parsing, and fixed-root
resolution. `pf-catalog`, `pf-session-authority`, and `pf-app-launch` all use this crate.
Launcher vendors that exact runtime crate and adds it to the existing source-equality guard,
preserving the current launcher/runtime vendoring model. [launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`Cargo.toml:26-38`; image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`build/Dockerfile.pf:1576-1589`; image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`tests/test-launcher-runtime-contract.sh:4-19`]

The exact accepted id grammar is:

```text
length: 3..=200 bytes
grammar: LABEL "." LABEL ("." LABEL)*
LABEL: [a-z0-9] ([a-z0-9_-]* [a-z0-9])?
```

It requires at least two labels; rejects uppercase, `/`, `..`, empty labels, leading or
trailing punctuation, and punctuation at either end of a label; and stays short enough for
`pf-app@<id>.service`. Poolsuite's `org.pocketforge.poolsuite` satisfies it.
[poolsuite@`3e1077679ed78a0fe9726cf894e807ef52b110cd` `app.toml:1-6`]

Resolution is only beneath the compile-time device root `/opt/pocketforge/apps`:

1. Validate the id before any path construction.
2. Require the fixed root itself to be a real directory, not a symlink.
3. Use `symlink_metadata` plus canonical containment to require
   `/opt/pocketforge/apps/<id>` to be a real directory whose canonical parent is the fixed
   root.
4. Require `app.toml` to be a non-symlink regular file and parse it with
   `pf-app-manifest`.
5. Require parsed `[app].id == <id>`.
6. Require `[launch].exec` to be one relative executable path: normal and `.` components
   are allowed; absolute paths, `..`, an empty value, shell text, and arguments are rejected.
   Require its canonical target to remain within the app directory and be a non-symlink
   regular executable.

The read-only/root-owned alternative in ruling 1 makes canonicalize-then-exec acceptable
for this default-app tier; downloadable or attacker-writable app trees require descriptor-
relative `openat2`/fd execution and are explicitly deferred.

### 3. Capability-only platform file: refuted; it must also carry runtime identity

**REFUTED.** Even after supplying `input` and `audio`, production `pf-shell` advertises
runtime family `pocketforge/native`, while Poolsuite pins `pocketforge/a133-powervr`.
`pf-catalog` checks family and ABI before capabilities, so a capability-only file cannot make
the tile ready. [launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`crates/pf-shell/src/main.rs:50-53`, `crates/pf-shell/src/main.rs:184-186`;
launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`crates/pf-catalog/src/lib.rs:448-465`; poolsuite@`3e1077679ed78a0fe9726cf894e807ef52b110cd`
`app.toml:10-19`]

**Minimal alternative:** keep the proposed single installed file but make it the complete
launcher-facing platform-support contract: family, ABI, platform version, and supported
capabilities. Platform already owns the canonical A133/A523 family ids and platform versions.
[platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`abi/families.toml:32-42`, `abi/families.toml:101-111`; platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`core/abi_view.py:103-128`]

**Coordinator ruling (accepted):** use the expanded contract below. Family, ABI, and platform
version are derived from platform's canonical `abi/families.toml` data as their single source;
there is no second family/ABI source. The image build validates the emitted identity and
capability tuple under the fatal preconditions listed below.

### 4. `needs_network` readiness: refuted as presently modeled

**REFUTED.** `pf-catalog` maps `needs_network=true` unconditionally to
`Availability::NeedsNetwork`; shell launches only `Availability::Ready` variants. Production
shell also uses an unavailable network adapter, so it cannot turn that state into ready when
Wi-Fi is connected. [launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`crates/pf-catalog/src/lib.rs:451-478`; launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`crates/pf-shell-core/src/lib.rs:2631-2678`, `crates/pf-shell-core/src/lib.rs:2688-2703`;
launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`crates/pf-shell/src/main.rs:2382-2431`]

**Minimal alternative:** make `needs_network` launch metadata, not a static unavailable
state. Add `Variant.needs_network: bool` (serde-defaulted for existing snapshots), leave a
compatible installed app `Ready`, and retain the network badge/detail cue. The app then owns
its offline UI. A later real `NetworkPort` may make the cue dynamic without changing the
descriptor contract.

**Coordinator ruling (accepted):** use that non-blocking metadata model. An installed,
compatible app remains `Ready` while retaining the network cue, and the app owns its offline
UI. Poolsuite already maps player connection failures and unavailable conditions into rendered
player states. [poolsuite@`3e1077679ed78a0fe9726cf894e807ef52b110cd`
`crates/ps-app/src/main.rs:663-677`; poolsuite@`3e1077679ed78a0fe9726cf894e807ef52b110cd`
`crates/ps-ui/src/lib.rs:1415-1423`] A production `NetworkPort` and dynamic readiness are out
of scope.

### 5. Poolsuite's currently pinned descriptor is not catalog-valid

**REFUTED.** Poolsuite declares `[app].theme`, but both the canonical platform schema and
`pf-catalog` deny unknown `[app]` fields. It also pins platform version `18`, while the
current A133 family offers `20`. [poolsuite@`3e1077679ed78a0fe9726cf894e807ef52b110cd`
`app.toml:1-19`; platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`abi/app.schema.json:17-35`; launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`crates/pf-catalog/src/lib.rs:150-190`; platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`abi/families.toml:34-45`]

Poolsuite already falls back to `classic` when no descriptor theme is found, so removing the
non-canonical key preserves that fallback. [poolsuite@`3e1077679ed78a0fe9726cf894e807ef52b110cd`
`crates/ps-app/src/main.rs:883-916`]

**Minimal alternative:** before the final lock bump, a Poolsuite PR removes `[app].theme`,
bumps `platform-version` to `20`, and runs the platform validator. `input`, `audio`,
`launch.audio=true`, and `needs_network=true` remain unchanged.

**Coordinator ruling (accepted):** that prerequisite Poolsuite PR is required and proves
`pf app-validate`; version `20` is the platform used by target A133-open dev image `add26f08`.
Theme selection stays in Poolsuite's persisted settings, and its fallback remains `classic`.
[poolsuite@`3e1077679ed78a0fe9726cf894e807ef52b110cd`
`crates/ps-app/src/main.rs:905-915`, `crates/ps-app/src/main.rs:931-944`,
`crates/ps-app/src/main.rs:1151-1197`]

### 6. Generic unit and return path: partly confirmed, lifecycle observation is missing

The foreground target already has `StopWhenUnneeded=yes`; its selected-shell drop-in
conflicts with and then restores `pf-shell-selected.service` through `OnSuccess`. A unit that
requires and orders after the target therefore returns panel ownership when it exits.
[image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`rootfs-overlay/etc/systemd/system/pocketforge-foreground.target:21-37`,
`rootfs-overlay/etc/systemd/system/pocketforge-foreground.target:54-71`;
image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`rootfs-overlay/etc/systemd/system/pocketforge-foreground.target.d/10-owner-shell.conf:1-6`]

**REFUTED for the complete session lifecycle.** On device, nothing currently submits the
authority's running/exit/target/owner/presentation observations. The only call sites that do
so are desktop-sim helpers; the production socket client only launches, polls events, and
acknowledges them. The authority otherwise remains in `Starting` after a successful command.
[launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`crates/pf-shell/src/main.rs:2002-2032`, `crates/pf-shell/src/main.rs:2532-2565`;
runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
`crates/pf-session-client/src/lib.rs:112-160`, `crates/pf-session-client/src/lib.rs:205-225`;
runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
`crates/pf-session-authority/src/lib.rs:815-885`]

**Minimal alternative:** retain the existing observation ladder, but make the device
`SessionSystem` query the exact `pf-app@<id>.service`, foreground target, and selected-owner
states during daemon reconciliation. A successful blocking `systemctl start` records
`SessionRunning`. The first `Events` call from the restored shell advances clean/crash,
unit-inactive, target-released, and owner-active observations from systemd state. After the
restored shell presents its first frame it sends the already-defined
`RpcRequest::Observe { presentation_acknowledged }`; only then does the authority publish
`Returned`. This preserves the documented receipt truth condition.
[runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
`crates/pf-session-authority/src/lib.rs:1-7`, `crates/pf-session-authority/src/lib.rs:470-492`,
`crates/pf-session-authority/src/lib.rs:908-928`]

**Coordinator ruling (accepted):** implement systemd-backed reconciliation in the runtime PR,
and publish `Returned` only after the restored shell's `presentation_acknowledged`. Visual
restoration alone is insufficient. **Inference:** because the launch publishes a durable
`Starting` event and no production path currently advances the observation ladder, the
restarted launcher would replay that state without a truthful terminal receipt.

### 7. Branding gate and application scope: explicit migration required

The current Track A selector is keyed only by SoC and variant, not `PF_GPU_MODEL`, and the
rootfs path invokes `install-poolsuite.sh` unconditionally. An A133 vendor/default dev image
therefore currently receives the Poolsuite tree and dedicated service. [image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`build/Dockerfile.pf:1429-1444`; image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`scripts/build-rootfs.sh:731-738`]

**Coordinator ruling (accepted):** the generic mechanism ships only on A133-open dev and
release profiles, and Poolsuite ships only on A133-open dev. Narrowing Poolsuite is an explicit,
tested migration: A133 vendor/default dev loses the Poolsuite tree and dedicated service and
selects the source-free `NOT-SHIPPED` producer, removing its Poolsuite fetch/compile cost. A133
vendor/default release and every A523 profile remain byte-identical. Moving Poolsuite to
A133-open release after written permission remains a selector change and is not part of this
work. Platform already gates the launcher source to open profiles. [platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`core/profile.py:427-450`]

## Fixed interfaces

### Session port and RPC

The launch port does not gain a path or executable field:

```rust
pub struct LaunchRequest {
    pub item_id: String, // canonical app id, for example org.pocketforge.poolsuite
}
```

The wire request remains:

```json
{"method":"launch","item_id":"org.pocketforge.poolsuite"}
```

The authority treats `item_id` only as an id, validates and resolves it below the fixed root,
and never accepts a caller-supplied path. Invalid, unknown, mismatched, or unsupported apps
return the existing `LaunchResult::ItemUnavailable` / `RpcResponse::ItemUnavailable`; the
stable reason is journaled, not exposed as customer copy. Busy remains
`RejectedBusy`. These response variants already exist. [runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
`crates/pf-ports/src/lib.rs:190-200`; runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
`crates/pf-session-authority/src/lib.rs:496-506`,
`crates/pf-session-authority/src/lib.rs:565-574`]

The device command templates become:

```text
start:     systemctl start pf-app@{item_id}.service
graceful:  systemctl stop pf-app@{item_id}.service
terminate: systemctl kill --kill-who=all pf-app@{item_id}.service
owner:     systemctl start pf-shell-selected.service
```

The durable authority state must retain `item_id` through Running, Stopping, ForceStopping,
and Restoring so stop/kill/reconciliation address the same validated unit. `session_id`
remains the receipt/history identity. Today those later phases retain only `session_id`, which
is why this state change is required. [runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
`crates/pf-session-authority/src/lib.rs:84-111`; runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
`crates/pf-session-authority/src/lib.rs:266-275`,
`crates/pf-session-authority/src/lib.rs:729-759`]

There is no fallback to `pf-foreground@`, another shell, the dedicated Poolsuite service, or
an executable supplied by the launcher.

### `pf-app-launch` CLI

Production syntax is exactly:

```text
pf-app-launch <app-id>
```

It has no production `--root`, `--exec`, or descriptor-path option. Tests inject a root through
the library API. It re-runs the same fixed-root resolver and `pf-app-manifest` parser used by
the catalog, changes directory to the resolved app directory, creates the already-authorized
XDG subdirectories if absent, and `execve`s the single resolved `[launch].exec` path without a
shell. Successful execution replaces the helper, so the application exit status and signal
are systemd's status.

Helper-only exit codes are fixed:

| Exit | Meaning |
|---:|---|
| 64 | usage error (wrong argument count) |
| 65 | invalid id, invalid TOML/descriptor, id mismatch, missing `[launch]`, invalid `launch.exec`, or platform-contract mismatch |
| 66 | fixed root, app directory, descriptor, or executable not found / wrong file type |
| 74 | other metadata, canonicalization, read, or XDG-directory I/O error |
| 126 | final executable exists but cannot be executed |

Every helper refusal emits one stable reason code from the table below before exiting. The
authority independently resolves before starting systemd; a helper refusal after authority
acceptance is therefore treated as a crash/drift, not `ItemUnavailable`.

### `pf-app@.service`

The image-owned template is:

```ini
[Unit]
Description=PocketForge default application %i
Requires=pocketforge-foreground.target
After=local-fs.target pocketforge-foreground.target
Conflicts=shutdown.target
Before=shutdown.target
ConditionPathExists=/dev/fb0

[Service]
Type=simple
User=gamer
Group=gamer
SupplementaryGroups=audio input video
WorkingDirectory=/opt/pocketforge/apps/%i
Environment=XDG_CONFIG_HOME=/var/lib/pocketforge/apps/%i/config
Environment=XDG_STATE_HOME=/var/lib/pocketforge/apps/%i/state
ExecStart=/usr/bin/pf-app-launch %i
StateDirectory=pocketforge/apps/%i
StateDirectoryMode=0700
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
PrivateTmp=yes
ReadOnlyPaths=/opt/pocketforge/apps/%i
ReadWritePaths=/var/lib/pocketforge/apps/%i
KillMode=control-group
KillSignal=SIGTERM
TimeoutStopSec=2s
Restart=no
MemoryMax=256M
Nice=-5
```

The template is installed but never enabled. It joins the existing foreground target exactly
as display apps do, and the target's image-selected drop-in restores the launcher. The current
Poolsuite service already demonstrates the required unprivileged user, supplementary groups,
app working directory, target join, state directory, stop timeout, and no-restart posture.
[image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`rootfs-overlay/etc/systemd/system/pocketforge-poolsuite.service:1-26`]

`Wants=network-online.target` is deliberately absent from the generic template: it cannot be
conditioned by descriptor data, and ruling 4 makes `needs_network` non-blocking metadata. The
app receives the real network state and owns its offline presentation.

The dedicated `pocketforge-poolsuite.service` is removed, and `install-poolsuite.sh` stops
installing it. Keeping it would create a second launch path that bypasses the authority's id,
descriptor, and lifecycle checks. Its useful generic directives are carried by
`pf-app@.service`. The service is disabled today, so removal does not remove a boot-time enable
edge. [image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`scripts/install-poolsuite.sh:50-68`; image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`tests/test-poolsuite-rootfs-install.sh:32-50`]

### Platform support file

The installed path is fixed:

```text
/usr/share/pocketforge/platform-capabilities.toml
```

Schema v1 is exact and denies unknown fields:

```toml
schema_version = 1
runtime_family = "pocketforge/a133-powervr"
runtime_abi = "1"
platform_version = "20"
supported_capabilities = ["audio", "entropy", "input", "settings"]
```

`supported_capabilities` must be sorted, unique, unmodified base names present in runtime's
canonical known-capability list. `egress:<host>` and `?` are app requirements, not platform
entries. Runtime currently defines the known base set, and its broker treats input, entropy,
audio, and settings as always-backed platform capabilities. [runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
`crates/pocketforge/src/backend.rs:233-258`; runtime@`a2f149caef326215ce0bff7d0d076bac292595d4`
`crates/pf-broker/src/manifest.rs:441-453`,
`crates/pf-broker/src/manifest.rs:619-627`]

Platform makes `abi/families.toml` the single source for the launcher-facing runtime family,
ABI, and platform version, alongside the canonical supported-capability declaration.
`profile.py` resolves that data and emits these four deterministic build arguments only for
A133-open profiles; image renders the TOML file:

```text
PF_APP_RUNTIME_FAMILY
PF_APP_RUNTIME_ABI
PF_APP_PLATFORM_VERSION
PF_APP_CAPABILITIES
```

No new repository or BuildKit context is introduced. Non-open profiles emit none of these
arguments, so the generic mechanism adds no non-open rootfs bytes. The separate A133
vendor/default dev Poolsuite-removal migration is fixed in section 7; byte identity remains the
gate for A133 vendor/default release and all A523 profiles. This uses platform's existing profile
and build-argument seam, which already emits runtime, launcher, Poolsuite, and image identities.
[platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`core/profile.py:392-470`; platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`core/pf-build.sh:520-547`]

`pf-shell` accepts `--platform-capabilities <path>` for hermetic tests and defaults to the fixed
installed path. A missing, unreadable, malformed, wrong-schema, or semantically invalid file
logs one warning and falls back to today's `pocketforge/native`, ABI `1`, no platform version,
and an empty capability set. That preserves the work order's missing-file behavior while making
the failure visible. The production provider passes all four parsed values to `pf-catalog`.

`pf-catalog` compares family, ABI, platform version (when the app pins one), and required
capabilities. Optional capabilities remain non-blocking. This closes the current gap where
platform version is recorded in provenance but not compared. [launcher@`bb8c9bc8c9ea15238d08cfee5376049bf67cf855`
`crates/pf-catalog/src/lib.rs:448-478`, `crates/pf-catalog/src/lib.rs:508-525`]

### Stable refusal and warning reason codes

Logs use a parseable one-line shape with JSON-escaped values:

```text
pf-session-authorityd: launch_refused reason=<code> item_id=<json-string>
pf-app-launch: launch_refused reason=<code> item_id=<json-string>
pf-shell: platform_contract_fallback reason=<code> path=<json-string>
```

The codes are API-stable diagnostics:

| Layer | Reason codes |
|---|---|
| id/root | `invalid_id`, `app_root_missing`, `app_root_symlink`, `app_not_found`, `app_dir_not_directory`, `app_dir_symlink`, `app_dir_escape` |
| descriptor | `descriptor_missing`, `descriptor_not_regular`, `descriptor_symlink`, `descriptor_parse`, `descriptor_invalid`, `descriptor_id_mismatch`, `launch_missing` |
| executable | `launch_exec_invalid`, `exec_missing`, `exec_not_regular`, `exec_symlink`, `exec_escape`, `exec_not_executable`, `exec_io` |
| platform/app compatibility | `runtime_family_mismatch`, `runtime_abi_mismatch`, `platform_version_mismatch`, `unsupported_capability`, `platform_contract_missing`, `platform_contract_invalid` |
| backend/lifecycle | `systemd_start_failed`, `systemd_state_unknown`, `app_exit_failed`, `target_not_released`, `owner_not_active`, `presentation_not_acknowledged` |
| shell platform file | `missing`, `read`, `parse`, `schema`, `invalid_family`, `invalid_abi`, `invalid_platform_version`, `invalid_capability`, `duplicate_capability`, `unsorted_capabilities` |

No invalid id is interpolated into a path, unit name, or command before `validate_app_id`
succeeds. No refusal falls back to the old foreground shell.

## Ordered PR and pin sequence

The ordering below is load-bearing. Image currently hard-codes both the runtime and launcher
SHAs, its tests assert those literals, and platform's lock selects the image/runtime/launcher
triplet. Moving runtime or launcher in the lock before an aligned image fails at the old image
guard. [image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`build/Dockerfile.pf:1113-1126`, `build/Dockerfile.pf:1564-1589`;
image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`tests/verify-w2c-prefsd-wiring.py:30-45`;
image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`tests/test-launcher-runtime-contract.sh:4-19`]

1. **Platform preparation PR (no `platform.lock` pin movement).** Add the app-runtime
   capability declaration/schema, derive the family/version, emit the four build args, and add
   resolver tests. **Inference:** because the old Dockerfile does not consume the new build
   arguments, every existing lock-selected build remains valid. Scope: schema/source for the
   platform contract, with the new build arguments emitted only for A133-open; non-open profile
   outputs and rootfs bytes remain unchanged.
2. **Poolsuite descriptor prerequisite PR.** Remove `[app].theme`, bump `platform-version` 18
   to 20, and prove `pf app-validate`. Scope: Poolsuite source only; the current lock continues
   selecting `3e107767` until step 6.
3. **Runtime PR.** Add `pf-app-manifest`, strict resolver, `pf-app-launch`, authority resolution,
   item-id-aware commands and persisted lifecycle state, systemd reconciliation, reason codes,
   and hermetic positive/negative tests. Merge it. Scope: source only until the final lock bump;
   the helper is architecturally device-generic.
4. **Launcher PR, based on the merged runtime SHA.** Vendor `pf-app-manifest` and all changed
   runtime contract crates; load the platform file; use family/ABI/version/capabilities; model
   network as decided in ruling 4; and test tile/activation. Merge it. Scope: launcher source;
   deployment remains A133-open-only because platform emits a launcher repo/SHA only for open
   GPU profiles. [platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
   `core/profile.py:427-443`, `core/profile.py:476-481`; platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
   `platform.lock:485-501`]
5. **Image PR, before any pin movement.** Update both hard-coded SHA guards to the merged
   runtime and launcher heads; update `verify-w2c-prefsd-wiring.py`,
   `test-launcher-runtime-contract.sh`, and the vendored-crate equality list. In A133-open
   stages only, build/install `pf-app-launch`, render/install the platform file, add
   `pf-app@.service`, and remove the dedicated Poolsuite service. Make the Poolsuite producer
   selector require `PF_GPU_MODEL=open` as well as A133/dev, and assert an A133 vendor/default
   dev fixture selects the source-free `NOT-SHIPPED` stub before any Poolsuite fetch or compile.
   Add unit/rootfs/profile tests that prove A133 vendor/default release and all A523 outputs
   remain byte-identical and contain none of the default-app files. The A133 vendor/default dev
   fixture instead proves the intentional removal migration: no Poolsuite tree, dedicated
   service, provenance, fetch, or compile. Merge it. The old platform lock still selects image
   `e765ba2c`, so no fleet build sees the new guards yet.
6. **One atomic platform lock PR owned by gpu-14.** Move `image`, `runtime`, and `launcher`
   together to the merged steps 3-5 heads, and move `poolsuite` to the merged step 2 head. Do not
   split these pin changes. The same PR refreshes derived ABI/build evidence required by
   platform policy.
7. **Only after step 6:** run hermetic image builds/reviews. Device acceptance is separately
   scheduled on `tsp-base` using the A133-open dev image; it is not performed by these
   implementation turns.

This is the required three-way interlock: runtime/launcher merge first, the image realigns to
both, and one platform lock PR moves image/runtime/launcher together.

### Image inputs and new fatal preconditions

The design adds **no new staged repository input and no new BuildKit context**. The existing
contexts remain image, kernel, GPU, SDL, WPA, runtime, blobs, vendor manifest, bootchain,
Poolsuite, and profile-gated sim/hwprobe/open-GPU/launcher/recovery contexts.
[platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`core/pf-build.sh:165-193`, `core/pf-build.sh:525-550`]

When the image pin moves, the pin owner must check every co-pin read by the new Dockerfile:
runtime, launcher, Poolsuite, recovery, sim, hwprobe, SDL, WPA, kernel/GPU/GPU-UM, bootchain,
blobs, vendor manifest, and the CAR digest. The current rootfs stage forwards those identities.
[image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`build/Dockerfile.pf:1623-1651`, `build/Dockerfile.pf:1687-1710`]

The image PR adds or updates these fatal preconditions:

1. `PF_RUNTIME_SHA` equals the merged runtime head; the wiring and launcher/runtime tests assert
   the same literal.
2. `PF_LAUNCHER_SHA` equals the merged launcher head in the open stage.
3. The launcher's vendored `pf-app-manifest` and every changed runtime contract crate are
   byte-equal to the staged runtime source.
4. On A133-open, all four `PF_APP_*` values are present, syntactically valid, internally
   compatible, and `PF_APP_CAPABILITIES` is sorted, unique, and a subset of runtime's known set;
   non-open profiles emit none of the four.
5. On A133-open, the generated platform TOML parses back to the exact build-arg values.
6. On A133-open, `pf-app-launch` exists, is AArch64, and satisfies the same static-musl check as
   the other runtime helpers.
7. On A133-open, `pf-shell`, `pf-session-authorityd`, `pf-app-launch`, `pf-app@.service`, and the
   platform TOML are all present or the build fails. Every non-open profile installs none of the
   default-app helper, template, or platform file. A133 vendor/default release and all A523
   profiles must remain byte-identical to their corresponding pre-feature outputs; A133
   vendor/default dev is the explicit Poolsuite-removal migration in item 8.
8. The Poolsuite producer selects the real tree only for A133 + `PF_GPU_MODEL=open` + dev, and
   that tree must pass the shared descriptor validator before installation. A133 vendor/default
   dev must select the source-free `NOT-SHIPPED` stub and contain no Poolsuite tree, dedicated
   service, or provenance marker; A133-open release, A133 vendor/default release, and all A523
   profiles remain exact no-ops for the app tree.

The recovery literal remains a co-pin even though this design does not change it; current image
checks it in both the recovery build stage and rootfs script. [image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`build/Dockerfile.pf:1494-1506`; image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`scripts/build-rootfs.sh:1787-1803`]

## Per-profile scope

The corrected coordinator scope follows the existing launcher/session-authority deployment
boundary: the complete default-app mechanism ships only on A133-open dev and release. A133
vendor/default and A523 receive no helper, template, or platform file. A133 vendor/default dev
is the explicit Poolsuite-removal migration; byte identity remains required for A133
vendor/default release and every A523 profile.

| Change | A133 open (dev/release) | A133 vendor/default DEV | A133 vendor/default RELEASE | A523 (dev/release) |
|---|---|---|---|---|
| Platform support declaration/build args | emitted; A133 family/ABI/version/caps | not emitted; no generic files added | not emitted; byte-identical | not emitted; byte-identical |
| `pf-app-manifest` source | compiled into authority/helper; vendored into shell | no image integration | no image integration; byte-identical | no image integration; byte-identical |
| `pf-app-launch`, `pf-app@.service`, platform TOML | installed; template dormant until launch | absent | absent; byte-identical | absent; byte-identical |
| `pf-session-authorityd` change | installed/enabled on open profiles | remains absent | remains absent; byte-identical | remains absent; byte-identical |
| launcher change | installed on open profiles | remains absent and no launcher source is staged | remains absent; byte-identical | remains absent and no launcher source is staged; byte-identical |
| Poolsuite payload | dev only; release absent | **migration: payload removed; `NOT-SHIPPED` stub selected** | absent; byte-identical | absent; byte-identical |
| dedicated Poolsuite service | removed from the open dev path it formerly served | **migration: service removed** | absent; byte-identical | absent; byte-identical |

The current image explicitly gates session authority and launcher on `PF_GPU_MODEL=open`, and
platform emits launcher identity only for open profiles. [image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`build/Dockerfile.pf:1172-1203`, `build/Dockerfile.pf:1564-1589`;
platform@`c75b33042eb663b6600ec16c91c77c0afaa4ce0a`
`core/profile.py:427-443`]

The earlier “mechanism ships in all images” wording was coordinator wording, not the owner's
decision. The owner's decision is that Poolsuite becomes a default app. This corrected scope is
load-bearing: tests must fail if any generic default-app file reaches a non-open output, or if a
real Poolsuite producer reaches any profile except A133-open dev. A133 vendor/default dev is not
a byte-identity case; its required delta is exactly removal of the existing Poolsuite payload,
service, provenance, and build cost.

## Failure modes and hermetic tests

| Failure mode | Required test and owner |
|---|---|
| Valid app is accidentally refused | Runtime: one invocation creates a real root/app/descriptor/executable and proves successful resolution/exec alongside all three coordinator-mandated negatives. |
| Traversal or malformed id reaches a command/path | Runtime: reject `../outside`, `org..example`, `/absolute`, uppercase, edge punctuation, overlength, and single-label ids; assert no executor call and `reason=invalid_id`. |
| Symlinked app directory escapes root | Runtime: symlink `<root>/org.example.app` to an outside valid tree; reject `app_dir_symlink`/`app_dir_escape`; same invocation includes the positive real-directory control. |
| Descriptor id differs from requested/directory id | Runtime: valid descriptor with `[app].id=org.example.other`; reject `descriptor_id_mismatch`; same invocation includes the positive matching control. |
| Descriptor or executable is a symlink/escape | Runtime: descriptor symlink, absolute exec, `../` exec, exec symlink outside, non-regular exec, and non-executable file; assert the exact reason and helper exit class. |
| Catalog and launcher parse differently | Runtime + launcher: shared fixture corpus is parsed only through `pf-app-manifest`; image vendored-source equality includes the crate. |
| Unknown id falls back to shell | Runtime: unknown valid id returns `ItemUnavailable`, logs `app_not_found`, performs zero start calls, and never references `pf-foreground@`. |
| Start/stop target different apps | Runtime: lifecycle test proves start, graceful stop, forced kill, and reconciliation all render `pf-app@<same-item-id>.service`; session id remains receipt id. |
| Authority accepts then helper rejects | Runtime: mutate fixture between authority resolution and helper call; helper fails closed and lifecycle records crash/drift, never fallback. |
| App clean-exits but launcher stays `Starting` | Runtime + launcher: fake systemd reports clean inactive app, inactive target, active owner; restored shell polls, presents, acknowledges, then receives exactly one `Returned`. |
| App crashes | Runtime + launcher: non-success systemd result produces `Crash`, still restores/presents launcher, and never reports `Returned`. |
| Safe-return stop or kill times out | Runtime: existing graceful deadline and forced-close tests are repeated with item-id units and persisted/restarted state. The authority already models those phases and receipts. [runtime@`a2f149caef326215ce0bff7d0d076bac292595d4` `crates/pf-session-authority/src/lib.rs:729-780`, `crates/pf-session-authority/src/lib.rs:829-857`] |
| Platform file missing/malformed | Launcher: missing, unreadable, invalid TOML, wrong schema, unknown cap, duplicate, unsorted; each yields one exact warning and empty capabilities with legacy family/ABI fallback. |
| Runtime family/ABI/platform version mismatch | Launcher + runtime: each mismatch is unavailable/refused with its stable reason; matching A133 v20 is ready. |
| Required capability absent | Launcher: `input` or `audio` missing makes Poolsuite `UnsupportedCapability`; both present with the matching identity makes it ready; an optional cap stays ready. |
| Network metadata blocks forever | Launcher: with no production network backend, `needs_network=true` remains launchable and exposes the approved network cue. |
| Wrong unit rendering | Image: parse `pf-app@.service`; assert exact root, user/groups, XDG paths, target join, hardening, no enable symlink, stop/restart policy, and helper command. |
| Dedicated Poolsuite bypass survives | Image: assert no `pocketforge-poolsuite.service` in source or installed tree and installer has no unit argument/install. |
| Capability file/build args drift | Platform + image: every A133-open profile emits the expected deterministic tuple and generated TOML round-trips; non-open profiles emit no tuple or file; unknown/missing open input is fatal. |
| Runtime/launcher/image lock split | Image + platform: negative fixtures move each SHA alone and prove the old/new image guard refuses; positive fixture moves image/runtime/launcher together. |
| A133 vendor/default dev migration regresses | Image + platform: the selector fixture proves A133 + non-open + dev resolves the source-free `NOT-SHIPPED` producer before any Poolsuite fetch/compile; its rootfs fixture contains no Poolsuite tree, dedicated service, or provenance marker. |
| Non-open default-app scope expands accidentally | Platform + image: every non-open profile emits no launcher or `PF_APP_*` identity, stages no launcher context, and contains none of the three generic default-app files. A133 vendor/default release and all A523 profiles also match their pre-feature byte fixtures. |
| Branding leaks to release or non-open profiles | Image + platform: the selector matrix proves the real Poolsuite producer is selected only for A133 + open + dev; A133 vendor/default dev exercises the migration, and every release/A523 case selects `NOT-SHIPPED`. The generic mechanism exists only in A133-open dev/release. |

## Device acceptance boundary

No implementation turn for this design uses a device, bench, labgrid, runner, build host, or
`pf build`. After the atomic lock PR and hermetic image review, device acceptance is a separate
`tsp-base` bench window: capture Poolsuite tile, activation into the player, app exit, and the
restored launcher. The bench is currently gated by `.923.42.1` (FEL) and `.984.9` (PSU safety),
and visual acceptance requires the owner's approval. Those gates are coordination facts, not
claims established by the reviewed repositories.

## Explicit non-goals

This work does not add downloadable installation, per-app minisign/cosign verification,
third-party broker sandbox enforcement, a production network-control adapter, verified boot,
an A133-open release selector for Poolsuite, or any default-app integration or rootfs byte change
for A133 vendor/default release or A523. A133 vendor/default dev is the sole non-open migration:
it removes the existing Poolsuite payload and service. The existing descriptor documents those
future signing and packaging siblings, while the owner decision for this bead limits the first
mechanism to image-shipped default apps on A133-open. [image@`e765ba2cd5d278b977cde1d7c3de4bec83de368e`
`docs/APP-DESCRIPTOR.md:10-36`, `docs/APP-DESCRIPTOR.md:38-59`]
