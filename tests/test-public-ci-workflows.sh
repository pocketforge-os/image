#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/image-public-ci-contract.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT

fail()
{
    printf 'public_ci_contract=FAIL reason=%s\n' "$1" >&2
    exit 1
}

check_workflow()
{
    workflow=$1
    name=$2
    shift 2

    test "$(grep -Fxc '    runs-on: [self-hosted, pf-public-ci]' "$workflow")" -eq 1 \
        || fail "$name must use exactly self-hosted,pf-public-ci"
    if grep -Eq 'pf-builder-vm|pf-pool-ci|pf-pool-trusted' "$workflow"; then
        fail "$name names a trusted runner class"
    fi
    if grep -Eq '^    if:' "$workflow"; then
        fail "$name has a job-level condition that can skip pull requests"
    fi
    if grep -Eq '^[[:space:]]*pull_request_target:' "$workflow"; then
        fail "$name uses pull_request_target"
    fi

    checkout_count=$(grep -c 'uses: actions/checkout@' "$workflow")
    credential_count=$(grep -Fxc '          persist-credentials: false' "$workflow")
    test "$checkout_count" -gt 0 || fail "$name does not check out source"
    test "$credential_count" -eq "$checkout_count" \
        || fail "$name leaves checkout credentials available"

    for source_file in "$workflow" "$@"; do
        test -f "$source_file" || fail "$name execution input is missing: $source_file"
        if grep -Eiq \
            '(^|[^0-9])(10\.[0-9]+\.[0-9]+\.[0-9]+|127\.[0-9]+\.[0-9]+\.[0-9]+|169\.254\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)([^0-9]|$)|([[:alnum:]-]+\.)*lan([/:]|$)|localhost([/:]|$)|:[0-9]*/pocketforge/' \
            "$source_file"; then
            fail "$name execution input names a private registry or LAN endpoint: $source_file"
        fi
        if grep -Eq 'actions/cache@|type=cache|--mount[ =][^[:space:]]*cache' "$source_file"; then
            fail "$name requests a persistent cache: $source_file"
        fi
    done

    grep -Fq 'tests/prove-public-ci-fit.sh' "$workflow" \
        || fail "$name does not execute the bounded-runner proof"
}

expect_refusal()
{
    reason=$1
    shift
    if (check_workflow "$@" >/dev/null 2>&1); then
        fail "negative control accepted: $reason"
    fi
}

check_public_builder_workflow()
{
    workflow=$1

    test "$(grep -Fxc '    runs-on: [self-hosted, pf-public-builder]' "$workflow")" -eq 1 \
        || fail 'app-policy-pair must use exactly self-hosted,pf-public-builder'
    if grep -Eq 'runs-on:.*(pf-pr-review|pf-ci([^[:alnum:]-]|$)|pf-ci-container|pf-docker)' "$workflow"; then
        fail 'app-policy-pair retains a legacy or credential-bearing runner label'
    fi
    if grep -Eq '^[[:space:]]+container:' "$workflow"; then
        fail 'app-policy-pair asks GitHub to pull a job container at runtime'
    fi
    grep -Fq 'docker run --rm --pull=never' "$workflow" \
        || fail 'app-policy-pair does not prohibit a runtime image pull'
    grep -Fq '10.0.32.86:5555/pocketforge/ci-rust@sha256:801f15f7e8fd20b449e3b0d0a7a56d632e28dae825b251a19a30e6f8b32bd8e9' "$workflow" \
        || fail 'app-policy-pair does not select the golden-bundled pinned image'
    test "$(grep -c 'uses: actions/checkout@' "$workflow")" -eq \
        "$(grep -Fxc '          persist-credentials: false' "$workflow")" \
        || fail 'app-policy-pair leaves checkout credentials available'
}

check_signing_routes()
{
    workflow=$1

    grep -Fq "      - '.github/workflows/sign-and-scan.yml'" "$workflow" \
        || fail 'sign-and-scan does not canary its own routing changes'
    test "$(grep -Fxc '    runs-on: [self-hosted, pf-public-ci]' "$workflow")" -eq 2 \
        || fail 'sign-and-scan package and sign jobs must use pf-public-ci'
    if grep -Eq 'runs-on:.*(pf-pr-review|pf-ci([^[:alnum:]-]|$)|pf-ci-container|pf-docker)' "$workflow"; then
        fail 'sign-and-scan retains a legacy or credential-bearing runner label'
    fi
    test "$(grep -c 'uses: actions/checkout@' "$workflow")" -eq \
        "$(grep -Fxc '          persist-credentials: false' "$workflow")" \
        || fail 'sign-and-scan leaves checkout credentials available'
}

build_workflow=$root/.github/workflows/build-stage-environment.yml
ime_workflow=$root/.github/workflows/ime-bus-security.yml
fit_proof=$root/tests/prove-public-ci-fit.sh

check_workflow "$build_workflow" build-stage-environment \
    "$root/tests/test-build-stage-environment.sh"
check_workflow "$ime_workflow" ime-bus-security \
    "$root/tests/test-ime-bus-security.sh" \
    "$root/tests/ime-bus-security/Containerfile"

test -x "$fit_proof" || fail 'bounded-runner proof is missing or not executable'
for witness in \
    'cpu_limit=4' \
    'memory_limit_kib=8388608' \
    'disk_limit_kib=54525952' \
    'command -v docker' \
    'docker buildx version'
do
    grep -Fq "$witness" "$fit_proof" \
        || fail "bounded-runner proof is missing witness: $witness"
done

sed 's/pf-public-ci/pf-builder-vm/' "$build_workflow" >"$scratch/trusted.yml"
expect_refusal trusted-runner "$scratch/trusted.yml" build-stage-environment \
    "$root/tests/test-build-stage-environment.sh"

sed '/    runs-on:/i\    if: github.event.pull_request.head.repo.full_name == github.repository' \
    "$build_workflow" >"$scratch/fork-skip.yml"
expect_refusal fork-skip "$scratch/fork-skip.yml" build-stage-environment \
    "$root/tests/test-build-stage-environment.sh"

sed 's/^  pull_request:/  pull_request_target:/' \
    "$build_workflow" >"$scratch/pr-target.yml"
expect_refusal pull-request-target "$scratch/pr-target.yml" build-stage-environment \
    "$root/tests/test-build-stage-environment.sh"

sed '/persist-credentials: false/d' "$build_workflow" >"$scratch/credentials.yml"
expect_refusal persisted-credentials "$scratch/credentials.yml" build-stage-environment \
    "$root/tests/test-build-stage-environment.sh"

cp "$build_workflow" "$scratch/private-endpoint.yml"
printf '%s\n' '      # registry.lan/pocketforge/image' >>"$scratch/private-endpoint.yml"
expect_refusal private-endpoint "$scratch/private-endpoint.yml" build-stage-environment \
    "$root/tests/test-build-stage-environment.sh"

cp "$build_workflow" "$scratch/cache.yml"
printf '%s\n' '      # uses: actions/cache@v4' >>"$scratch/cache.yml"
expect_refusal persistent-cache "$scratch/cache.yml" build-stage-environment \
    "$root/tests/test-build-stage-environment.sh"

pair_workflow=$root/.github/workflows/app-policy-pair.yml
signing_workflow=$root/.github/workflows/sign-and-scan.yml
check_public_builder_workflow "$pair_workflow"
check_signing_routes "$signing_workflow"

sed 's/pf-public-builder/pf-ci/' "$pair_workflow" >"$scratch/private-builder.yml"
if (check_public_builder_workflow "$scratch/private-builder.yml" >/dev/null 2>&1); then
    fail 'negative control accepted the private pf-ci route for app-policy-pair'
fi
sed 's/--pull=never/--pull=always/' "$pair_workflow" >"$scratch/network-pull.yml"
if (check_public_builder_workflow "$scratch/network-pull.yml" >/dev/null 2>&1); then
    fail 'negative control accepted a runtime registry pull'
fi
sed '0,/pf-public-ci/s//pf-ci-container/' "$signing_workflow" >"$scratch/private-signing.yml"
if (check_signing_routes "$scratch/private-signing.yml" >/dev/null 2>&1); then
    fail 'negative control accepted a private signing route'
fi

printf '%s\n' \
    'public_ci_contract=PASS workflows=build-stage-environment,ime-bus-security,app-policy-pair,sign-and-scan runners=pf-public-ci,pf-public-builder skip=release-sign-only credentials=none egress=public-only persistent_cache=none limits=bounded'
