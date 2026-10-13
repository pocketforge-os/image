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

TRACEPARENT=00-0123456789abcdef0123456789abcdef-0123456789abcdef-01 \
TRACESTATE=pf-red=1 OTEL_SERVICE_NAME=pf-red \
    docker buildx build --no-cache --progress=plain \
    --file "$tmp/Dockerfile" --output "type=local,dest=$tmp/out" "$tmp"

grep -qxF 'PF_TEST_ADMITTED=admitted' "$tmp/out/environment"
if grep -Eq '^(TRACEPARENT|TRACESTATE|OTEL_)' "$tmp/out/environment"; then
    echo 'FAIL: BuildKit tracing environment reached a RUN stage' >&2
    cat "$tmp/out/environment" >&2
    exit 1
fi

echo 'build-stage-environment-test=PASS'
