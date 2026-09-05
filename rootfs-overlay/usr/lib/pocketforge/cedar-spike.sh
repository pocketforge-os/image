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
command -v cedar-headless-test >/dev/null 2>&1 || fail 0 headless_decoder_missing
command -v strace >/dev/null 2>&1 || fail 0 strace_missing

# libvdpau's loader accepts either multiarch or traditional VDPAU module paths.
DRIVER=$(find /usr/lib /usr/local/lib -type f -name 'libvdpau_sunxi.so*' 2>/dev/null | head -n 1 || true)
[ -n "$DRIVER" ] || fail 0 libvdpau_sunxi_not_shipped

# The direct decoder creates a libcedrus-backed device without X11 presentation.
# FFmpeg libraries parse H.264 headers, but the program accepts VDPAU hardware
# surfaces only; it has no software-output path.
set +e
# -yy resolves the descriptor target at each ioctl.  That makes the evidence
# lifetime- and task-specific even when another thread closes/reuses the same
# numeric descriptor; a bare same-number ioctl can never satisfy the check.
strace -f -yy -qq -e trace=open,openat,close,dup2,dup3,ioctl -o "$TRACE" \
    cedar-headless-test "$CLIP" >"$PROGRESS" 2>&1
rc=$?
set -e

frames=$(sed -n 's/^frames=//p' "$PROGRESS" 2>/dev/null | tail -n 1)
frames=${frames:-0}
grep -Eq 'open(at)?\(.*"/dev/cedar_dev".*\)[[:space:]]*=[[:space:]]*[0-9]+</dev/cedar_dev[^[:space:]]*>' "$TRACE" \
    || fail "$frames" cedar_device_not_opened
# cedar-headless-test is the only decoder in this trace and does not fork worker
# processes: its worker threads share one descriptor table.  Keying by fd across
# that single process group therefore accepts a main-thread open followed by a
# worker-thread ioctl.  The open/close lifetime and -yy target still reject reuse.
awk '
{
    if ($0 ~ /open(at)?\(.*"\/dev\/cedar_dev".*\)[[:space:]]*=[[:space:]]*[0-9]+<\/dev\/cedar_dev/) {
        result = $0; sub(/^.*=[[:space:]]*/, "", result); sub(/<.*$/, "", result)
        live[result] = 1
    } else if (match($0, /close\([0-9]+<[^>]*>/)) {
        fd = substr($0, RSTART, RLENGTH); sub(/^close\(/, "", fd); sub(/<.*$/, "", fd)
        delete live[fd]
    } else if (match($0, /ioctl\([0-9]+<\/dev\/cedar_dev[^>]*>/)) {
        fd = substr($0, RSTART, RLENGTH); sub(/^ioctl\(/, "", fd); sub(/<.*$/, "", fd)
        if (live[fd]) found = 1
    }
}
END { exit(found ? 0 : 1) }
' "$TRACE" || fail "$frames" cedar_ioctl_not_observed
[ "$rc" -eq 0 ] || fail "$frames" decoder_exit_${rc}
[ "$frames" -eq 900 ] 2>/dev/null || fail "$frames" incomplete_decode

printf 'PASS cedar-h264 hw_used=yes frames=%s device=/dev/cedar_dev ioctl=yes\n' "$frames"
