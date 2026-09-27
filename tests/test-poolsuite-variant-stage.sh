#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${root}/build/Dockerfile.pf"
rootfs_builder="${root}/scripts/build-rootfs.sh"

grep -Fx 'FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171 AS poolsuite-toolchain' "${dockerfile}" >/dev/null
grep -Fx 'ARG RUST_VERSION=1.91.0' "${dockerfile}" >/dev/null
grep -Fx 'ARG RUSTUP_INIT_SHA256=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c' "${dockerfile}" >/dev/null
grep -Fx 'dpkg-query -W > /toolchain-packages.txt' "${dockerfile}" >/dev/null

grep -Fx 'FROM poolsuite-toolchain AS poolsuite-fetch' "${dockerfile}" >/dev/null
grep -Fx 'FROM poolsuite-toolchain AS poolsuite-dev' "${dockerfile}" >/dev/null
# shellcheck disable=SC2016 # Match literal Dockerfile ARG interpolation.
grep -Fx 'FROM ${PF_CONTAINER} AS poolsuite-release' "${dockerfile}" >/dev/null
# shellcheck disable=SC2016 # Match literal Dockerfile ARG interpolation.
grep -Fx 'FROM poolsuite-${PF_VARIANT} AS poolsuite' "${dockerfile}" >/dev/null

fetch_body="$(sed -n '/^FROM poolsuite-toolchain AS poolsuite-fetch$/,/^FROM poolsuite-toolchain AS poolsuite-dev$/p' "${dockerfile}")"
grep -F 'COPY --from=poolsuite-src . /work/poolsuite' <<<"${fetch_body}" >/dev/null
grep -F './ci/device-fetch.sh' <<<"${fetch_body}" >/dev/null
grep -F 'there is no fallback' <<<"${fetch_body}" >/dev/null

# shellcheck disable=SC2016 # sed matches literal Dockerfile ARG interpolation.
dev_body="$(sed -n '/^FROM poolsuite-toolchain AS poolsuite-dev$/,/^FROM ${PF_CONTAINER} AS poolsuite-release$/p' "${dockerfile}")"
grep -F 'COPY --from=poolsuite-fetch /opt/poolsuite-cargo-home /opt/poolsuite-cargo-home' <<<"${dev_body}" >/dev/null
grep -F 'RUN --network=none' <<<"${dev_body}" >/dev/null
grep -F './ci/device-build.sh --offline' <<<"${dev_body}" >/dev/null
grep -F 'NEEDED.*libSDL3' <<<"${dev_body}" >/dev/null
grep -F 'GLIBC_2.36' <<<"${dev_body}" >/dev/null
for key in poolsuite@ cargo_lock_sha256 fetched_source_sha256 ps_app_sha256; do
    grep -F "${key}" <<<"${dev_body}" >/dev/null
done

# shellcheck disable=SC2016 # sed matches literal Dockerfile ARG interpolation.
release_body="$(sed -n '/^FROM ${PF_CONTAINER} AS poolsuite-release$/,/^FROM poolsuite-${PF_VARIANT} AS poolsuite$/p' "${dockerfile}")"
if grep -Eq 'poolsuite-src|poolsuite-fetch|PF_POOLSUITE_SHA|device-(fetch|build)' <<<"${release_body}"; then
    echo 'release stage unexpectedly references the Poolsuite build graph' >&2
    exit 1
fi
grep -Eq '^COPY --from=poolsuite[[:space:]]+/out[[:space:]]+/work/poolsuite$' "${dockerfile}"
grep -F 'POOLSUITE_DIR=/work/poolsuite' "${dockerfile}" >/dev/null
# shellcheck disable=SC2016 # Match a literal shell variable in build-rootfs.sh.
grep -F '"${POOLSUITE_DIR}"' "${rootfs_builder}" >/dev/null

echo 'poolsuite variant stage contract: PASS'
