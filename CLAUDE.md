# PocketForge Image Builder

Builds the bootable SD image for the TrimUI Smart Pro (Debian 12 arm64 + PowerVR fbdev DDK + `libSDL3-pocketforge` + Steam Link bootstrap + owned boot chain). Cross-repo doctrine lives in [`pocketforge-os/mission-control`](https://github.com/pocketforge-os/mission-control); this file is orientation only.

## Session startup + working norms

Run `bd prime` (auto-injected), `bd dolt pull`, register + background your pf-wall listener, `bd update <id> --claim`, and edit in a fresh `pf-wt create <bead-id> --repos image[,…]` worktree — never in `/home/matt/image` directly. Full checklist: [mission-control CLAUDE.md](https://github.com/pocketforge-os/mission-control/blob/master/CLAUDE.md); worktree/branch→PR→merge norm: [mission-control git-workflow rules](https://github.com/pocketforge-os/mission-control/blob/master/.claude/rules/git-workflow.md). Every change is a `<bead-id>` branch → PR → merge; no straight-to-default pushes.

## Shared Claude Code substrate

`.claude/settings.json` enables the shared `pf@pocketforge` plugin ([pocketforge-os/claude-plugins](https://github.com/pocketforge-os/claude-plugins)): skills (`/build-image`, `/close-bead`, `/file-bead`, `/flash`, `/kickoff`, `/plan-doc`, `/screen-check`, `/serial-review`), custom agents (`log-triage`, `researcher`, `screen-reviewer`), enforcement hooks (PreToolUse deny+redirect, Stop DoD gate, InstructionsLoaded audit).

## Repo-specific gotchas

- **Container-owned toolchain (ARM A-Profile 10.3-2021.07 / gcc 10.3.1 / glibc 2.33) — never hand-build.** Owned artifacts (BL31, U-Boot, kernel, GPU KM, SDL) build ONLY in `pocketforge/build:10.3-2021.07-bookworm` (pinned by `container.pin` sha256). The image build lives behind [`/build-image`](https://github.com/pocketforge-os/claude-plugins/blob/main/plugins/pf/skills/build-image/SKILL.md) → `pocketforge-automation/scripts/build-owned-image.sh --target modelmaker`; interactive default is `modelmaker` (~9 min, Threadripper), `dell` is the ~45-min fallback. Native-toolchain output is non-reproducible and NOT release-valid.
- **`build/check-glibc-symver.sh` refuses any binary linking GLIBC_2.34+.** That is a hard gate for the Debian 12 rootfs — do not disable it to get a build to pass; investigate why a symbol is newer than 2.33 and fix the source or its build.
- **`snapshot-date.txt` pins the apt snapshot.debian.org date** — a single line, e.g. `20260601T000000Z`. Bumping it re-hashes the rootfs (every apt package resolves to a new archive URL). Only bump deliberately + on its own bead + verify the container still resolves everything.
