#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${RUNNER_TEMP:-/tmp}/image-build-stage-environment.XXXXXX")
trap 'find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT

shell_instruction=$(grep -m1 '^SHELL .*PF_\*' "$root/build/Dockerfile.pf" || :)
[ -n "$shell_instruction" ] || {
    echo 'FAIL: Dockerfile.pf has no build-stage environment allowlist' >&2
    exit 1
}

{
    printf '%s\n' 'FROM alpine:3.22 AS probe'
    printf '%s\n' "$shell_instruction"
    printf '%s\n' 'ARG PF_TEST_ADMITTED=admitted'
    printf '%s\n' 'RUN mkdir -p /out && env | LC_ALL=C sort > /out/environment'
    printf '%s\n' 'FROM scratch'
    printf '%s\n' 'COPY --from=probe /out /'
} >"$tmp/Dockerfile"

for run in a b; do
    case "$run" in
        a) trace=00-0123456789abcdef0123456789abcdef-0123456789abcdef-01 ;;
        b) trace=00-fedcba9876543210fedcba9876543210-fedcba9876543210-01 ;;
    esac
    TRACEPARENT=$trace TRACESTATE="pf-$run=1" OTEL_SERVICE_NAME="pf-$run" \
        docker buildx build --no-cache --progress=plain \
        --file "$tmp/Dockerfile" --output "type=local,dest=$tmp/out-$run" "$tmp"

    grep -qxF 'PF_TEST_ADMITTED=admitted' "$tmp/out-$run/environment"
    if grep -Eq '^(TRACEPARENT|TRACESTATE|OTEL_)' "$tmp/out-$run/environment"; then
        echo 'FAIL: BuildKit tracing environment reached a RUN stage' >&2
        cat "$tmp/out-$run/environment" >&2
        exit 1
    fi
done
cmp "$tmp/out-a/environment" "$tmp/out-b/environment"

echo 'build-stage-environment-test=PASS'
