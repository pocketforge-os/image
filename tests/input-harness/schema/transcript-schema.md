# Input harness transcript schema (pf-input-harness.transcript/v1)

Each test client writes one transcript file per run:

    <out>/transcripts/<client>.jsonl

The file is JSON Lines: one JSON object per line, UTF-8, no trailing
commas, no top-level array. Lines are appended in event order and flushed
so a crashed client still leaves a readable prefix.

## Common envelope (every line)

| Field       | Type   | Meaning                                            |
| ----------- | ------ | -------------------------------------------------- |
| `schema`    | string | Constant `pf-input-harness.transcript/v1`.         |
| `client`    | string | Client id, e.g. `gtk4-text` (matches file name).   |
| `seq`       | int    | 1-based, strictly +1 per line, no gaps.            |
| `t_mono_us` | int    | Monotonic microseconds since client start, non-decreasing. |
| `event`     | string | Event name from the table below.                   |

Unknown extra fields are rejected: the schema is closed so drift is caught
by the validator, not by a human reading logs.

## Lifecycle events

- `start` — first line. Fields: `pid` (int), `argv` (array of string),
  `backend` (`wayland` | `x11` | `headless` | `drm`; `headless` and `drm` are
  used by session.jsonl, whose client is the compositor session itself), `display`
  (string, the WAYLAND_DISPLAY or DISPLAY value the client connected to).
- `stop` — last line. Fields: `rc` (int, client exit status).
- `mapped` — the client's top-level surface/window was mapped (Wayland
  configure or X11 MapNotify). Fields: `width`, `height` (int, surface
  size in px).
- `error` — client-side failure. Fields: `message` (string). Any `error`
  event makes the client FAIL.

## Input events

- `enter` — keyboard focus entered the client's surface. Fields:
  `serial` (int, protocol serial where available, else 0).
- `leave` — keyboard focus left. Fields: `serial` (int).
- `key` — raw key event. Fields: `keycode` (int, evdev or X11 keycode),
  `keysym` (string, resolved name or `""`), `state` (`pressed` |
  `released`), `mods` (int, modifier bitmask).
- `content` — text-input content type/purpose. Fields:
  `source` (`set` — value the client asked its toolkit for, `protocol` —
  value observed on the wire), `hints` (array of string: `auto-correct`,
  `auto-completion`, `auto-capitalization`, `hidden`, `sensitive`,
  `latin-only`, `multiline`, `none`), `purpose` (string: `normal`,
  `alpha`, `digits`, `number`, `phone`, `email`, `url`, `password`,
  `pin`, `terminal`, `multiline`, `unknown`).
- `commit` — text was committed into the field. Fields: `text` (string),
  `source` (`im` — via an input-method/text-input protocol, `toolkit` —
  synthesized locally by the toolkit (e.g. GTK IMContextSimple), `key` —
  synthesized by the client from raw keys).
- `preedit` — composing/pre-edit text changed. Fields: `text` (string).
- `widget_text` — text read back from the client's real displayed widget or
  application text buffer after input handling. Fields: `text` (string). The
  final value must exactly equal that client's expected phrase.
- `im_state` — input-method availability/state observed by the client.
  Fields: `protocol` (`text-input-v3`, `input-method-v2`,
  `gamescope-input-method`, `xim`, `sdl-textinput`, `none`), `state`
  (`available`, `unavailable`, `enabled`, `disabled`).
- `screen_keyboard` — on-screen-keyboard visibility signal (SDL). Fields:
  `shown` (bool).

## Pointer / cursor events

- `pointer_motion` — Fields: `x`, `y` (number, surface-local).
- `pointer_button` — Fields: `button` (int, Linux input event code),
  `state` (`pressed` | `released`), `x`, `y` (number).
- `pointer_axis` — Fields: `axis` (`vertical` | `horizontal`), `value`
  (number).
- `cursor` — a named cursor was requested for the pointer. Fields: `name`
  (string, e.g. `text`, `default`, `pointer`). On Wayland clients this is
  captured by interposing `wl_cursor_theme_get_cursor` in
  `libpf-transcript-preload.so`; on X11 clients cursor names are opaque,
  so only Wayland clients emit this event (documented limitation).

## Session-level events

Session infrastructure (fake input devices, compositor readiness,
screenshots) is logged by the driver to `<out>/session.jsonl` using the
same envelope with `client` = `session` (including `start` first and
`stop` last, `backend` = `headless`) and these extra events:

- `device_created` — Fields: `kind` (`keyboard` | `pointer`), `name`
  (string), `event_source` (string; currently `private-seqpacket`). These are
  process-private streams, not kernel devices.
- `compositor_ready` — Fields: `pid` (int), `wayland_display` (string),
  `x_display` (string), `backend` (string, e.g. `headless`).
- `client_launch` / `client_stop` / `client_exit` — Fields: `client` is
  `session`; `target` (string, client id), `rc` (int, on exit). The driver
  records `client_stop` immediately before asking the client to terminate.
- `screenshot` — Fields: `target` (string, client id), `phase` (`before` |
  `after`), `path` (string), `type` (int, gamescope screenshot_type),
  `width`, `height` (int, expected size). Text clients have one capture in
  each phase; the final frame must visibly differ in its declared text region.

## Validation

`validate/validate_transcript.py` (stdlib-only Python) enforces the
envelope, the per-event field sets and types, `seq` contiguity,
`start`-first/`stop`-last, and non-decreasing `t_mono_us`. It exits 0 on a
valid transcript and prints `reason=<code> hint=<text>` on stderr when it
rejects one. `report/report.py` evaluates a whole transcript directory
against the per-client expectations and prints the house verdict lines.
