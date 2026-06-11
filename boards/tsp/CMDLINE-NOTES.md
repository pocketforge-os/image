# Kernel Command Line — TrimUI Smart Pro (tsp)

Canonical cmdline lives in `cmdline.txt` (this directory). Consumed by `abootimg --create` via `$(cat image/boards/tsp/cmdline.txt)` — never inlined as a shell string.

The file uses `abootimg`'s `-c` config format: `cmdline=<kernel args>` (the `cmdline=` prefix is required by `abootimg`; it is not passed to the kernel).

## Arguments

### `console=ttyS0,115200`

UART0 serial console at 115200 baud, 8N1. Required for:
- Serial debug output during boot (the only console available before userspace).
- The initrd's busybox-shell fallback — if `switch_root` fails, the shell is accessible via serial.
- M1.B first-boot bring-up: the busybox shell over serial is the only UI.

UART0 is the Allwinner `sunxi-uart` at MMIO base `0x05000000` (see `earlyprintk` below). The USB-UART adapter connects to the unpopulated pads on the TSP PCB (see `tsp-iuz.1.12` for the rig).

### `earlyprintk=sunxi-uart,0x05000000`

Pre-console kernel log output to UART0 at physical address `0x05000000`. Prints kernel messages before the normal `console=` driver is registered (covers the window from kernel entry to `console_init()`). Critical for diagnosing boot failures that happen before the serial tty driver loads.

Address `0x05000000` is the Allwinner A133 UART0 MMIO base (confirmed in `hardware-firmware-probes.md` §1 / §4; the stock cmdline uses the same address).

### `root=PARTLABEL=userdata`

Find the root filesystem by GPT partition name, not by a hardcoded `/dev/mmcblk1pN` device path. The vendor U-Boot and kernel resolve partitions by GPT name (confirmed by device probe — `hardware-firmware-probes.md` §6; the eMMC `/dev/by-name` ordering is non-sequential, proving name-based resolution).

The initrd's `/init` script uses `findfs PARTLABEL=userdata` (or `blkid -t PARTLABEL=userdata -o device`) to locate the rootfs partition, then `switch_root`s into it. This makes the cmdline and initrd independent of the SD card's partition index numbering — our SD GPT can have `userdata` at any `mmcblk1pN` as long as the GPT name is correct.

### `rootwait`

Wait indefinitely for the root device to appear. Required because the SD card driver (`sunxi-mmc`) may take a variable number of milliseconds to probe the card and create the block device nodes. Without `rootwait`, the kernel panics with "VFS: Unable to mount root fs" if the SD device isn't ready yet.

### `init=/sbin/init`

PID 1 on the rootfs. For PocketForge this is systemd (Debian bookworm's default `/sbin/init` is a symlink to `systemd`). In M1.B (minimal image), the initrd's `/init` is the actual PID 1 and this argument is only relevant after `switch_root` into the real rootfs — which doesn't happen in M1.B-mode (the initrd drops to a busybox shell instead).

### `loglevel=8`

Set the kernel console log level to 8 (KERN_DEBUG — all messages). This ensures every kernel log message is printed to the serial console during development. Useful for diagnosing driver load failures, module init errors, and early boot issues.

M1.E hardening may dial this down to `4` (KERN_WARNING) or `5` (KERN_NOTICE) for the release variant. Keep `8` for the dev variant.

### `cma=64M`

Reserve a 64 MiB Contiguous Memory Allocator pool. The vendor kernel uses this for DMA-coherent buffer allocations by the Allwinner Display Engine 2.0 (`dc_sunxi.ko`), the PowerVR GPU (`pvrsrvkm.ko`), and the Cedar VPU (`/dev/cedar_dev`). The vendor stock cmdline uses the same value. Reducing this below 64 MiB risks display engine panics or GPU allocation failures.

### `gpt=1`

Tell the kernel's partition parser to use GPT (GUID Partition Table) for disk layout, not the legacy MBR. PocketForge ships a GPT-formatted SD card; the vendor kernel's Allwinner `sunxi` partition driver keys on this flag.

### `androidboot.hardware=sun50iw10p1`

Android-style SoC/hardware identifier. The vendor U-Boot's `bootm` flow also injects this automatically, but including it explicitly is harmless and makes the cmdline self-documenting. The value `sun50iw10p1` identifies the Allwinner A133P SoC variant. Some vendor kernel drivers and init scripts may key on this string.

## Arguments NOT included (and why)

### `partitions=bootloader@mmcblk1p1:env@mmcblk1p2:...`

**Dropped.** The vendor kernel's `sunxi` partition driver and U-Boot's `update_bootcmd()` routine auto-generate the `partitions=` mapping from the GPT table at boot. Including a hardcoded mapping in our cmdline would be fragile (it must match the actual SD GPT layout exactly) and redundant. PocketForge resolves the rootfs by `PARTLABEL=userdata` (see above), not by partition index. The initrd uses `findfs`/`blkid`, which work against the GPT directly.

If U-Boot's auto-injection proves insufficient on our SD layout (verified at first-SD-boot in `tsp-iuz.1.7`), add the explicit mapping back to this file — but the expectation based on KNULLI's working recipe and the vendor boot log analysis is that it is not needed.

### `disp_reserve=3686400,0x7b823480`

**Not included.** U-Boot's display init (`drv_disp_init` / `boot_gui_init`) allocates the framebuffer, then injects `disp_reserve=<size>,<physaddr>` into the kernel cmdline during `bootm`. The address is computed at boot time based on DRAM layout — hardcoding it would be incorrect if the DRAM allocator changes. The size (3,686,400 = 720 x 1280 x 4 bytes, one ARGB8888 frame) is derived from the panel resolution in the DTB.

Verified: the stock boot log shows `disp_reserve` appearing in `/proc/cmdline` even when a manual `setenv bootargs` omitted it — proving U-Boot injection (see bead notes).

### `lcd=er68576`

**Not included.** U-Boot's LCD panel driver reads `lcd_driver_name` from the DTB (our `boot_package.fex` carries the DTB), initializes the OTM1289A panel, and injects `lcd=er68576` into the kernel cmdline during `bootm`. As long as the PocketForge DTB preserves the `lcd0` node with the correct `lcd_driver_name = "otm1289a"` property (verified in `tsp-iuz.1.5`, the DTB-compile bead), this is auto-injected.

### `rdinit=/rdinit`

**Dropped.** Vendor uses this to point at a custom initrd init. PocketForge's initrd uses the default `/init` path (the kernel tries `/init` in the initramfs automatically).

### `initcall_debug=0`, `rotpk_status=0`, `pstore_blk.*`, `pstore.update_ms=*`

**Dropped.** Android/vendor diagnostic flags not needed by the PocketForge Debian rootfs.

### `androidboot.mode=normal`, `androidboot.serialno=*`, `androidboot.boot_type=*`, `boot_type=*`, `androidboot.secure_os_exist=0`, `androidboot.dramsize=*`

**Dropped.** Android init property conventions. U-Boot injects most of these automatically during `bootm` anyway; they are not needed in our boot.img cmdline and are irrelevant to the Debian userspace.

### `uboot_message=*`

**Dropped.** U-Boot version stamp, auto-injected by U-Boot. Informational only.

## Format notes

- `cmdline.txt` uses `abootimg`'s `-c` config format: `cmdline=<args>`. The `cmdline=` prefix is consumed by `abootimg` and does NOT appear in the kernel's `/proc/cmdline`.
- The file has no trailing newline (verified: `wc -l` reports 0 lines; `wc -c` reports the expected byte count).
- The build step reads it via shell substitution: `abootimg --create boot.img -k Image -r initrd.img -c "$(cat image/boards/tsp/cmdline.txt)" -p 0x800 -b 0x40000000`.
- At runtime, `/proc/cmdline` will contain our arguments plus any U-Boot-injected arguments (e.g., `disp_reserve`, `lcd`, `androidboot.*`). The combined set is what the kernel and initrd see.

## References

- `pocketforge-plan.md` §11.2 — "We own the kernel cmdline"
- `sd-boot-research.md` §7.4 — example cmdline (source for this canonical version, with `partitions=` dropped)
- `build-integration-reference.md` §10.5 — cmdline -> mkbootimg wiring
- `hardware-firmware-probes.md` §1 (UART0 address), §4 (stock cmdline), §6 (PARTLABEL discipline)
- Bead `tsp-iuz.1.6` — initrd; references the cmdline for partition resolution
- Bead `tsp-iuz.1.7` — first SD image; mkbootimg invocation reads from this file
