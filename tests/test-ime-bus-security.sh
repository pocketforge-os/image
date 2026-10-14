#!/usr/bin/env bash
# Containerized real-binary private-bus and xdg-dbus-proxy abuse tests.
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "${script_dir}/.." && pwd)
python3 -B "${script_dir}/verify-ime-bus-wiring.py"
container_dir="${script_dir}/ime-bus-security"
snapshot=$(tr -d '\r\n' < "${repo_root}/snapshot-date.txt")
run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-$$"
run_id=$(printf '%s' "${run_id}" | tr -c 'A-Za-z0-9_.-' '-')
image_ref="pocketforge-ime-bus-test:${run_id}"
run_label="pf.ime-bus.run=${run_id}"
image_built=0
view_root=

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required for the real IME bus security harness"
[ "${snapshot}" = 20260601T000000Z ] \
    || fail "snapshot-date.txt drifted: expected 20260601T000000Z, got ${snapshot:-empty}"

cleanup() {
    status=$?
    trap - EXIT INT TERM
    set +e
    container_ids=()
    if ! container_ids_text=$(docker container ls --all --quiet \
            --filter label=pf.bead=tsp-ihne1.5 \
            --filter "label=${run_label}"); then
        echo "FAIL: could not list IME harness containers during cleanup" >&2
        status=1
        container_ids_text=
    fi
    if [ -n "${container_ids_text}" ]; then
        readarray -t container_ids <<<"${container_ids_text}"
    fi
    if [ "${#container_ids[@]}" -gt 0 ]; then
        docker container rm --force "${container_ids[@]}" >/dev/null \
            || { echo "FAIL: could not remove IME harness container" >&2; status=1; }
    fi
    if [ "${image_built}" -eq 1 ]; then
        docker image rm "${image_ref}" >/dev/null \
            || { echo "FAIL: could not remove IME harness image ${image_ref}" >&2; status=1; }
    fi
    if [ -n "${view_root}" ]; then
        find "${view_root}" -mindepth 1 -delete
        rmdir "${view_root}"
    fi
    exit "${status}"
}
trap cleanup EXIT INT TERM
view_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-ime-view.XXXXXX")

docker build \
    --build-arg "APT_SNAPSHOT_DATE=${snapshot}" \
    --build-arg "PF_IME_UID=$(id -u)" \
    --build-arg "PF_IME_GID=$(id -g)" \
    --label pf.bead=tsp-ihne1.5 \
    --label "${run_label}" \
    --tag "${image_ref}" \
    --file "${container_dir}/Containerfile" \
    "${container_dir}" \
    || fail "IME harness image build failed"
image_built=1

docker run --rm \
    --label pf.bead=tsp-ihne1.5 \
    --label "${run_label}" \
    --user "$(id -u):$(id -g)" \
    --env HOME=/tmp \
    --env RUNNER_TEMP=/tmp \
    --network none \
    --read-only \
    --cap-drop ALL \
    --tmpfs /run:rw,nosuid,nodev,mode=0777 \
    --tmpfs /tmp:rw,nosuid,nodev,mode=1777 \
    --mount "type=bind,src=${repo_root},dst=/work/image,readonly" \
    --workdir /work/image \
    "${image_ref}" \
    /bin/bash tests/ime-bus-security/run.sh \
    || fail "containerized IME bus security harness failed"

# Reproduce pf-app@'s mount view in a second disposable container. Only app-a's
# door is present in the read-only /run view; neither another app nor the private
# bus can be reached. This uses Docker's existing mount isolation and therefore
# does not depend on nested user namespaces in the runner VM.
mkdir -p "${view_root}/run/pf-ime-door/app-a"
touch "${view_root}/run/pf-ime-door/app-a/own-door"
docker run --rm \
    --label pf.bead=tsp-ihne1.5 \
    --label "${run_label}" \
    --user "$(id -u):$(id -g)" \
    --env HOME=/tmp \
    --network none \
    --read-only \
    --cap-drop ALL \
    --tmpfs /tmp:rw,nosuid,nodev,mode=1777 \
    --mount "type=bind,src=${view_root}/run,dst=/run,readonly" \
    "${image_ref}" \
    /bin/sh -eu -c '
        test -e /run/pf-ime-door/app-a/own-door || {
            echo "FAIL: app-a own door is absent from the app view" >&2
            exit 1
        }
        test ! -e /run/pf-ime-door/app-b || {
            echo "FAIL: app-b door leaked into the app-a view" >&2
            exit 1
        }
        test ! -e /run/pf-ime/bus || {
            echo "FAIL: private IME bus leaked into the app view" >&2
            exit 1
        }
        if DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/pf-no-session-bus \
            dbus-send --session --print-reply --dest=org.freedesktop.DBus \
                /org/freedesktop/DBus org.freedesktop.DBus.ListNames \
                >/tmp/wayland-no-bus.log 2>&1; then
            echo "FAIL: Wayland app view unexpectedly found a session bus" >&2
            exit 1
        fi
    ' \
    || fail "containerized app-view isolation control failed"
echo "PASS door_cannot_reach_other_door: app-a mount view exposes only app-a"
echo "PASS wayland_no_bus: no session or IME bus socket is visible"
