#!/bin/bash
# =============================================================================
# test-kbd-layout-gamescope.sh: keyboardLayout end-to-end under gamescope
# =============================================================================
# Acceptance criterion (bd tsp-ihne1.6): setting keyboardLayout=de makes a
# fake USB keyboard type German characters into a GTK test app under
# headless gamescope; resetting to us restores the US characters.
#
# Wiring under test, all production code paths:
#   prefs store / seed document  (as pf-prefsd / cloud-init-tsp write them)
#     -> rootfs-overlay/usr/lib/pocketforge/kbd-layout-env   (generator)
#     -> XKB_DEFAULT_* environment                           (env file)
#     -> gamescope headless XKB keymap
#     -> fake uinput keyboard via the shared input harness EIS bridge
#     -> committed text in the x11-gtk transcript client.
#
# Requires docker, /dev/uinput and tests/input-harness (tsp-ihne1.2).
# Fails closed (MISSING_PREREQUISITE) when a prerequisite is absent.
#
#   tests/test-kbd-layout-gamescope.sh [--no-build]
#
# Safety: docker run --rm only, no anonymous volumes, never privileged, no
# init/systemd PID 1, worktree mounted read-only, output chowned back to the
# host user. Images labelled pf.bead=tsp-ihne1.6.
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="${SRC_DIR}/tests/input-harness"
SELF_DIR="${SRC_DIR}/tests/kbd-layout-harness"

NAME="kbd-layout-gamescope"
fail() {
    echo "FAIL: ${NAME} reason=$1 hint=$2" >&2
    exit 1
}
missing() {
    echo "MISSING_PREREQUISITE: ${NAME} reason=$1 hint=$2" >&2
    exit 1
}

[ -d "${HARNESS_DIR}" ] || missing "harness_absent" \
    "tests/input-harness is not in this checkout (tsp-ihne1.2)"
[ -f "${SELF_DIR}/entry.sh" ] && [ -f "${SELF_DIR}/driver.py" ] ||
    fail "assets_missing" "tests/kbd-layout-harness/{entry.sh,driver.py}"
command -v docker >/dev/null 2>&1 || missing "no_docker" \
    "docker not found on PATH"
docker info >/dev/null 2>&1 || missing "docker_unusable" \
    "cannot reach the docker daemon"
[ -e /dev/uinput ] || missing "no_uinput" \
    "/dev/uinput missing or not permitted on this host"

BUILD=1
if [ "${1:-}" = "--no-build" ]; then
    BUILD=0
fi

# shellcheck source=tests/input-harness/pins.env
. "${HARNESS_DIR}/pins.env"

if [ "${BUILD}" = 1 ] && ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
    echo "==> building ${IMAGE_TAG} (gamescope ${GAMESCOPE_COMMIT:0:12})"
    docker build \
        -f tests/input-harness/Containerfile \
        --build-arg GAMESCOPE_URL="${GAMESCOPE_URL}" \
        --build-arg GAMESCOPE_COMMIT="${GAMESCOPE_COMMIT}" \
        --build-arg BASE_IMAGE="${BASE_IMAGE}" \
        --label pf.bead=tsp-ihne1.6 \
        -t "${IMAGE_TAG}" "${SRC_DIR}"
fi
docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1 || missing "no_image" \
    "harness image ${IMAGE_TAG} absent and build was not requested"

OUT="$(mktemp -d "${RUNNER_TEMP:-/tmp}/kbd-layout-gamescope.XXXXXX")"
cleanup() {
    find "${OUT}" -mindepth 1 -delete
    rmdir "${OUT}"
}
trap cleanup EXIT

# run_case <label> <where: store|seed> <token> <expected-commit> <source>
run_case() {
    local label="$1" where="$2" token="$3" expect="$4" source_kind="$5"
    local d="${OUT}/${label}"
    mkdir -p "${d}/transcripts"
    if [ "${where}" = "seed" ]; then
        printf '{"keyboardLayout": "%s"}\n' "${token}" > "${d}/seed.json"
    else
        printf '{"schemaVersion": 2, "keyboardLayout": "%s"}\n' \
            "${token}" > "${d}/prefs.json"
    fi

    echo "==> case ${label}: ${where} keyboardLayout=${token} expect=${expect}"
    (
        cd "${SRC_DIR}"
        docker run --rm \
            --label pf.bead=tsp-ihne1.6 \
            --network none \
            --device /dev/uinput \
            -v /dev/input:/dev/input \
            -v "${d}:/out" \
            -v "${SRC_DIR}:/repo:ro" \
            -e HOST_UID="$(id -u)" \
            -e HOST_GID="$(id -g)" \
            -e OUT=/out \
            -e PF_KBD_PREFS_FILE=/out/prefs.json \
            -e PF_KBD_SEED_FILE=/out/seed.json \
            -e PF_KBD_ENV_FILE=/out/kbd.env \
            -e PF_KBD_EXPECT="${expect}" \
            --entrypoint bash \
            "${IMAGE_TAG}" /repo/tests/kbd-layout-harness/entry.sh
    ) || fail "case_${label}" "container run failed (see log above)"

    [ -f "${d}/kbd.env" ] || fail "case_${label}" "generator wrote no env file"
    local layout="${token%%(*}"
    local variant=""
    case "${token}" in
        *\(*) variant="${token#*(}"; variant="${variant%)}" ;;
    esac
    grep -q "^XKB_DEFAULT_LAYOUT=\"${layout}\"$" "${d}/kbd.env" ||
        fail "case_${label}" "env file layout != ${layout}"
    grep -q "^XKB_DEFAULT_VARIANT=\"${variant}\"$" "${d}/kbd.env" ||
        fail "case_${label}" "env file variant != ${variant}"
    grep -q "^PF_KEYBOARD_LAYOUT_SOURCE=\"${source_kind}\"$" "${d}/kbd.env" ||
        fail "case_${label}" "env file source != ${source_kind}"

    [ -f "${d}/result.json" ] || fail "case_${label}" "driver wrote no result"
    python3 - "$d" "$expect" "$token" <<'PY' || fail "case_${label}" \
        "driver result did not match expectations"
import json, sys
d, expect, token = sys.argv[1], sys.argv[2], sys.argv[3]
res = json.load(open(f"{d}/result.json", encoding="utf-8"))
assert res["pass"] is True, f"driver reported failure: {res}"
assert res["committed"] == expect, f"committed {res['committed']!r}"
assert res["expected"] == expect, f"expected {res['expected']!r}"
assert res["token"] == token, f"token {res['token']!r}"
tx = [json.loads(l) for l in
      open(f"{d}/transcripts/x11-gtk.jsonl", encoding="utf-8") if l.strip()]
commits = "".join(e.get("text", "") for e in tx if e.get("event") == "commit")
assert commits == expect, f"transcript commits {commits!r} != {expect!r}"
print(f"    committed {commits!r} for {token} (transcript verified)")
PY
}

# Positive: a German store value makes the probe key (evdev code 39) type ö.
run_case "de-store" store "de" "ö" "stored"
# Negative control, same invocation: resetting to us restores the semicolon.
run_case "us-reset" store "us" ";" "stored"
# Cloud-init first-boot seed path: same layout, sourced from the seed file.
run_case "de-seed" seed "de" "ö" "seed"

echo "PASS: ${NAME} (de->ö stored, us->; reset, seed->ö; gamescope headless)"
