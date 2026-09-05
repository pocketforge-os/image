# A133 Cedar H.264 hardware-decode spike

Bead: `tsp-h5ed.17`

## Result after kernel preflight: NO (userspace backend cannot yet be pinned)

The exact `platform.lock` kernel pin
`a7cfec247898bb2c22e51bb705a7f18fd5910285` passes the kernel preflight. Its
`drivers/media/Makefile` links `cedar-ve/` unconditionally, `pocketforge_tsp.dts`
contains the enabled `allwinner,sunxi-cedar-ve` node, and the driver's probe
registers the character device and creates `cedar_dev`. No kernel change is needed.

The image build still has no userspace implementation of that ioctl ABI.
The clean-room legacy stack is
[`libcedrus`](https://github.com/linux-sunxi/libcedrus) commit
`9b243c430a4d445b3853262552ad563fa9ea325d`, beneath
[`libvdpau-sunxi`](https://github.com/linux-sunxi/libvdpau-sunxi) commit
`ebdf7844efbb997a1e858600ae76c90985ea865d`, with FFmpeg's VDPAU hwaccel above it.
Neither source is a `platform.lock` input today. The authorized attempts to create
`pocketforge-os/libcedrus` and `pocketforge-os/libvdpau-sunxi` forks were rejected by
GitHub with `HTTP 403: Resource not accessible by integration`; consequently there
is no owned source remote that `platform.lock` can honestly pin yet. Fetching either at image-build time
would violate PocketForge's pinned-source and hermetic-build contract, so this change
does not disguise a network fetch as a decoder integration.

This dev-image spike adds Debian-snapshot-pinned FFmpeg, the generic VDPAU loader, and
`strace`, plus a deterministic 30-second 1280x720 H.264 Annex-B clip and
`pf-cedar-spike`.  On the current graph the command intentionally prints:

```
FAIL cedar-h264 hw_used=no frames=0 blocker=libvdpau_sunxi_not_shipped
```

That is the exact integration blocker and the spike's current NO answer.  Once the two
clean-room repositories are added as exact `platform.lock` inputs and cross-built, the
same command proceeds to decode.  It reports PASS only when all of these hold:

1. FFmpeg is forced to VDPAU output (no software fallback is selected).
2. `/dev/cedar_dev` is successfully opened by a traced task.
3. An ioctl is issued while its descriptor resolves to `/dev/cedar_dev`. `strace -yy`
   annotates the descriptor target at the time of every syscall, so an equal FD number
   in another task—or after close and reuse—cannot be mistaken for Cedar activity.
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
- Unpinned GitHub downloads during the image build are not acceptable provenance.
