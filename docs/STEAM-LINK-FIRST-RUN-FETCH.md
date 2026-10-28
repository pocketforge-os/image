# Steam Link signed first-run fetch

## Boundary

PocketForge does not redistribute Valve's Steam Link payload. The image ships a
source-owned Debian 13 application root, launcher, fetcher, trust key, and
minimum-version policy. The fetcher runs as the `pf-app@` unit's unprivileged
`gamer` identity and installs Valve's signed archive only below the application's
state directory. It never invokes sudo, apt, a package manager, or a privileged
host helper.

The one launch path remains `app.toml` → `pf-app@org.pocketforge.steamlink` →
`pf-app-launch`. The descriptor's `[runtime.root]` selects the payload-free
Debian 13 squashfs and the content-addressed host platform runtime from
[the app-root contract](STEAM-LINK-APP-RUNTIME-ROOT.md). The source-owned launch
wrapper prepares or selects the Valve tree in writable state, then executes its
`steamlink/bin/shell`; no Valve file is added to the immutable runtime root.

## Trust and version policy

The minimum accepted version is `1.3.32.316`. Pins are minimums, not a maximum:
automatic updates remain enabled. The exact archive URL and SHA-256 for that
minimum release provide a bootstrap and recovery pin. A newer candidate may be
selected by Valve's `public_build.txt`, but the mutable pointer is discovery
metadata, never an integrity authority.

Every archive must have a valid detached signature from the committed Valve
Steam Link Release Key whose primary fingerprint is pinned in source as
`BA23DAE64102FBE0BB140CE5387C648A24C0E740`. Verification uses a new local GnuPG
home containing only that key. Network/keyserver retrieval is forbidden. Key
rotation requires a reviewed source change to the committed key and fingerprint;
a download cannot extend the trust set.

The fetcher rejects a candidate below the minimum or below the installed
last-good version. The minimum release additionally has to match its committed
archive SHA-256, `6e1e431265da01b85a7a2fb2ef652f822eb16c5b78aca03f0d0d500dc29b93d3`.
After signature verification, the fetcher records the computed SHA-256, version,
signing fingerprint, and source URLs in the installed build receipt.

## State machine and layout

The states are `discover → download → verify → record → extract → ABI check →
atomic switch → launch`.

```text
/var/lib/pocketforge/apps/org.pocketforge.steamlink/
  steamlink-fetch/
    builds/<version>-<archive-sha256>/
      steamlink/...
      receipt.json
    current -> builds/<version>-<archive-sha256>
    last-good -> builds/<version>-<archive-sha256>
    .staging.<random>/
```

Downloads have bounded connect/read time and size. A staging directory is on the
same filesystem as `builds`; only exclusive regular files are created there.
Content-Length disagreement or premature EOF is `reason=download_truncated`.
Network unavailability is `reason=offline`. Neither changes `current` or
`last-good`, and staging is removed on every exit.

The detached signature is checked before extraction. Archive members must have
canonical relative paths below the single `steamlink/` directory. Regular files
and directories are extracted first. Valve's library-name symlinks are created
only afterward, and only when a single-component relative target names an
already extracted regular file in the same directory. Absolute paths, `..`,
hard links, escaping/dangling symlinks, devices, FIFOs, and sockets are rejected.
The extracted `version.txt` must equal the discovered version and `bin/shell`
must be a regular executable. The completed directory is renamed into `builds`
atomically. An atomic relative-symlink replacement moves the old `current` to
`last-good`, then selects the new build.

## Platform ABI gate and fallback

Before the switch, the fetcher validates the read-only platform runtime at
`/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1`. Its manifest must
declare schema 1, runtime id `steamlink-ffmpeg59`, revision `v1`, architecture
`aarch64`, and the exact private library directory. Its library manifest must
hash exactly these regular files, with the corresponding SONAME links:

- `libavcodec.so.59.37.100` / `libavcodec.so.59`
- `libavutil.so.57.28.100` / `libavutil.so.57`
- `libswresample.so.4.7.100` / `libswresample.so.4`

Missing, changed, writable, or unexpected ABI material is
`reason=abi_mismatch`. The app never accepts a bundled or state-owned
`libavcodec.so.59` as a substitute.

On any discovery, download, signature, archive, version, or ABI refusal, a
previously verified `last-good` tree remains selected and may launch with
`fallback=last_good`. A first run with no last-good exits with the typed reason,
allowing the PocketForge launcher to show a bounded retry/error while remaining
usable. Offline with a current verified build performs no download and launches
the cached tree.

## Verification and later device check

`tests/test_steamlink_fetch.py` starts a loopback HTTP fixture over the preserved
Valve 1.3.32.316 archive and signature. One invocation covers successful install,
bad signature, truncated response with no partial install, version below the
floor, ABI mismatch retaining last-good, and offline first run. The preserved
files are read at test time and are never copied into the repository.

The later gpu-14 device window must execute the `.996.19` first-run journey row
on a fresh pf-build image and capture timestamped screen/log PASS/FAIL receipts:
online source/digest/signature presentation and atomic install, offline bounded
retry with a usable launcher, cached relaunch without another download, and an
induced rejected update retaining last-good. No device claim is made here.
