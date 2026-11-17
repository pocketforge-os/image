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
  kexec applet, and the initrd does not stage kexec-tools yet, so every initrd
  built today takes the typed refusal on a kexec-capable kernel.
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

## Contract and digest effect

- `docs/SELF-FLASH-V3.md` is **unchanged**, so `ContractSHA256` (the digest in
  `/etc/pocketforge-selfflash-v3` and in the runner's request) stays
  `6e87faeeda40125128e6a182918a89a1beea38a6a9942c2b9c43a194e126908e`. Its
  "reboots into the target" step is carried out through the table above.
- The initrd digest **changes**: `/init` and `/lib/pocketforge-self-flash-v3.sh`
  are new bytes. Any pinned initrd or `boot.img` hash for a dev image must be
  re-taken from a container build of this change.
- `build-initrd.sh` now also requires the `od`, `poweroff` and `gunzip` BusyBox
  applets. The staged files are otherwise unchanged.

## Follow-ups (not in this change)

- Stage a static arm64 `kexec` in the dev initrd (it belongs in the build
  container; it is not hand-built here). The kernel side is
  `tsp-76dbc3f58842be997200` (kexec on the default kernel).
- A producer for `/etc/pocketforge-cold-wake` once a kit lane proves cold wake
  is wired (automation#2489 activation modes).
