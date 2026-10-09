# Volatile-root selection for batched release-image kits

Status: design for `tsp-mc9m.41.995.43.1`; implementation requires gpu-14
approval. The reviewed source worktrees are `pocketforge-os/kernel-sunxi-7.x`
(`device/a133`), `pocketforge-os/image` (`main`), and
`pocketforge-os/platform` (`main`).

## Decision

Use one transient kernel argument, `pocketforge.root=volatile`, on a direct
SD-payload boot from the node's RAM-resident recovery U-Boot. Keep the release
image's default command line and persistent-root behavior unchanged.

`#PocketForge.FelBoot` currently RAM-boots recovery U-Boot, exposes the whole SD
through UMS, writes and reads back the entire image, then exits UMS and cold
boots the freshly flashed media (`test-node-farm/node/bin/node-recover.sh:1-18`,
`:884-912`, `:976-1024`). That cold boot cannot add a one-shot argument: the
flashed release U-Boot has `CONFIG_BOOTDELAY=0`, and its command and command line
are compiled in (`pocketforge-platform/platform.lock:1083-1102` and
`pocketforge-platform/docs/A133-OPEN-7X-OWNED-SPL.md:30-40`).

The node already has the required non-persistent primitive. Its FelSdBoot path
loads `Image`, `dtb.bin`, and `initrd.gz` from the SD, validates a caller-supplied
`--bootargs`, applies it with RAM-only `setenv bootargs`, and calls `booti`
(`test-node-farm/node/bin/fel-sd-boot.sh:184-221`, `:422-442`, `:474-515`). The
session adoption should reuse that command sequence immediately after the UMS
readback, while the recovery U-Boot is still at its prompt, instead of performing
the normal cold cycle. The session-facing choice is an enum (`RootMode=Volatile`),
not arbitrary bootargs or an ambient flag: the node constructs the exact release
command line plus the one additional token. It must refuse seed injection or any
other post-readback write and record `boot_path=fel-sd-boot`. The verified
whole-image write is then the last media write, its full readback follows, and the
kernel, initrd, DTB, and rootfs all come from the exact flashed release image.

This is a deliberate evidence boundary: the transient run bypasses the flashed
SPL and U-Boot, so it does not prove the release cold-boot chain. The existing
platform evidence already distinguishes a FelBoot payload run from a cold
BROM-to-SPL run (`pocketforge-platform/docs/A133-OPEN-7X-OWNED-SPL.md:20-26`).
Any kit whose subject includes the boot chain remains standalone and cold-boots.

The same rule applies between attached kits. Kit 1 uses the direct payload boot
that follows the one verified UMS flash. After every passing kit, kits 2 through
N use `#PocketForge.FelSdBoot`: enter FEL, RAM-boot recovery U-Boot, load the SD
payload, and append `pocketforge.root=volatile`, with **no UMS write**. A normal
cold power cycle would run the flashed release U-Boot without the selector and
produce a persistent root; that ends the session, and the next attach validator
must refuse it rather than dispatch another kit. Every attached boot therefore
has the same `boot_path=fel-sd-boot` and a fresh volatile-root witness.

For planning, a healthy no-write FelSdBoot is expected to cost roughly 60--120
seconds per later kit: its fixed defaults include 2 seconds of strap settling, 6
seconds powered off, and 18 seconds after loading recovery U-Boot, followed by SD
payload loads and Linux login (`test-node-farm/node/bin/fel-sd-boot.sh:40-55`,
`:385-442`). This estimate must be replaced by `.995.43.2`'s PhaseHistory device
measurement. Against the measured 995-second whole-image FelBoot reference, the
expected gross saving is about 875--935 seconds (14:35--15:35) for each later
kit. Timeout ceilings are failure bounds, not expected duration.

The alternatives are weaker:

| Selection | Cost and coverage | Decision |
| --- | --- | --- |
| Transient bootargs on the existing FEL/U-Boot path | One node-flow branch in the later adoption bead; no second image or media/environment write. It runs the release image's exact payload and rootfs, but not its flashed SPL/U-Boot. | **Selected.** |
| Node-supplied U-Boot environment | A persistent environment violates the no-media-mutation rule. Importing an environment into RAM duplicates the existing validated `setenv bootargs` mechanism, adds an environment schema/CRC surface, and still bypasses the flashed U-Boot. The zero-second release autoboot is not a reliable interception point. | Reject; never use `saveenv`. |
| CTS-profile default | Cheap for `a133-open-7x-gpu-cts`, which inherits the release hardware stack but adds a CTS-only payload (`pocketforge-platform/devices/a133-open-7x-gpu-cts/profile.toml:1-6`). It covers only CTS kits and is a different image. Making release default to volatile would change customer behavior and invalidate persistent-root testing. | Retain only as a possible CTS convenience, not session selection. |

Thus a release kit still runs the release image users receive. The capability is
dormant without the argument, and the no-selector route must retain today's
behavior. The runtime mount policy differs only for explicitly attached kits,
and those kits must not claim coverage of that policy difference.

## Initrd contract

The image uses a static BusyBox initrd: it resolves the userdata filesystem by
label and currently mounts it directly at `/newroot` as writable ext4 before the
existing `switch_root` checks (`pocketforge-image/boards/tsp/initrd/init:561-572`,
`:592-639`). The new branch is wholly inside this initrd; it does not depend on
systemd interpreting the kernel command line.

Selector parsing happens immediately after `/proc`, `/sys`, and `/dev` are
mounted and **before any persistent-media mount or write**. This ordering is
required because the current initrd otherwise mounts the boot-resource FAT
writable and truncates `bootlog.txt` (`pocketforge-image/boards/tsp/initrd/init:31-68`).

The parser has three results:

1. No `pocketforge.root` token: run the existing boot-log, optional development
   self-flash, writable ext4 mount, and switch-root path unchanged.
2. Exactly one `pocketforge.root=volatile`: select the volatile branch. Keep
   `PFLOG` empty and console-only, never mount boot-resource writable, and bypass
   the development self-flash gate even if its marker is present.
3. An empty, unknown, or duplicate `pocketforge.root` token: before changing any
   block-device state, emit exactly
   `[pf-initrd] STAGE: malformed pocketforge.root selector; using normal root`
   and take the normal persistent-root path.

For a valid selector, after `LABEL=POCKETFORGE_DATA` resolves to one block device:

1. Apply `blockdev --setro` to that device and require `blockdev --getro` to
   return exactly `1`.
2. Mount it at `/lower` as ext4 with `ro,noload,noatime`, so even journal replay
   cannot modify the flashed lower.
3. Mount a fresh tmpfs at initramfs `/run`. Using the validated UUID from
   `/proc/sys/kernel/random/boot_id`, create
   `/run/pf-kit-session/<boot-id>/{upper,work,lower}`. `upper` and `work` are
   directories on that one tmpfs.
4. Mount overlayfs at `/newroot` with `/lower` as `lowerdir` and those exact
   `upper` and `work` paths. Move the `/run` tmpfs to `/newroot/run`, then move
   the lower mount to `/newroot/run/pf-kit-session/<boot-id>/lower`; the mounts
   and their mount IDs survive `switch_root` and remain observable by the kit.
5. Before `switch_root`, parse `/proc/self/mountinfo` and require all of the
   following: `/newroot` is overlay; the lower witness is ext4 from the resolved
   root device with `ro`; the device still reports read-only; `upper` and `work`
   resolve to the same positive tmpfs mount ID; and their visible paths are
   `/run/pf-kit-session/<boot-id>/upper` and `/work` beneath the same prefix.

Failure to establish or verify a requested volatile topology drops to the
existing initrd failure shell; it must never fall through to a writable root.
Only a syntactically malformed selector is ignored, before mutation, as required
for the normal-root fallback.

The kernel prerequisite is built-in overlayfs (`CONFIG_OVERLAY_FS=y`), which is
absent from the current `a133_defconfig`; ext4 and tmpfs are already built in
(`pocketforge-os/kernel-sunxi-7.x/arch/arm64/configs/a133_defconfig:168-174`).
The initrd can therefore mount the future overlay before userspace without an
alternate image or loadable module.

## Kit witness and evidence limits

After login, the shared attach validator already requires an overlay `/`, a
read-only lower block device and mount, and exact upper/work paths on one tmpfs
mount (`pocketforge-automation/scripts/lib/pf_kit_session.py:190-218`). Its
collector should derive those facts rather than trust labels:

- `findmnt -n -o FSTYPE /` reports `overlay`;
- `/proc/self/mountinfo` identifies the lower witness mount and proves that the
  exact upper/work paths resolve to one tmpfs mount ID;
- `findmnt` resolves the lower source, and `blockdev --getro <source>` returns
  `1`; and
- `/proc/sys/kernel/random/boot_id` matches the path component and has not
  appeared in an earlier session receipt.

Together with the full-image write/readback receipt and live build identity,
this proves that every attached boot starts from the same exact flashed lower
and gets a new, empty, boot-local writable layer. A reboot discards the prior
kit's changes.

It does **not** prove persistence across reboot, ext4 journal/write behavior,
filesystem repair or resize, free-space and wear behavior, updates or rollback,
credential/seed persistence, boot-resource writes, or the cold SPL/U-Boot path.
Upgrade, persistence, storage, destructive-media, and boot-chain kits therefore
remain standalone and use the ordinary persistent release boot.
