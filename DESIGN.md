# DESIGN — Mesa on-disk shader cache (zstd) for a133-open

Bead: `tsp-mc9m.60.29.64.33` · closes source `tsp-mc9m.41.924.23`
Matrix: row **G11** (open-side shader-cache cost) / evidence **A15** (GLES launch cost by source).
Scope: a133-open image only. Closed (DDK) and none profiles are untouched.

## 1. Problem

The a133-open Mesa build configured with `-Dshader-cache=disabled -Dzlib=disabled
-Dzstd=disabled` (native-precompiler stage `:618`/`:824` is host-only; the target
aarch64 Mesa cross stage `build/Dockerfile.pf:975-977` was the offender). Every
application launch through Zink/EGL recompiled its shaders from source, paying the
compile cost on the CPU for every foreground start even when the same program had
been launched many times before.

## 2. Build change

File: `build/Dockerfile.pf`, target aarch64 Mesa stage `gpu-um-build` only.
Do **not** touch the `gpu-um-native-precompilers` x86_64 host-tools stage — its
`-Dshader-cache=disabled -Dzlib=disabled -Dzstd=disabled` is correct (generators
only, no on-device cache semantics).

Meson flags on the target stage (around `:975-977`):

```
-Dshader-cache=enabled
-Dshader-cache-max-size=64M
-Dzstd=enabled
-Dzlib=disabled          # unchanged from baseline
```

The gpu-um-tsp `meson.build:1738-1743` guard ("Shader Cache requires
compression") demands at least one compression backend be enabled with the
cache. zstd wins over zlib: smaller decompression memory, faster decompress on
the A133 cores, and it is already a rootfs package (`rootfs-packages.txt`
lists `libzstd1`).

Cross sysroot: add `libzstd-dev:arm64` to the `GPUUMSYSROOT` apt-get install
block of the target stage. No runtime package change — `libzstd1` is already
pulled in by the existing rootfs package list.

## 3. Cache location and permissions

Mesa resolves the cache path in this order (`gpu-um-tsp src/util/disk_cache_os.c`
`~:880-881, ~:913, ~:930`):

1. `$MESA_SHADER_CACHE_DIR`, if set.
2. `$XDG_CACHE_HOME/mesa_shader_cache` if `XDG_CACHE_HOME` is set.
3. `$HOME/.cache/mesa_shader_cache` otherwise.

The `gamer` user's home (`/home/gamer`) sits on the single read-write ext4
rootfs partition (`boards/tsp/initrd/init` mounts it `-o rw,noatime`). There is
no overlay, no volatile tmpfs, no split read-only layer — it is the persistent
partition itself. Therefore Mesa's default path is correct and **no override is
needed**.

Permissions: the cache directory is created lazily by Mesa under `$HOME/.cache`,
owned by the running user. Foreground apps run as `User=gamer`
(`pf-foreground@.service:12`), so the cache is `gamer:gamer 0700` automatically.
No extra `tmpfiles.d` / `sysusers.d` entry is required.

## 4. Environment variables

No change is required to the four open-GPU environment files:

- `rootfs-overlay/etc/environment.d/50-pocketforge-open-gpu.conf`
- `etc/profile.d/pocketforge-open-gpu.sh`
- `etc/systemd/system.conf.d/50-pocketforge-open-gpu.conf`
- `etc/systemd/system/pf-foreground@.service.d/50-open-gpu.conf`

Rationale:

- `MESA_SHADER_CACHE_DIR` is unset — Mesa falls through to the persistent
  `$HOME/.cache/mesa_shader_cache`, which is exactly where we want it.
- `MESA_SHADER_CACHE_MAX_SIZE` is unset — Mesa's own runtime default is 1 GiB,
  but the **build-time** `-Dshader-cache-max-size=64M` bakes a 64 MiB hard
  ceiling into the binary, which is what Mesa will use when the env var is
  unset. The same tier as the existing journald caps (`pocketforge-release:
  16M`, `pocketforge-dev: 50M`) — chosen so the cache cannot alone consume the
  rootfs's 25% headroom margin (`scripts/build-rootfs.sh`, "Size the ext4
  image"). Operators can still override at runtime by exporting
  `MESA_SHADER_CACHE_MAX_SIZE=<bytes>` in any of the four env files above.

`PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1` stays where it is — that is the Vulkan
ICD's kill-switch acknowledgement, unrelated to the shader cache but required
alongside it for Vulkan paths to reach Mesa.

## 5. Persistence

The cache lives on the persistent rootfs, so it survives reboots with no extra
work. There is no volatile-root, no tmpfs-backed `/home`, no squashfs overlay
that would throw away the cache on power cycle.

If in a future image the rootfs becomes read-only + overlay, the cache path
**must** be redirected in the four env files to a writable, persistent
location on the userdata partition (e.g. `MESA_SHADER_CACHE_DIR=/var/cache/gamer/mesa`
created by `tmpfiles.d` on the userdata mount). The current design is correct
only for the present single-RW-rootfs layout.

## 6. Measurement

### Before (baseline, today)

- `testgles2` launch from cold: shader-compile wall time dominates the
  launch-to-first-frame interval.
- `find /home/gamer/.cache -name mesa_shader_cache*` after a run: **absent** —
  the cache directory is never created.

### After

- Same probe, first launch from clean: directory exists, non-empty (a handful
  of `.cache` blob files, compressed with zstd).
- Second and subsequent launches of the same program: `zink` skips compile,
  cache hit path runs.

### Numbers to record (coordinator-verified on tsp-base, pf-node-01)

| Run | Launch | Cache state | Launch → first frame (ms) | Shader compiles in trace |
|-----|--------|-------------|--------------------------|--------------------------|
| 1 of 3 before | cold | n/a | record | record |
| 2 of 3 before | cold | n/a | record | record |
| 3 of 3 before | cold | n/a | record | record |
| 1 of 3 after  | cold | empty | record | record |
| 2 of 3 after  | warm | populated | record | 0 |
| 3 of 3 after  | warm | populated | record | 0 |

Method: `pf-foreground` service start with `testgles2`; trace launch-to-first-
frame via the existing bench harness; count shader-compile syscalls from a
`zink` debug trace or a perf probe on the Gallium compile entry. Report median
over the three runs of each bucket.

### CI gate (already landed)

`scripts/verify-mesa-shader-cache.sh` + `tests/test-mesa-shader-cache.sh`
(hermetic, runs in PR CI on `a133-open-7x-gpu`): fail the build unless
`libgallium_dri.so` contains both the compiled Zink cache witness string
(`"zink: Failed to create disk cache queue"`) and an active `DT_NEEDED`
`libzstd.so.1` with `ZSTD_compress`/`ZSTD_decompress` undefined symbols.
Four negative fixtures (cache disabled, no zstd calls, no zstd DT_NEEDED)
must be rejected.

## 7. Risk

### Cache corruption on unclean shutdown

zstd-compressed blobs are read through a header check. A torn write produces a
failed decompress, which Mesa treats as a cache miss — the shader is
recompiled and the new blob is rewritten. No application-visible failure; at
worst a single slow launch after a crash. No `fsck`-style recovery path is
needed.

### Disk-fill edge case

The 64 MiB per-user ceiling is enforced by Mesa itself (cache eviction is LRU
by access time once the ceiling is reached). On a shared device with multiple
users each capped at 64 MiB, the total is bounded and well within the rootfs's
headroom. If a future image lowers the rootfs margin, revisit the ceiling.

### First-launch cold vs warm

The first launch of any program after a cache clear or a program update pays
the full compile cost — this is the same behaviour as today, not a regression.
Subsequent launches are strictly faster. The warm-cache path does not change
any rendering output; cache blobs are keyed on the shader source + driver
version, so a Mesa upgrade invalidates old blobs automatically.

### Cross-profile contamination

The build flag change is gated by `PF_GPU_MODEL=open`. The DDK profile
(`gpu-um-mesa-ddk`) and the none profile
(`gpu-um-mesa-none`) remain at `-Dshader-cache=disabled` — they do not build
Mesa at all (DDK uses the closed userspace; none has no graphics). CI for both
must stay green; the hermetic shader-cache test only runs for `a133-open`.

### Regression on closed-DUK testing

No change to closed/DUK image inputs. The only surface of change is the
aarch64 Mesa cross-build output; the `installed-cross-build-sha256.txt`
reproducibility self-check inside the same stage will catch any accidental
binary drift.

## 8. Scope summary

| File | Change |
|------|--------|
| `build/Dockerfile.pf` `gpu-um-build` (target aarch64 Mesa stage, ~:975-977) | `-Dshader-cache=enabled -Dshader-cache-max-size=64M -Dzstd=enabled`; add `libzstd-dev:arm64` to sysroot apt block |
| `build/Dockerfile.pf` `gpu-um-native-precompilers` (x86_64 host tools, ~:824) | **no change** |
| `rootfs-overlay/etc/environment.d/50-pocketforge-open-gpu.conf` | **no change** |
| `etc/profile.d/pocketforge-open-gpu.sh` | **no change** |
| `etc/systemd/system.conf.d/50-pocketforge-open-gpu.conf` | **no change** |
| `etc/systemd/system/pf-foreground@.service.d/50-open-gpu.conf` | **no change** |
| `scripts/verify-mesa-shader-cache.sh`, `tests/test-mesa-shader-cache.sh` | already added as CI gate |

Acceptance: owned-image-build CI green for `a133-open-7x-gpu` with the Mesa
stage meson summary showing `shader-cache: YES`; coordinator-verified on
tsp-base with the before/after launch timings above.
