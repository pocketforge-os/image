# Steam Link FFmpeg 59 platform runtime, revision v1

This producer builds an isolated AArch64 runtime from the exact Debian source
package `ffmpeg 7:5.1.8-0+deb12u1`. It applies only five historical commits from
the LibreELEC/Kwiboo V4L2 Request series: buffer-pool flush, common request API,
the H.264 bit-size prerequisite, H.264 request acceleration, and NULL-device DRM
creation. MPEG-2, VP8, HEVC, VP9, NV15/NV20, and later format patches are not in
the transform.

The runtime contract is the immutable directory
`/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1`. Consumers must
select its `lib/aarch64-linux-gnu` directory explicitly. Nothing adds that path
to the global dynamic loader, and no system FFmpeg file is replaced.

`source.lock`, the selected original mail patches, the Debian source package
objects and signatures, build configuration, ABI reports, and license files are
installed with the runtime as corresponding-source material.
