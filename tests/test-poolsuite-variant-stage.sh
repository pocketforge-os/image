#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${root}/build/Dockerfile.pf"
rootfs_builder="${root}/scripts/build-rootfs.sh"

grep -Fx 'FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS poolsuite-toolchain' "${dockerfile}" >/dev/null
grep -Fx 'ARG RUST_VERSION=1.91.0' "${dockerfile}" >/dev/null
grep -Fx 'ARG RUSTUP_INIT_SHA256=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c' "${dockerfile}" >/dev/null
grep -Fx 'dpkg-query -W > /toolchain-packages.txt' "${dockerfile}" >/dev/null
grep -Fx 'ARG PF_SOC=not-shipped' "${dockerfile}" >/dev/null

grep -Fx 'FROM poolsuite-toolchain AS poolsuite-fetch' "${dockerfile}" >/dev/null
grep -Fx 'FROM poolsuite-toolchain AS poolsuite-dev' "${dockerfile}" >/dev/null
# shellcheck disable=SC2016 # Match literal Dockerfile ARG interpolation.
grep -Fx 'FROM ${PF_CONTAINER} AS poolsuite-not-shipped' "${dockerfile}" >/dev/null
# Only A133 + open + dev reaches the real producer. Every other normative
# profile resolves immediately to the source-free NOT-SHIPPED stage.
grep -Fx 'FROM poolsuite-dev AS poolsuite-sun50iw10p1-open-dev' "${dockerfile}" >/dev/null
for soc in sun50iw10p1 sun55iw3; do
    for gpu_model in open ddk none; do
        for variant in dev release; do
            alias="poolsuite-${soc}-${gpu_model}-${variant}"
            producer="$(sed -n "s/^FROM \([^ ]*\) AS ${alias}$/\1/p" "${dockerfile}")"
            test -n "${producer}"
            if [ "${soc}:${gpu_model}:${variant}" = sun50iw10p1:open:dev ]; then
                test "${producer}" = poolsuite-dev
            else
                test "${producer}" = poolsuite-not-shipped
            fi
        done
    done
done
grep -Fx 'FROM poolsuite-not-shipped AS poolsuite-not-shipped-ddk-dev' "${dockerfile}" >/dev/null
grep -Fx 'FROM poolsuite-not-shipped AS poolsuite-not-shipped-ddk-release' "${dockerfile}" >/dev/null
# shellcheck disable=SC2016 # Match literal Dockerfile ARG interpolation.
grep -Fx 'FROM poolsuite-${PF_SOC}-${PF_GPU_MODEL}-${PF_VARIANT} AS poolsuite' "${dockerfile}" >/dev/null

fetch_body="$(sed -n '/^FROM poolsuite-toolchain AS poolsuite-fetch$/,/^FROM poolsuite-toolchain AS poolsuite-dev$/p' "${dockerfile}")"
grep -F 'COPY --from=poolsuite-src . /work/poolsuite' <<<"${fetch_body}" >/dev/null
grep -F './ci/device-fetch.sh' <<<"${fetch_body}" >/dev/null
grep -F 'there is no fallback' <<<"${fetch_body}" >/dev/null

# shellcheck disable=SC2016 # sed matches literal Dockerfile ARG interpolation.
dev_body="$(sed -n '/^FROM poolsuite-toolchain AS poolsuite-dev$/,/^FROM ${PF_CONTAINER} AS poolsuite-not-shipped$/p' "${dockerfile}")"
grep -F -- '--mount=type=bind,from=poolsuite-fetch,source=/opt/poolsuite-cargo-home,target=/opt/poolsuite-cargo-home,rw' <<<"${dev_body}" >/dev/null
if grep -F 'COPY --from=poolsuite-fetch /opt/poolsuite-cargo-home' <<<"${dev_body}"; then
    echo 'poolsuite dev stage unexpectedly copies the fetched Cargo closure' >&2
    exit 1
fi
grep -F 'RUN --network=none' <<<"${dev_body}" >/dev/null
grep -F './ci/device-build.sh --offline' <<<"${dev_body}" >/dev/null
grep -F 'NEEDED.*libSDL3' <<<"${dev_body}" >/dev/null
grep -F 'GLIBC_2.36' <<<"${dev_body}" >/dev/null
grep -F 'pf-app-validate /tmp/default-app-root /work/platform-capabilities.toml org.pocketforge.poolsuite' <<<"${dev_body}" >/dev/null
grep -F 'COPY --from=runtime /out/build-tools/pf-app-validate' <<<"${dev_body}" >/dev/null
for key in poolsuite@ cargo_lock_sha256 fetched_source_sha256 ps_app_sha256; do
    grep -F "${key}" <<<"${dev_body}" >/dev/null
done

# shellcheck disable=SC2016 # sed matches literal Dockerfile ARG interpolation.
not_shipped_body="$(sed -n '/^FROM ${PF_CONTAINER} AS poolsuite-not-shipped$/,/^FROM poolsuite-dev AS poolsuite-sun50iw10p1-open-dev$/p' "${dockerfile}")"
if grep -Eq 'poolsuite-src|poolsuite-fetch|PF_POOLSUITE_SHA|device-(fetch|build)' <<<"${not_shipped_body}"; then
    echo 'NOT-SHIPPED stage unexpectedly references the Poolsuite build graph' >&2
    exit 1
fi
grep -Eq '^COPY --from=poolsuite[[:space:]]+/out[[:space:]]+/work/poolsuite$' "${dockerfile}"
grep -F 'POOLSUITE_DIR=/work/poolsuite' "${dockerfile}" >/dev/null
# shellcheck disable=SC2016 # Match a literal shell variable in build-rootfs.sh.
grep -F '"${POOLSUITE_DIR}"' "${rootfs_builder}" >/dev/null

echo 'poolsuite variant stage contract: PASS'
