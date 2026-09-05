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
`ebdf7844efbb997a1e858600ae76c90985ea865d`. The image applies a committed,
reproducible patch that adds a decode-only headless device constructor, then builds
`cedar-headless-test`: FFmpeg libraries parse the elementary stream while the
sunxi decoder programs the VE through libcedrus. The decoder accepts VDPAU hardware
surfaces only and aborts instead of returning a software frame. The runner passes
the discovered absolute `libvdpau_sunxi.so.1` path to the probe, which prints that
path before decoding; it does not depend on the VDPAU module directory being in the
default dynamic-loader search path.
Dedicated Dockerfile stages fetch those exact immutable refs, cross-build AArch64
libraries with the pinned toolchain, verify their ELF machine type, and copy only the
libraries and provenance stamp into the dev rootfs. A build-graph selector uses the
existing SoC and variant profile values, reaching the networked stages only for
`sun50iw10p1` + `dev`; A523 and A133 release builds select an empty stage, so they
neither fetch nor build Cedar. Release images do not install the payload.

This dev-image spike adds Debian-snapshot-pinned FFmpeg libraries, the generic VDPAU
loader, and `strace`, plus a deterministic 30-second 1280x720 H.264 Annex-B clip and
`pf-cedar-spike`. The remaining result is deliberately pending the coordinator's
batched DUT run. It reports PASS only when all of these hold:

1. The headless decoder returns 900 VDPAU hardware frames (no software output is accepted).
2. `/dev/cedar_dev` is successfully opened by a traced task.
3. An ioctl is issued on the descriptor between its Cedar open and close. The verifier
   keys the live descriptor by FD across the one traced decoder process group because
   its worker threads share one FD table; this permits a main-thread open and a
   worker-thread ioctl. It also requires `strace -yy` to resolve the ioctl descriptor
   to `/dev/cedar_dev`, while the close tracking prevents post-close FD reuse from
   becoming false hardware evidence.
4. The direct decoder exits successfully and reports exactly 900 decoded frames (30 seconds at
   30 fps).

## Build and DUT handoff

Build the normal A133 dev OS image on modelmaker. The build creates the clip inside
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
- VDPAU (ffmpeg/mpv) requires X — not viable headless on the current image;
  direct-VE (libcedrus) is the headless path; the TV pipeline design must account
  for this. `libvdpau-sunxi` remains installed because it contains the proven H.264
  VE implementation, but the spike bypasses its X11 presentation constructor.
- Decoder log text or successful playback alone cannot distinguish hardware from a
  software fallback; the runner traces the actual character-device FD and its ioctl.
- Moving branch tips and non-owned source remotes are not acceptable provenance; both
  inputs are owned forks selected by literal full commit IDs.
