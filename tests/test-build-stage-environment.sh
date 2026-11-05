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

# The apt cache arrives as BuildKit's predefined http_proxy build-arg (tsp-hqm1p.135). It
# must (1) pass the allowlist, (2) be the ONLY proxy variable that does, and (3) stay out
# of the layer cache key: a build without it reuses the layer a build with it produced,
# and a fresh build without it differs by that one variable. A per-run nonce makes the
# keys unique to this run; the proxy URL is only a value here and is never contacted.
nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
proxy=http://apt-cache.invalid:3142
{
    printf '%s\n' 'FROM alpine:3.22 AS probe'
    printf '%s\n' "$shell_instruction"
    printf '%s\n' "ARG PF_TEST_NONCE=$nonce"
    printf '%s\n' 'RUN mkdir -p /out && env | LC_ALL=C sort > /out/environment'
    printf '%s\n' 'FROM scratch'
    printf '%s\n' 'COPY --from=probe /out /'
} >"$tmp/Dockerfile.proxy"
proxy_build() {
    out=$1
    shift
    docker buildx build --progress=plain --file "$tmp/Dockerfile.proxy" \
        --output "type=local,dest=$tmp/$out" "$@" "$tmp"
}
# BuildKit exports HTTP_PROXY alongside http_proxy and treats the two as one setting, so
# only the lowercase name is ever passed (conflicting values would race); the allowlist
# must still strip the uppercase twin it adds.
proxy_build proxy-with --build-arg "http_proxy=$proxy" --build-arg 'https_proxy=http://other.invalid:1' \
    --build-arg 'no_proxy=other.invalid' --build-arg 'all_proxy=http://other.invalid:3'
grep -qxF "http_proxy=$proxy" "$tmp/proxy-with/environment" || {
    echo 'FAIL: the sanitising SHELL strips the predefined http_proxy, so no apt stage can use the cache' >&2
    cat "$tmp/proxy-with/environment" >&2
    exit 1
}
if grep -Eq '^(https_proxy|HTTPS_PROXY|no_proxy|NO_PROXY|all_proxy|ALL_PROXY|ftp_proxy|FTP_PROXY|HTTP_PROXY)=' "$tmp/proxy-with/environment"; then
    echo 'FAIL: a proxy variable other than http_proxy reached a RUN stage' >&2
    cat "$tmp/proxy-with/environment" >&2
    exit 1
fi
proxy_build proxy-reused
cmp "$tmp/proxy-with/environment" "$tmp/proxy-reused/environment" || {
    echo 'FAIL: dropping the apt cache re-ran the layer, so the proxy is part of the cache key' >&2
    exit 1
}
proxy_build proxy-without --no-cache
grep -vx "http_proxy=$proxy" "$tmp/proxy-with/environment" >"$tmp/environment-without-proxy"
cmp "$tmp/environment-without-proxy" "$tmp/proxy-without/environment" || {
    echo 'FAIL: the apt cache changed the RUN environment by more than http_proxy' >&2
    exit 1
}

echo 'build-stage-environment-test=PASS'
