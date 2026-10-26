#!/bin/bash
# Runs the product image's gamescope DRM session while every harness binary
# comes from the read-only attachment mounted by pfvd cloud-init.  The DRM
# backend is deliberate: unlike gamescope's headless backend it owns a libinput
# session, so the guarded devices created in this guest kernel actually cross
# gamescope before they reach the clients.
set -euo pipefail

root=/opt/pf-input-harness
test -x /usr/bin/gamescope || { echo "product gamescope absent" >&2; exit 1; }
test -x "$root/bin/fake-input" || { echo "guest fake-input absent" >&2; exit 1; }
selector=/usr/lib/pocketforge/pf-gamescope-kms-select
test -x "$selector" || { echo "product KMS selector absent" >&2; exit 1; }

export PF_HARNESS_ROOT="$root"
export PF_INPUT_SOURCE=guest-kernel
export PF_COMPOSITOR_BACKEND=drm
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/pf-input-harness-xdg}"
install -d -m 0700 "$XDG_RUNTIME_DIR"
kms_env="$XDG_RUNTIME_DIR/gamescope-kms.env"
PF_GAMESCOPE_KMS_NODE=$(
    "$root/session/select-product-kms.sh" "$selector" "$kms_env" /dev/dri
)
export PF_GAMESCOPE_KMS_NODE
export PF_MANGO_FIFO="${PF_MANGO_FIFO:-/run/pf-input-harness-mango.fifo}"
test -p "$PF_MANGO_FIFO" || mkfifo "$PF_MANGO_FIFO"
export PATH="$root/bin:$root/usr/bin:$PATH"
export XKB_DEFAULT_RULES=evdev
export LIBINPUT_DEFAULT_SEAT=seat0

OUT="${OUT:-/run/pf-input-harness-output}"
mkdir -p "$OUT/transcripts" "$OUT/screenshots"
exec /usr/bin/gamescope --backend drm --expose-wayland \
    --prefer-drm "$PF_GAMESCOPE_KMS_NODE" \
    -W "${PF_OUTPUT_WIDTH:-1280}" -H "${PF_OUTPUT_HEIGHT:-720}" \
    --mangoapp -- env \
    LD_LIBRARY_PATH="$root/lib:$root/usr/local/lib:$root/usr/lib/aarch64-linux-gnu" \
    "$root/usr/bin/python3" -B "$root/session/driver.py" "$OUT"
