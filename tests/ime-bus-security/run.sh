#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "${script_dir}/../.." && pwd)
test_root=$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-ime-bus.XXXXXX")

cleanup() {
    status=$?
    trap - EXIT INT TERM
    find "${test_root}" -mindepth 1 -delete
    rmdir "${test_root}"
    exit "${status}"
}
trap cleanup EXIT INT TERM

mkdir -p /run/pf-ime /run/pf-ime-door/app-a /run/pf-ime-door/app-b
chmod 0700 /run/pf-ime
chmod 0755 /run/pf-ime-door /run/pf-ime-door/app-a /run/pf-ime-door/app-b

pf_ime_uid=$(awk -F: '$1 == "pf-ime" { print $3; exit }' /etc/passwd)
pf_ime_gid=$(awk -F: '$1 == "pf-ime" { print $4; exit }' /etc/passwd)
if [ "${pf_ime_uid}:${pf_ime_gid}" != "$(id -u):$(id -g)" ]; then
    echo "FAIL: container pf-ime identity does not match the invoking uid:gid" >&2
    exit 1
fi

PF_IME_TEST_ROOT="${test_root}" \
PF_IME_REPO_ROOT="${repo_root}" \
    /bin/bash "${script_dir}/../ime-bus-security-inner.sh"
