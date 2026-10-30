#!/usr/bin/env bash
# Runs only inside the digest-pinned CI Rust image; the workflow owns /work.
set -euo pipefail
scripts/check-launcher-runtime-contract.sh launcher-pair runtime-pair \
    pf-app-launch pf-app-manifest pf-scene pf-ports pf-render pf-framehost \
    pf-framehost-wayland pf-hang-trigger pf-theme pf-input-map pf-prefs pf-prefs-port \
    pf-session-client pf-session-authority pf-wire
PF_HANG_RUNTIME_ROOT=runtime-pair tests/test-hang-sampler-image.sh
(cd runtime-pair && cargo build --locked --manifest-path Cargo.toml \
    -p pf-app-launch --bins --target-dir /work/target)
export PF_APP_LAUNCH=/work/target/debug/pf-app-launch
export PF_APP_POLICY_RENDER=/work/target/debug/pf-app-policy-render
(cd /work/target/debug && sha256sum pf-app-launch pf-app-policy-render) > /work/SHA256SUMS
tests/test-app-runtime-root.sh
tests/test-steamlink-app-policy.sh "$PF_APP_POLICY_RENDER"
tests/test-steamlink-first-run-install.sh
tests/test-default-app-platform.sh
PF_RUNTIME_UNITS_DIR=/workspace/runtime-pair/systemd tests/test-runtime-path-producers.sh
