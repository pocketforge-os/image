# A133 Cedar H.264 hardware-decode spike

Bead: `tsp-h5ed.17`

## Result before DUT execution: NO (userspace backend is not shipped)

The current A133 image's owned 4.9 kernel describes the Cedar VE and creates
`/dev/cedar_dev`, but the image build has no userspace implementation of that ioctl ABI.
The clean-room legacy stack is
[`libcedrus`](https://github.com/linux-sunxi/libcedrus) commit
`9b243c430a4d445b3853262552ad563fa9ea325d`, beneath
[`libvdpau-sunxi`](https://github.com/linux-sunxi/libvdpau-sunxi) commit
`ebdf7844efbb997a1e858600ae76c90985ea865d`, with FFmpeg's VDPAU hwaccel above it.
Neither source is a `platform.lock` input today.  Fetching either at image-build time
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
2. `/dev/cedar_dev` is successfully opened during that FFmpeg process tree.
3. At least one ioctl is issued on the returned Cedar file descriptor.
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
