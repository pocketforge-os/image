# A133 Cedar H.264 hardware-decode spike

Bead: `tsp-h5ed.17`

## Build candidate: kernel and pinned userspace are integrated; DUT result pending

The exact `platform.lock` kernel pin
`a7cfec247898bb2c22e51bb705a7f18fd5910285` passes the kernel preflight. Its
`drivers/media/Makefile` links `cedar-ve/` unconditionally, `pocketforge_tsp.dts`
contains the enabled `allwinner,sunxi-cedar-ve` node, and the driver's probe
registers the character device and creates `cedar_dev`. No kernel change is needed.

The dev image now source-builds the clean-room legacy stack from the owned forks:
[`pocketforge-os/libcedrus`](https://github.com/pocketforge-os/libcedrus) commit
`9b243c430a4d445b3853262552ad563fa9ea325d`, beneath
[`pocketforge-os/libvdpau-sunxi`](https://github.com/pocketforge-os/libvdpau-sunxi) commit
`ebdf7844efbb997a1e858600ae76c90985ea865d`, with FFmpeg's VDPAU hwaccel above it.
Dedicated Dockerfile stages fetch those exact immutable refs, cross-build AArch64
libraries with the pinned toolchain, verify their ELF machine type, and copy only the
libraries and provenance stamp into the dev rootfs. Release images do not install them.

This dev-image spike adds Debian-snapshot-pinned FFmpeg, the generic VDPAU loader, and
`strace`, plus a deterministic 30-second 1280x720 H.264 Annex-B clip and
`pf-cedar-spike`. The remaining result is deliberately pending the coordinator's
batched DUT run. It reports PASS only when all of these hold:

1. FFmpeg is forced to VDPAU output (no software fallback is selected).
2. `/dev/cedar_dev` is successfully opened by a traced task.
3. An ioctl is issued by the same process on the descriptor between its Cedar open and
   close. The verifier tracks `(pid, fd)` lifetimes and also requires `strace -yy` to
   resolve that ioctl descriptor to `/dev/cedar_dev`, preventing cross-task collisions
   and post-close FD reuse from becoming false hardware evidence.
4. FFmpeg exits successfully and reports exactly 900 decoded frames (30 seconds at
   30 fps).

## Build and DUT handoff

Build the normal A133 dev OS image on modelmaker.  The build creates the clip inside
the target rootfs with the snapshot-pinned target FFmpeg and installs the runner.  The
coordinator records the resulting OS artifact SHA-256 and batches this exact command:

```sh
sudo /usr/lib/pocketforge/cedar-spike.sh
```

The single PASS/FAIL line is sufficient serial/stdout evidence.  Retain the full line;
do not translate the expected blocker into a hardware failure.  After a future backend
integration, a PASS proves device open + ioctl activity and frame completion, while any
FAIL names the first observed blocker.

## Dead ends rejected

- `v4l2m2m`/mainline Cedrus is not the A133 BSP interface; the current kernel exposes
  the legacy character device instead.
- Stock Debian FFmpeg and `libvdpau1` provide the client and loader, not the sunxi
  VDPAU driver.  Their presence cannot constitute Cedar support.
- Decoder log text or successful playback alone cannot distinguish hardware from a
  software fallback; the runner traces the actual character-device FD and its ioctl.
- Moving branch tips and non-owned source remotes are not acceptable provenance; both
  inputs are owned forks selected by literal full commit IDs.
