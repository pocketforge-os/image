# Self-flash v3: post-write hand-off

Bead: `tsp-fd3619f30f92cf9c62f5` (parent `tsp-mc9m.60.29.84`). Code:
`boards/tsp/initrd/self-flash-v3.sh` (`BEGIN/END POCKETFORGE SELF-FLASH V3
HANDOFF`), called from the v3 gate in `boards/tsp/initrd/init`. Tests:
`tests/test-initrd-selfflash-v3-handoff.sh` (full table) and the hand-off
section of `tests/test-initrd-selfflash-v3.sh`.

## Why

Until this change a verified write ended in `sync; reboot -f`. On the A133 that
warm reset can fall through to the eMMC TinaLinux chain instead of the newly
written SD (window `0f770435`: BOOT0 logs `card no is 2`). The initrd now leaves
for the new target by the most direct route the running kernel and board allow.

## Hand-off table

Evaluated only after `sf_v3_run_armed_transaction` returned 0.

| Write verified | Kernel `kexec_load` | kexec binary | Cold-wake marker | Action |
|---|---|---|---|---|
| no | any | any | any | no hand-off: `PF_SELF_FLASH_V3_HANDOFF_REFUSED mode=any reason=write_not_verified`, terminal recovery (FEL) |
| yes | available | present | any | kexec the target's `boot.img` (kernel, ramdisk, cmdline) |
| yes | available | absent | wired | `PF_SELF_FLASH_V3_HANDOFF_REFUSED mode=kexec reason=kexec_binary_absent`, then `poweroff -f` |
| yes | available | absent | not wired | same typed refusal, then `reboot -f` |
| yes | unavailable | any | wired | `poweroff -f` |
| yes | unavailable | any | not wired | `reboot -f` (previous behavior) |
| yes | kexec chosen, but target unreadable, `kexec -l` failed, or `kexec -e` returned | | | `PF_SELF_FLASH_V3_HANDOFF_FALLBACK from=kexec to=reboot reason=<target_boot_image_invalid\|kexec_load_failed\|kexec_exec_returned>`, then `reboot -f` |

Every hand-off emits one decision line on the console before acting:

```text
PF_SELF_FLASH_V3_HANDOFF decision=<kexec|poweroff|reboot> kexec=<available|refused|unavailable> kexec_reason=<available|kexec_core_absent|kexec_load_disabled|kexec_load_disabled_unreadable|kexec_load_not_configured|kexec_binary_absent> cold_wake=<wired|absent>
```

If the final `kexec -e`, `poweroff -f` or `reboot -f` returns, `/init` enters
terminal recovery with the mode and fallback reason. kexec failure never falls
back to `poweroff -f`.

"Recorded" means the typed console/serial line above. The hand-off writes no
block device after the `pass` receipt and stamp, so the stamped target stays
exactly as verified; nothing is persisted to the SD.

## Definitions

- **Write verified**: transaction status 0, `XzResult`, `WriteResult` and
  `StampResult` all `pass`, decompressed SHA-256 and byte count equal to the
  descriptor, and the admitted SD fd still open.
- **Kernel `kexec_load` available**: `/sys/kernel/kexec_loaded` exists
  (`CONFIG_KEXEC_CORE`), `/proc/sys/kernel/kexec_load_disabled` reads `0`, and,
  if `/proc/config.gz` exists, it contains `CONFIG_KEXEC=y` (this rules out a
  `KEXEC_FILE`-only kernel). Without `/proc/config.gz` a `KEXEC_FILE`-only kernel
  fails at `kexec -l` (ENOSYS) and takes the recorded reboot fallback.
- **kexec binary**: regular executable file at `/sbin/kexec`. BusyBox has no
  kexec applet. Every `--variant dev` initrd gets a static AArch64 kexec-tools
  2.0.32 build at this path (see "Static kexec" below). Release initrds do not
  carry it and do not carry the self-flash engine. Only a dev initrd built
  before tsp-624ea955036f01d58629 takes the `kexec_binary_absent` refusal on a
  kexec-capable kernel.
- **Cold-wake marker**: `/etc/pocketforge-cold-wake` in the initrd, a regular
  file (not a symlink) with exactly these two lines:

  ```text
  Schema=pocketforge.cold-wake/v1
  ColdWake=wired
  ```

  Absent, extended, symlinked or any other value means not wired. No build
  stages this marker yet; `poweroff -f` is reached only on an initrd built with
  it.

## What kexec loads

The target is read only through the admitted SD fd, never by device name:

1. GPT header at LBA 1 (`EFI PART`), 128-byte entries, at most 128 entries;
2. exactly one partition named `boot`, lying wholly inside
   `[0, TargetRawBytes)`, so it is part of the verified write;
3. its Android boot image v0 header (`ANDROID!`, page size 2048 or 4096): the
   kernel, which must carry the arm64 `ARM\x64` Image magic, the ramdisk, and
   the NUL-terminated 512-byte cmdline.

These go into the initrd work directory (not the candidate-image staging rule:
the candidate stays on the SD) and are passed as
`kexec -l <kernel> --initrd=<ramdisk> --command-line=<cmdline>`, then
`kexec -e`. No `--dtb` is passed, so kexec-tools reuses the running,
firmware-fixed-up FDT (`/sys/firmware/fdt`). The target's TOC1 DTB is **not**
used; if a target needs a different DTB, use the cold or reboot path until that
is supported. GPT CRCs are not checked; the whole written range was already
checked against `TargetRawSHA256`.

## Static kexec

Bead `tsp-624ea955036f01d58629`. `boards/tsp/initrd/build-kexec-static.sh`
builds kexec-tools from the upstream release tarball, which is committed byte
for byte in `third_party/kexec-tools/` together with its kernel.org signature.
`third_party/kexec-tools/SOURCE.md` has the provenance, signing key and flags.
The build runs in the pinned build container with no network and links
statically against glibc 2.33. The builder refuses to continue if either pin
does not match:

| Pin | SHA-256 |
|---|---|
| source `kexec-tools-2.0.32.tar.xz` | `8f81422a5fd2362cf6cb001b511e535565ed0f32c2f4451fb5eb68fed6710a5d` |
| `/sbin/kexec` (742248 bytes, stripped) | `09b191b07a4d24e7ccf3546199b68368cf02931706db67b3305662c00fd098c2` |

`build-initrd.sh` stages it only inside the dev-only self-flash block. With
`PF_TEST_BUILD_CONTAINER=<container.pin image>`,
`tests/test-initrd-selfflash-v3-handoff.sh` builds the dev initrd twice in the
container. It checks that the two builds are byte-identical and that the packed
`/sbin/kexec` is a regular 0755 static AArch64 file with the pinned digest.

The kernel side, `CONFIG_KEXEC=y` with G2D kept, is kernel#185. On a kernel
that lacks it, the table's `unavailable` rows still apply.

## Contract and digest effect

- `docs/SELF-FLASH-V3.md` is **unchanged** by both image#407 and this change.
  `ContractSHA256` therefore stays
  `6e87faeeda40125128e6a182918a89a1beea38a6a9942c2b9c43a194e126908e`. That is
  the digest in `/etc/pocketforge-selfflash-v3`, in the normal-root marker and
  in the runner's request. A base and a target built from this change carry
  the same contract. A base built before it also carries the same contract,
  but its initrd has no kexec. The hand-off runs in the **base** initrd, so it
  can kexec only when the base itself was built with this change.
- **InitrdSHA256 changes for dev images only.** The dev initrd gains
  `/sbin/kexec` (plus 361 KB compressed in the 7.x open fixture below). Every
  base descriptor `InitrdSHA256`, and every pinned dev `initrd.gz` or
  `boot.img` hash, must be re-taken from a container build of this change. The
  value is the effective `/boot/initrd.gz` of that image. It depends on the
  kernel, the modules and `SOURCE_DATE_EPOCH`, so the repo pins no single
  value. Release initrds are byte-identical to before.
- Reference fixture: the 7.x open model (`--gpu-model open --gpu-km-model
  in-tree-7.x --kernel-required-modules powervr`, empty `modules.builtin`)
  built with `SOURCE_DATE_EPOCH=1790605388`. Results:
  - dev initrd: `5396fe7162f8c27a122fb740969df26a6e17d9f6e189be00430b5f45f69107b3` (1014504 B) before, now
    `f92adca2083c52bfa7393101ac48bc1916b38dccf845a222c4364934f97758ee`
    (1375746 B);
  - release initrd: unchanged at
    `2f7b1a81ca6a405acbb2f01ba7742c51235de55ab632500aad4808a306bc4a90`.
- image#407 made `build-initrd.sh` also require the `od`, `poweroff` and
  `gunzip` BusyBox applets.

## Follow-ups (not in this change)

- A producer for `/etc/pocketforge-cold-wake` once a kit lane proves cold wake
  is wired (automation#2489 activation modes).
- A device lane that proves `kexec -l`/`-e` on kernel#185 lands in the target
  (no device action was taken here).
