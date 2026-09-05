#!/bin/sh
# Hardware-only Cedar H.264 spike.  Software fallback is deliberately forbidden.
set -eu

CLIP=/usr/share/pocketforge/cedar-spike-720p.h264
TRACE="${TMPDIR:-/tmp}/pf-cedar-spike.$$.trace"
PROGRESS="${TMPDIR:-/tmp}/pf-cedar-spike.$$.progress"
trap 'rm -f "$TRACE" "$PROGRESS"' EXIT HUP INT TERM

fail() {
    printf 'FAIL cedar-h264 hw_used=no frames=%s blocker=%s\n' "${1:-0}" "$2"
    exit 1
}

[ -c /dev/cedar_dev ] || fail 0 cedar_device_missing
[ -r "$CLIP" ] || fail 0 test_clip_missing
command -v ffmpeg >/dev/null 2>&1 || fail 0 ffmpeg_missing
command -v strace >/dev/null 2>&1 || fail 0 strace_missing

# libvdpau's loader accepts either multiarch or traditional VDPAU module paths.
DRIVER=$(find /usr/lib /usr/local/lib -type f -name 'libvdpau_sunxi.so*' 2>/dev/null | head -n 1 || true)
[ -n "$DRIVER" ] || fail 0 libvdpau_sunxi_not_shipped

# Capture opens and ioctls.  A successful ffmpeg exit alone is not evidence: ffmpeg
# can fall back to its software H.264 decoder unless every hwaccel is constrained.
set +e
VDPAU_DRIVER=sunxi strace -f -qq -e trace=open,openat,ioctl -o "$TRACE" \
    ffmpeg -nostdin -hide_banner -loglevel error \
    -hwaccel vdpau -hwaccel_output_format vdpau \
    -i "$CLIP" -an -sn -dn -f null - \
    -progress "$PROGRESS"
rc=$?
set -e

frames=$(sed -n 's/^frame=//p' "$PROGRESS" 2>/dev/null | tail -n 1)
frames=${frames:-0}
grep -Eq 'open(at)?\([^\n]*"/dev/cedar_dev"[^\n]*= [0-9]+' "$TRACE" \
    || fail "$frames" cedar_device_not_opened

cedar_fd=$(sed -nE 's/.*open(at)?\([^\n]*"\/dev\/cedar_dev"[^\n]*= ([0-9]+).*/\2/p' "$TRACE" | head -n 1)
[ -n "$cedar_fd" ] || fail "$frames" cedar_fd_unresolved
grep -Eq "ioctl\(${cedar_fd}," "$TRACE" || fail "$frames" cedar_ioctl_not_observed
[ "$rc" -eq 0 ] || fail "$frames" decoder_exit_${rc}
[ "$frames" -eq 900 ] 2>/dev/null || fail "$frames" incomplete_decode

printf 'PASS cedar-h264 hw_used=yes frames=%s device=/dev/cedar_dev ioctl=yes\n' "$frames"
