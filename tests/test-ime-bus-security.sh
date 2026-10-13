#!/usr/bin/env bash
# Containerized real-binary private-bus and xdg-dbus-proxy abuse tests.
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "${script_dir}/.." && pwd)
python3 -B "${script_dir}/verify-ime-bus-wiring.py"
container_dir="${script_dir}/ime-bus-security"
snapshot=$(tr -d '\r\n' < "${repo_root}/snapshot-date.txt")
run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-$$"
run_id=$(printf '%s' "${run_id}" | tr -c 'A-Za-z0-9_.-' '-')
image_ref="pocketforge-ime-bus-test:${run_id}"
run_label="pf.ime-bus.run=${run_id}"
image_built=0

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
    exit "${status}"
}
trap cleanup EXIT INT TERM

docker build \
    --build-arg "APT_SNAPSHOT_DATE=${snapshot}" \
    --label pf.bead=tsp-ihne1.5 \
    --label "${run_label}" \
    --tag "${image_ref}" \
    --file "${container_dir}/Containerfile" \
    "${container_dir}" \
    || fail "IME harness image build failed"
image_built=1

# Host AppArmor otherwise denies bwrap's mount-namespace setup even after the
# committed default-deny seccomp policy admits the required syscalls.
docker run --rm \
    --label pf.bead=tsp-ihne1.5 \
    --label "${run_label}" \
    --user "$(id -u):$(id -g)" \
    --env HOME=/tmp \
    --env RUNNER_TEMP=/tmp \
    --network none \
    --security-opt apparmor=unconfined \
    --security-opt "seccomp=${container_dir}/bwrap-seccomp.json" \
    --mount "type=bind,src=${repo_root},dst=/work/image,readonly" \
    --workdir /work/image \
    "${image_ref}" \
    /bin/bash tests/ime-bus-security/run.sh \
    || fail "containerized IME bus security harness failed"
