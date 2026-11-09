#!/usr/bin/env bash
# tsp-ca44436b9799851cd483: the gamescope focus client's session contract, seen from the broker.
#
# fake-gamescope (--focus-client) connects to a broker compositor.sock and sends the runtime
# producer's golden frames byte for byte (crates/pf-input-ipc/tests/golden/register.json,
# state_snapshot.json, focus.json with surface kind "app"). The broker side is runtime's real
# compositor endpoint code at the pinned runtime head: CompositorAuthority + serve_compositor_peer
# from pf-input-broker's session_ipc, with the real RumbleControl writing its `rumble: ...` lines
# to stderr exactly as the daemon does into the journal. Only the hardware is left out: the
# production binary also grabs an evdev source and creates uinput devices, so the endpoint is
# driven by a test-only example (session-authority-systemd/compositor-focus-broker.rs) built
# from the same crate.
#
# The broker build follows tests/test-session-authority-systemd.sh: a git clone of runtime at the
# exact pinned SHA, built with its committed vendor tree (--locked --offline) inside the
# digest-pinned rust:1.85-bookworm image, with no network in the container.
#
# Pass: the broker logs `rumble: compositor_register peer=... epoch=1`, then
# `rumble: focus surface=app action=gained`, then `focus surface=compositor_gone action=lost` on
# EOF. Negative control: the same focus frame without a register first is refused and logs no
# compositor_register and no surface=app action=gained.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="${root}/tests/session-authority-systemd"
runtime_sha=7b97af8ffe1acb2665b946f97f4473728ba2ccb1
runtime_repository="${PF_RUNTIME_REPOSITORY:-https://github.com/pocketforge-os/runtime.git}"
rust_image='docker.io/library/rust:1.85-bookworm@sha256:e51d0265072d2d9d5d320f6a44dde6b9ef13653b035098febd68cce8fa7c0bc4'
example=pf_compositor_focus_broker
cache="${PF_FAKE_GAMESCOPE_FOCUS_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/pocketforge/fake-gamescope-focus}"

fail() {
    echo "fake-gamescope focus: FAIL: $*" >&2
    exit 1
}

for tool in docker git python3; do
    command -v "${tool}" >/dev/null 2>&1 || fail "MISSING_TOOL: ${tool}"
done
[ -f "${fixtures}/fake-gamescope" ] || fail "fake-gamescope fixture missing"
[ -f "${fixtures}/compositor-focus-broker.rs" ] || fail "compositor-focus-broker.rs fixture missing"

# The fixture's existing lifecycle self-test still holds with the new mode added.
python3 -I "${fixtures}/fake-gamescope" --self-test >/dev/null || fail "fake-gamescope --self-test"

# Runtime source at the exact pin (cached; reused only when HEAD matches and the tree is clean).
runtime="${cache}/runtime-${runtime_sha:0:12}"
mkdir -p "${cache}"
if [ -d "${runtime}/.git" ] \
    && [ "$(git -C "${runtime}" rev-parse HEAD 2>/dev/null)" = "${runtime_sha}" ] \
    && [ -z "$(git -C "${runtime}" status --porcelain --untracked-files=no)" ]; then
    :
else
    rm -rf "${runtime}"
    git clone --quiet --filter=blob:none --no-checkout "${runtime_repository}" "${runtime}"
    git -C "${runtime}" fetch --quiet origin "${runtime_sha}"
    git -C "${runtime}" checkout --quiet --detach "${runtime_sha}"
fi
[ "$(git -C "${runtime}" rev-parse HEAD)" = "${runtime_sha}" ] || fail 'RUNTIME_SHA_MISMATCH'
golden="${runtime}/crates/pf-input-ipc/tests/golden"
for name in register state_snapshot focus; do
    [ -f "${golden}/${name}.json" ] || fail "runtime golden fixture missing: ${name}.json"
done
install -D -m 0644 "${fixtures}/compositor-focus-broker.rs" \
    "${runtime}/crates/pf-input-broker/examples/${example}.rs"

target="${cache}/target-${runtime_sha:0:12}"
scope="$(mktemp -d "${TMPDIR:-/tmp}/pf-fake-gamescope-focus.XXXXXX")"
trap 'rm -rf "${scope}"' EXIT
mkdir -p "${target}" "${scope}/run"
install -m 0755 "${fixtures}/fake-gamescope" "${scope}/fake-gamescope"

# shellcheck disable=SC2016  # expanded inside the container
inner='
set -euo pipefail
bash scripts/check-vendor.sh
cargo build --quiet --locked --offline -p pf-input-broker --example "$EXAMPLE"
broker="$CARGO_TARGET_DIR/debug/examples/$EXAMPLE"
golden=/src/runtime/crates/pf-input-ipc/tests/golden

run_case() {
    local name="$1"; shift
    local sock="/work/run/${name}.sock"
    "$broker" "$sock" >"/work/run/${name}.broker.stdout" 2>"/work/run/${name}.broker.stderr" &
    local pid=$!
    for _ in $(seq 100); do [ -S "$sock" ] && break; sleep 0.1; done
    [ -S "$sock" ] || { echo "broker did not bind $sock" >&2; cat "/work/run/${name}.broker.stderr" >&2; exit 1; }
    python3 -I /work/fake-gamescope --focus-client "$sock" "$golden" "$@" \
        >"/work/run/${name}.client.stdout"
    local rc=0
    timeout 10 tail --pid="$pid" -f /dev/null || { kill "$pid"; echo "broker did not exit after EOF" >&2; exit 1; }
    wait "$pid" || rc=$?
    echo "$rc" >"/work/run/${name}.broker.rc"
}

run_case focus
run_case unregistered --omit-register
'

docker run --rm --network none \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e CARGO_HOME=/work/target/cargo-home \
    -e CARGO_TARGET_DIR=/work/target \
    -e EXAMPLE="${example}" \
    -v "${runtime}:/src/runtime" \
    -v "${target}:/work/target" \
    -v "${scope}/run:/work/run" \
    -v "${scope}/fake-gamescope:/work/fake-gamescope:ro" \
    -w /src/runtime \
    "${rust_image}" bash -c "${inner}" \
    || fail "broker build or focus run failed in ${rust_image%%@*}"

run="${scope}/run"
echo '--- broker stderr (focus) ---'
cat "${run}/focus.broker.stderr"
echo '--- broker stderr (unregistered control) ---'
cat "${run}/unregistered.broker.stderr"

python3 -I - "${run}" <<'PY' || fail "broker log assertions"
import re
import sys
from pathlib import Path

run = Path(sys.argv[1])
focus = (run / "focus.broker.stderr").read_text(encoding="utf-8").splitlines()
rumble = [line for line in focus if line.startswith("rumble: ")]


def index(predicate, what):
    for i, line in enumerate(rumble):
        if predicate(line):
            return i
    raise SystemExit(f"missing broker line: {what}; rumble lines: {rumble}")


register = index(
    lambda l: re.fullmatch(r"rumble: compositor_register peer=uid\d+/pid\d+ epoch=1", l) is not None,
    "rumble: compositor_register peer=uid<N>/pid<N> epoch=1",
)
gained = index(lambda l: l == "rumble: focus surface=app action=gained", "rumble: focus surface=app action=gained")
gone = index(
    lambda l: l == "rumble: focus surface=compositor_gone action=lost",
    "rumble: focus surface=compositor_gone action=lost",
)
if not register < gained < gone:
    raise SystemExit(f"broker lines out of order: {rumble}")
if (run / "focus.broker.rc").read_text().strip() != "0":
    raise SystemExit("broker endpoint returned an error for the golden register/snapshot/focus stream")
client = (run / "focus.client.stdout").read_text(encoding="utf-8")
if "fake-gamescope focus-client: PASS register=golden snapshot=golden focus=app epoch=1" not in client:
    raise SystemExit(f"fake-gamescope did not complete the golden stream: {client!r}")

control = (run / "unregistered.broker.stderr").read_text(encoding="utf-8")
if "compositor_register" in control or "surface=app action=gained" in control:
    raise SystemExit(f"negative control: unregistered focus frame reached the broker: {control!r}")
if (run / "unregistered.broker.rc").read_text().strip() == "0":
    raise SystemExit("negative control: broker accepted a focus frame before register")
client = (run / "unregistered.client.stdout").read_text(encoding="utf-8")
if "fake-gamescope focus-client: REFUSED without register" not in client:
    raise SystemExit(f"negative control: client did not observe the refusal: {client!r}")
PY

echo "fake-gamescope focus: PASS runtime_sha=${runtime_sha} broker=session_ipc+ff golden=register,state_snapshot,focus lines=compositor_register,focus_surface=app_action=gained,compositor_gone_lost negative_control=unregistered_refused"
