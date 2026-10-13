# PocketForge input harness (tsp-ihne1.2)

Shared laptop harness for all gamescope/input work: a **headless gamescope
session** (our fork, branch `pocketforge`, pinned in `pins.env`) with
Xwayland, fake uinput controller/keyboard/mouse, and one test client per
row of the design's *When the keyboard opens* table. Every client writes a
machine-readable **transcript** so downstream beads assert behaviour, not
pixels.

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
| `Containerfile` | 3-stage build: pinned gamescope fork → clients/tools → slim runtime (lavapipe) |
| `pins.env` | gamescope fork URL/branch/commit + base image digest |
| `schema/transcript-schema.md` | transcript JSONL schema (documented, closed) |
| `validate/validate_transcript.py` | stdlib transcript validator (reason=/hint= lines) |
| `report/report.py` | run-directory evaluation → `PASS:`/`FAIL:`/`SKIP:` verdict |
| `selftest/make_fixtures.py` | fixture generator for the hermetic CI self-test |
| `session/entry.sh` | container entrypoint; execs headless gamescope + driver |
| `session/driver.py` | session orchestrator (devices → EIS bridge → clients → screenshots → report) |
| `session/mangoapp` | trusted-client relay for `gamescopectl screenshot` |
| `session/udev-shim.sh` | synthetic udev seat tags for the fake devices |
| `tools/fake-input.c` | uinput daemon: fake pad/keyboard/mouse |
| `tools/eis-bridge.c` | evdev → libeis sender bridge into gamescope |
| `tools/pf-shot.c` | trusted `gamescope_control` screenshot (type 4, waits for `screenshot_taken`) |
| `tools/provision-wayland-protocols.sh` | exposes the closure-pinned 1.49 protocol XMLs to Meson before trixie's 1.44 package |
| `tools/transcript.{h,c}` | `libpf-transcript.so` used by every client |
| `tools/transcript-preload.c` | LD_PRELOAD interposer (cursor names, text-input-v3 availability) |
| `clients/*.c(pp)` | the test clients, one per design table row |

Placement decision (bead asked to record it): everything lives in the
**image repo** under `tests/input-harness/`, next to the existing
gamescope session tests. The fake-pad helper stayed a small C program here
instead of a runtime crate — it is test tooling, not product code.

## Clients and expected behaviour

| Client | Row covered | Backend | Notes |
| --- | --- | --- | --- |
| `gtk4-text` | Wayland apps that ask to show | wayland | GtkEntry, purpose from `PF_TX_PURPOSE` (email), commits via insert-text when available and capture-phase raw-key fallback otherwise; pointer + cursor transcript; readiness is emitted after the first painted frame; wire-protocol `im_state` comes from the preload interposer, never from a hardcoded claim |
| `qt6-text` | Wayland apps that ask to show | wayland | QLineEdit, `ImhDigitsOnly`; digits hint rejects the phrase → raw-keys mode is the expected pass path today |
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
after the PNG is on disk). Captures are 1280x720 PNGs checked against
`screenshots/manifest.json` (run-dir-relative paths, so the report
works both in-container and on the host).

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

The full docker run is a laptop/one-command thing by design (the hermetic
workflow has no docker daemon); it is not wired into CI yet.

## Safety and blast radius

- **Never** `--privileged`, never `/sbin/init`, never systemd in the
  container, never mounts `/` or `docker.sock`, never touches the global
  buildx builder.
- `docker run --rm` only; no anonymous volumes; image labelled
  `pf.bead=tsp-ihne1.2`.
- Container runs as root **inside** its own user namespace only because
  `/dev/uinput` needs it; outputs in the host run dir are chowned back to
  the invoking host user (`HOST_UID`/`HOST_GID`) before exit, so no
  root-owned files land in the worktree or cache.
- Host mounts: `/dev/input` (bind) and the run dir only. `--device
  /dev/uinput` grants creation of **host-visible** input devices — this is
  the harness blast radius: a bug in `fake-input` could inject keystrokes
  into the host session. Mitigations: the daemon destroys its devices on
  stdin EOF, the driver always destroys them in `finally`, and `run.sh`
  refuses to start without `/dev/uinput`.
- `--device-cgroup-rule "c 13:* rmw"` lets the container open input event
  nodes (major 13). It is required because the fake devices are created
  through `/dev/uinput` **after** container start, so they are not in the
  `--device` allow-list and every `open()` of `/dev/input/eventN` would
  fail with EPERM. Scope: input event devices only — still no
  `--privileged`, and no access to disks, DRM or other majors.
- `--network none` at run time (build needs network; the run does not).
- No device, node, labgrid or PSU actions; laptop only.

## Known gaps / design notes (fed back to the plan)

1. **Headless gamescope has no libinput path**: the fork only creates the
   libinput backend when the backend is session-based
   (`src/wlserver.cpp:2114`, `src/Backends/HeadlessBackend.cpp:224`
   `IsSessionBased()==false`). The harness therefore injects input through
   gamescope's EIS (libeis) input-emulation socket:
   `driver → fake-input (uinput) → kernel evdev → eis-bridge (libeis
   sender) → gamescope`. Topology matches production (`pf-input-decode →
   evdev → compositor`); the bridge stands in for the missing libinput.
   When pf-input-broker/router work starts, `session/udev-shim.sh` already
   provides seat-tagged udev entries for the same devices.
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
9. **The laptop harness and device image intentionally use different gamescope
   pins.** The harness uses `8b0f0fd1a6ca1142bde86e3ecfcaca6de295bbf1`
   from gamescope#15 and #16: current lavapipe can start headless without
   `VK_KHR_external_semaphore_fd`, and a headless client commit with no fence is
   ready immediately instead of registering an invalid descriptor. The device
   image remains at `298881e3dff1ade108d57a257e8bf59bf8c6436f` because both
   changes are confined to the headless path. DRM scanout and explicit-sync
   paths still require the extension and wait on a real fence, so the device
   path is unchanged and the harness carries no private gamescope patch.
