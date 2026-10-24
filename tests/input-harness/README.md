# PocketForge input harness (tsp-ihne1.2)

The default hermetic tier is a **headless gamescope session** (our fork,
branch `pocketforge-linear`, pinned in `pins.env`) with Xwayland, private
keyboard/pointer event streams, and one test client per row of the design's
*When the keyboard opens* table. Every client writes a
machine-readable **transcript** plus pre/post text-region frames so downstream
beads assert both widget state and visible compositor output.

The guest tier packages the same clients and guarded `fake-input` into a
separate, content-addressed, read-only arm64 squashfs attachment. pfvd mounts
that attachment at `/opt/pf-input-harness` only for a requested harness
session. The production image and its `/usr/bin/gamescope` remain byte-for-byte
unchanged; the attachment never supplies gamescope.

One command builds the container, runs the whole session and prints the
house verdict:

```sh
tests/input-harness/run.sh            # add --out DIR to choose the run dir
```

Default run dir: `~/.cache/pf-input-harness/run-<UTC timestamp>/` with
`transcripts/*.jsonl`, `session.jsonl`, `screenshots/*.png` (1280x720,
type `screen_buffer` for golden comparison) and `screenshots/manifest.json`.

## Layout

| Path | What |
| --- | --- |
| `run.sh` | one-command entry (build + run + verdict) |
| `run-guest.sh` | guarded real-kernel entry used only in the pfvd guest or matching DUT |
| `guest/agent.py` | bounded framed virtio-serial request/artifact agent |
| `Containerfile.guest-payload` | pinned Bookworm arm64 attachment producer; builds the normalized squashfs twice and compares bytes |
| `guest-payload.{pins,lock}` | external source pins plus the produced squashfs SHA256/size |
| `verify-guest-payload.sh` | verifies producer output and manifest against the committed content address |
| `negative-control.sh` | explicitly authorized host-run wrapper; brackets the session with host input and journal checks |
| `Containerfile` | 3-stage build: pinned gamescope fork → clients/tools → slim runtime (lavapipe) |
| `pins.env` | gamescope fork URL/branch/commit + base image digest |
| `schema/transcript-schema.md` | transcript JSONL schema (documented, closed) |
| `validate/validate_transcript.py` | stdlib transcript validator (reason=/hint= lines) |
| `report/report.py` | run-directory evaluation → `PASS:`/`FAIL:`/`SKIP:` verdict |
| `report/layout_scenario.py` | exact GTK readback evaluator for keyboard-layout scenarios |
| `selftest/make_fixtures.py` | fixture generator for the hermetic CI self-test |
| `session/entry.sh` | container entrypoint; execs headless gamescope + driver |
| `session/driver.py` | session orchestrator (private streams → EIS bridge → clients → screenshots → report) |
| `session/mangoapp` | trusted-client relay for `gamescopectl screenshot` |
| `tools/private-input.c` | command reader that writes native `struct input_event` packets to an inherited private fd |
| `tools/eis-bridge.c` | private input-event fds → libeis sender bridge into gamescope |
| `tools/fake-input.c` | retained source for guarded VM/DUT runs only; calls the vendored domain guard before its opener and is not built into the default harness image |
| `tools/pf_uinput_domain_guard.h` | byte-for-byte runtime guard vendored from `bb923b328eced983daef2210aded6febe3ce2fdf` |
| `selftest/uinput-domain-v1.{tsv,SOURCE}` | shared 23-case domain fixture plus pinned source/hashes |
| `session/udev-shim.sh` | retained source for guarded VM/DUT runs only; unused by the default harness |
| `tools/pf-shot.c` | trusted `gamescope_control` screenshot (type 4, waits for `screenshot_taken`) |
| `tools/provision-wayland-protocols.sh` | exposes the closure-pinned 1.49 protocol XMLs to Meson before trixie's 1.44 package |
| `tools/transcript.{h,c}` | `libpf-transcript.so` used by every client |
| `tools/transcript-preload.c` | LD_PRELOAD interposer (cursor names, text-input-v3 availability) |
| `clients/*.c(pp)` | the test clients, one per design table row |

## Keyboard-layout scenario

The default host-safe run adds two compositor sessions after the client
matrix. Each session runs the production
`/usr/lib/pocketforge/kbd-layout-env` generator against an explicit stored
`keyboardLayout`, sources its rendered environment, and only then starts
gamescope. The shared driver sends evdev `KEY_Y` and `KEY_SEMICOLON` through
the same private `SOCK_SEQPACKET` → `eis-bridge` path as every other client.
The German session requires the GTK widget readback `zö`; the restarted U.S.
session requires `y;`. A deliberately wrong U.S. expectation against the
German transcript must exit nonzero with
`reason=layout_widget_text_mismatch`. Both sessions retain their transcript
and before/after screenshots under `layout-scenario/{de,us}/`.

Placement decision (bead asked to record it): everything lives in the
**image repo** under `tests/input-harness/`, next to the existing gamescope
session tests. The default path uses only process-private sockets. The legacy
kernel-device helper remains source-only here for the separate guarded VM/DUT
tier; it is test tooling, not product code.

## Guest attachment

`.github/workflows/input-harness-payload.yml` builds the attachment on
`[self-hosted, pf-builder-vm]`; it cannot select `trimui-build-lab`. The
digest-pinned build container creates two Bookworm arm64 sysroots from the
pinned Debian snapshot, builds libei, SDL3, the clients and guarded helper,
normalizes every timestamp to the snapshot's fixed nonzero epoch, then runs
`mksquashfs` twice with one compressor thread. Squashfs has no filesystem UUID,
and mksquashfs sorts each directory before assigning inode numbers. A byte
mismatch fails before publication. `manifest.json` records the
snapshot, external commits, recipe/source hashes, runtime package closure,
payload size and digest.

The guest tool build runs through qemu-user on the x86 builder and takes its
parallelism from that runner's `nproc`; a cold producer must fit the existing
40-minute build-step guard. Pull requests force a no-cache build to retain cold
timing evidence, then verify without writing any external store. A matching
main push sends the verified squashfs, manifest and
CI receipt through the write-once trusted modelmaker intake, emitting a typed
receipt and SHA256 for each object. GitHub artifact storage is not used for
these build outputs. Intake is not publication: the producer never writes the
read-only store. After the main run, gpu-14 promotes each named, verified
`trusted-builder` intake object and confirms it is served from the modelmaker
SHA store. Consumers pin and fetch only those promoted immutable objects and
verify the committed addresses again.

The bootstrap loader cache is discarded with the other install-time state,
then regenerated once from the completed arm64 tree with its own
`/usr/sbin/ldconfig -i`. The auxiliary cache is removed afterward. This keeps
the `/etc/ld.so.conf.d` search paths available without allowing producer-host
cache state into the attachment.

The required `PF_APT_PROXY` build argument routes each producer apt invocation
through the fleet apt-cacher-ng because BuildKit RUN steps have no DNS. A
missing or non-HTTP value is refused before apt starts; mmdebstrap still
verifies the snapshot's signed package metadata. External source commits are
checked out and archived on the runner, SHA-verified there, then supplied as
named read-only build contexts; no BuildKit RUN step performs a DNS lookup.
The output is test-only and is never installed into a product rootfs.

## Clients and expected behaviour

| Client | Row covered | Backend | Notes |
| --- | --- | --- | --- |
| `gtk4-text` | Wayland apps that ask to show | wayland | GtkEntry, purpose from `PF_TX_PURPOSE` (email), commits via insert-text when available and capture-phase raw-key fallback otherwise; pointer + cursor transcript; readiness is emitted after the first painted frame; wire-protocol `im_state` comes from the preload interposer, never from a hardcoded claim |
| `qt6-text` | Wayland apps that ask to show | wayland | QLineEdit, `ImhDigitsOnly`; injects the compatible phrase `1234567890` and requires exact QLineEdit readback |
| `sdl3-text` | patched SDL3 native Wayland | wayland | `SDL_StartTextInput`, TEXTINPUT commits, screen-keyboard events |
| `sdl2-game` | SDL2 game through sdl2-compat | wayland | Debian's `libsdl2` **is** sdl2-compat; no org fork exists (see gaps) |
| `x11-gtk` | X11 apps with GTK/Qt | x11 | GTK3 via Xwayland with `GTK_IM_MODULE=simple` (deterministic im-context-simple commits), purpose url, records `im_state none/unavailable` |
| `xim-only` | X11 XIM-only apps | x11 | pure Xlib; records XIM availability (unavailable: no XIM server) and raw keys; never commits |
| `no-im` | app with no input method | wayland | raw libwayland client; never binds any text-input protocol; keys only; waits for the first xdg_surface configure before attaching a buffer (not_constructed protocol rule) |
| `wpe-view` | WPE minimal view | wayland | **not available** in the harness image → report emits `SKIP:` (bead: "if available") |
| `broken-client` | negative control | headless | deliberately invalid transcript (seq gap, unknown event, bad type, no stop) — the run only passes when the validator catches it; the verdict line shows the caught `FAIL` with `reason=` |

Until the gamescope text-input-v3/input-method-v2 relay lands (tsp-501qb,
blocked on this harness), Wayland clients cannot receive protocol commits.
`report.py` therefore accepts either `mode=commits` (phrase appears in
commit events) or `mode=raw_keys` (every phrase character observed as a
pressed key + input-method availability recorded). When the relay lands,
tighten the specs to commits-only.

## Transcripts

JSONL, schema `pf-input-harness.transcript/v1`, fully documented in
[`schema/transcript-schema.md`](schema/transcript-schema.md). Validate one:

```sh
python3 -B tests/input-harness/validate/validate_transcript.py <run>/transcripts/gtk4-text.jsonl
```

## Screenshots

`pf-shot <path> 4` (`tools/pf-shot.c`, screenshot type 4 =
`screen_buffer`, the buffer displayed 1:1) executed through the
trusted-client relay: gamescope's `--mangoapp` path spawns
`session/mangoapp` under `gamescopereaper --respawn` with a trusted
`WAYLAND_SOCKET`; the stand-in blocks on a FIFO and `exec`s one
`pf-shot` per command, so each screenshot consumes exactly one trusted
connection. `pf-shot` binds the privileged `gamescope_control` global,
requests the capture and waits for the `screenshot_taken` event (sent
after the PNG is on disk). Each text client is captured before typing and
again after its exact `widget_text` readback. `report.py` decodes both
1280x720 PNGs and requires a client-calibrated material pixel count and
horizontal span in that client's declared text region; a stale or partial
one-glyph compositor frame fails with
`reason=stale_frame`. The paths and phases live in
`screenshots/manifest.json` (run-dir-relative, so the report works both
in-container and on the host).

The pure-Xlib `xim-only` control uses XDrawString's compact server font, so
its calibrated floor is lower than the source-owned glyph-atlas clients while
still rejecting a seeded short-prefix frame. This keeps the gate tied to the
renderer's actual text footprint instead of assuming every client uses the
same font scale.

`gamescopectl screenshot` is deliberately NOT used: its `Execute()`
forwards only two strings over `gamescope_private`, so the type
argument is dropped and the compositor's console command falls back to
`base_plane_only` (no overlays) without waiting for the write — see
known gap 7.

## CI

The hermetic self-test runs on every PR in `hermetic-tests.yml`
(no docker, no network): fixture generation → validator → report, with
positive and negative controls in one invocation:

```sh
tests/test-input-harness-selftest.sh
```

The payload producer is a source-build PR check. The real-kernel tier is a
manual-only pfvd workflow on `[self-hosted, pf-builder-vm]` or a modelmaker
run, always inside the host bracket and only after per-run approval; it is
never run on the laptop. The fixture-only self-test above remains safe to run. It
compiles `fake-input.c` against a mocked probe/opener (never a device node),
checks the shared execution-domain fixture and hashes, exercises the laptop
negative-control wrapper with fake `/proc` and journal inputs, and runs the
repo-wide uinput occurrence inventory with seeded red controls.

## Safety and blast radius

- **Never** `--privileged`, never `/sbin/init`, never systemd in the
  container, never mounts `/` or `docker.sock`, never touches the global
  buildx builder.
- `docker run --rm` only; no anonymous volumes; image labelled
  `pf.bead=tsp-ihne1.2`.
- The runtime receives no host device option, no device cgroup rule, and no
  host input bind. Its only host bind is the chosen output directory.
- `driver.py` creates two `AF_UNIX/SOCK_SEQPACKET` socketpairs. It passes the
  writer ends only to `private-input` and the reader ends only to `eis-bridge`.
  Both endpoints are ordinary process-private fds; no kernel input device,
  udev announcement, host libinput subscription or host-session event exists.
- `private-input` accepts commands on stdin and sends complete native
  `struct input_event` packets with `SYN_REPORT`. It never opens a path.
- The fixture-only CI self-test statically rejects any Docker device option,
  device cgroup rule, `/dev/uinput` reference or `/dev/input` bind in `run.sh`,
  and proves the detector with a seeded copy of the former unsafe grants.
- The 2026-10-13 incident established that uinput is host-kernel global and
  containers do not isolate it. The source-only `fake-input.c` therefore calls
  the approved positive-identity guard before opening uinput. It refuses bare
  metal and a desktop VM with
  `reason=unsafe_uinput_domain domain=<class>` and reaches its opener only in
  a pfvd guest or on a DUT. The vendored header SHA256 is
  `eef274664360cac95c7087a3a1ac0be960710eee8eea77768340fa1f80ba79ef`;
  the shared fixture SHA256 is
  `538fce952f5de6cb901c46c1919aedc44dcd436e753f7786c1a6e5fe21ad2fb9`.
- `tests/uinput_inventory.py` classifies exact line hashes for every owned
  uinput creation/exposure reference in this repo, fails on new or stale
  entries, and proves the gate with duplicate, stale and seeded-violation red
  controls.
- Every approved CI/modelmaker guest run uses
  `negative-control.sh --out DIR --receipt FILE` as its host bracket. It snapshots
  `/proc/bus/input/devices`, records user/system journal cursors, polls for any
  added input-device entry while the private-FD harness runs, and terminates
  the session immediately on an addition. Its receipt contains the before and
  after device lists verbatim, both journal deltas, the harness log, and a
  second functional report covering widget text, pointer activation, the
  deliberately broken transcript and pixel deltas. It fails on the input-device
  hazard signatures `PocketForge Fake`, XINPUT/xf86 device addition,
  libinput/GNOME/mutter device addition, or kernel `input:` registration;
  generic PocketForge service lines are counted as receipt information. The wrapper
  creates its snapshots rather than copying procfs permissions, preserves the
  original before snapshot and journal cursor records in a mode-0700
  `<receipt>.evidence/` directory, and writes a typed receipt from its EXIT
  finalizer on success, host-safety abort, timeout, or internal failure. Receipts
  also serialize test mode, every injected/real source path, the named journal
  patterns, and per-pattern counts. In real mode the wrapper resolves and
  accepts only its canonical sibling `run.sh` or `run-guest.sh`; arbitrary
  executables, symlinks and non-canonical traversal spellings fail with
  `reason=runner_not_allowlisted`. The receipt records the canonical runner
  path and its SHA256. The manual pfvd workflow enters through `run-guest.sh`,
  which delegates only to `ci/run-input-harness-e2e.sh` in the exact committed
  pfvd checkout; no caller-selected nested executable is accepted.
- `--network none` at run time (build needs network; the run does not).
- No host input passthrough: QEMU command lines must reject `input-linux`,
  `usb-host`, evdev passthrough, `/dev/uinput`, and `/dev/input/*` routes.
- No device, node, labgrid or PSU actions from this harness worker.

## Known gaps / design notes (fed back to the plan)

1. **Headless gamescope has no libinput path**: the fork only creates the
   libinput backend when the backend is session-based
   (`src/wlserver.cpp:2114`, `src/Backends/HeadlessBackend.cpp:224`
   `IsSessionBased()==false`). The harness therefore injects input through
   gamescope's EIS (libeis) input-emulation socket:
   `driver → private-input → SOCK_SEQPACKET input_event stream → eis-bridge
   (libeis sender) → gamescope`. The private stream exercises gamescope's
   keyboard, absolute-pointer, focus and button paths without entering the
   host kernel input subsystem. Real evdev fidelity belongs to the guarded
   pfvd guest/DUT tier.
2. **sdl2-compat**: no `pocketforge-os/sdl2-compat` fork exists; Debian
   trixie's `libsdl2` is sdl2-compat (2.32.x), which covers the row until
   the hint-ignoring patch (D2-E2) needs a fork.
3. **WPE**: no WPE package in the harness image; `wpe-view` is an optional
   client and reports `SKIP`.
4. **X11 cursor names** are opaque (Xcursor images, no names) — the
   preload interposer only captures Wayland cursor theme lookups.
5. **No emoji**: consistent with round-7 X3 (no emoji font in the image),
   no client or fixture uses emoji.
6. Headless lavapipe timing says nothing about GE8300/A53 compositing cost
   (D2-R1); this harness is for behaviour contracts, not performance.
7. **gamescopectl cannot select a screenshot type**: its `Execute()`
   forwards only `name` + one argument over `gamescope_private`, so
   `gamescopectl screenshot <path> 4` silently captures
   `base_plane_only` (type 1 — no overlays) and returns before the
   write completes. The harness uses `tools/pf-shot.c` (binds
   `gamescope_control`, type 4 `screen_buffer`, waits for
   `screenshot_taken`). Fed back to the plan: any downstream bead that
   wants overlay-inclusive goldens (OSK, system menu) must use
   `gamescope_control` directly or fix `gamescopectl`.
8. **Gamescope's wlroots pin requires wayland-protocols >=1.48**, while
   Debian trixie provides 1.44. The harness mirrors gamescope's aarch64 CI:
   it materializes the manifest's `wlroots-wayland-protocols` edge at
   `aa62366fb800a0689f4e9de83811ff33f6a91f44`, copies that 1.49 tree outside
   `subprojects/`, and places a generated `wayland-protocols.pc` first on
   `PKG_CONFIG_PATH` before Meson resolves the dependency. Production
   `pf build` resolves this differently,
   from the snapshot-pinned Bookworm backports package in its owned build
   environment; neither path patches gamescope source.
9. **The laptop harness and the device provenance pipeline pin the same
   gamescope commit.** The harness uses
   `cf4475a73409295b06ec352f18497fef23422a72` (pocketforge-linear tip, matching
   `build/produce-gamescope-pvr-cache.sh`), carrying gamescope#15–#21:
   current lavapipe can start headless without
   `VK_KHR_external_semaphore_fd`; a headless client commit with no fence is
   ready immediately and nudges the compositor so the frame is presented;
   reused wl_shm buffers refresh their damaged pixels before composition; and
   partial damage is tracked across shm buffer pools (gamescope#21), so a
   pooled double-buffered commit presents its full updated region instead of
   dropping the newest repaint — the gtk4-text last-glyph miss seen at
   `5dd17e1c`. The tip also contains the panel-orientation quarter-turn
   inversion; runtime orientation still falls back to the fixed mount when the
   harness has no session-authority socket. DRM scanout and explicit-sync
   still require the extension and wait on a real fence.
   `guest-payload.pins` keeps its own
   `298881e3dff1ade108d57a257e8bf59bf8c6436f` pin for the reproducible guest
   payload — a different path, deliberately untouched. The harness carries
   no private gamescope patch.
