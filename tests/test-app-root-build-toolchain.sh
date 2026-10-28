#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
base_dockerfile="${root}/build/Dockerfile"
dockerfile="${root}/build/Dockerfile.pf"
builder="${root}/scripts/build-debian-app-root.sh"
workflow="${root}/.github/workflows/input-harness-payload.yml"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/app-root-build-toolchain.XXXXXX")"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT INT TERM

check_contract() {
    local candidate_base_dockerfile=$1
    local candidate_dockerfile=$2
    local candidate_builder=$3
    local candidate_workflow=$4
    python3 - "${candidate_base_dockerfile}" "${candidate_dockerfile}" \
        "${candidate_builder}" "${candidate_workflow}" <<'PY'
from pathlib import Path
import re
import sys

base_dockerfile = Path(sys.argv[1]).read_text(encoding="utf-8")
dockerfile = Path(sys.argv[2]).read_text(encoding="utf-8")
builder = Path(sys.argv[3]).read_text(encoding="utf-8")
workflow = Path(sys.argv[4]).read_text(encoding="utf-8")

if not re.search(r"(?m)^\s*squashfs-tools\s*\\?$", base_dockerfile):
    raise SystemExit("owned build-container recipe missing squashfs-tools")
if "mksquashfs -version" not in base_dockerfile:
    raise SystemExit("owned build-container recipe does not validate mksquashfs")

match = re.search(
    r"(?ms)^FROM pf-build-base AS app-root-tools\n(?P<body>.*?)(?=^FROM |\Z)",
    dockerfile,
)
if match is None:
    raise SystemExit("missing app-root-tools stage")
body = match.group("body")
if "apt-get" in body or re.search(r"(?m)^\s*squashfs-tools\s*\\?$", body):
    raise SystemExit("app-root-tools stage installs tools during the OS image build")
if "scripts/build-debian-app-root.sh" not in body:
    raise SystemExit("app-root-tools stage does not copy the app-root builder")
if "build-debian-app-root.sh --preflight-only" not in body:
    raise SystemExit("app-root-tools stage does not run the real app-root preflight")
if "FROM app-root-tools AS rootfs" not in dockerfile:
    raise SystemExit("rootfs stage does not inherit app-root-tools")

for fragment in ("--preflight-only", "app-root-preflight=PASS"):
    if fragment not in builder:
        raise SystemExit(f"app-root builder missing {fragment}")

for fragment in (
    "--target app-root-tools",
    "--build-context image-src=.",
    "build/Dockerfile.pf",
    "scripts/build-debian-app-root.sh",
    "tests/test-app-root-build-toolchain.sh",
):
    if fragment not in workflow:
        raise SystemExit(f"real-container CI preflight missing {fragment}")
PY
}

# Prove the checker accepts the intended ownership boundary and rejects a
# recipe whose snapshot-pinned package list loses squashfs-tools.
cat >"${scratch}/Dockerfile.base" <<'EOF'
FROM debian:bookworm AS final
RUN apt-get install -y \
    squashfs-tools
RUN mksquashfs -version
EOF
cat >"${scratch}/Dockerfile.pf" <<'EOF'
FROM pf-build-base AS app-root-tools
COPY --from=image-src scripts/build-debian-app-root.sh /usr/local/libexec/build-debian-app-root.sh
RUN /usr/local/libexec/build-debian-app-root.sh --preflight-only
FROM app-root-tools AS rootfs
EOF
cat >"${scratch}/builder.sh" <<'EOF'
case "$1" in --preflight-only) echo app-root-preflight=PASS ;; esac
EOF
cat >"${scratch}/workflow.yml" <<'EOF'
paths: [build/Dockerfile.pf, scripts/build-debian-app-root.sh, tests/test-app-root-build-toolchain.sh]
run: docker buildx build --target app-root-tools --build-context image-src=. .
EOF
check_contract "${scratch}/Dockerfile.base" "${scratch}/Dockerfile.pf" \
    "${scratch}/builder.sh" "${scratch}/workflow.yml"
sed '/squashfs-tools/d' "${scratch}/Dockerfile.base" >"${scratch}/Dockerfile.tampered"
if check_contract "${scratch}/Dockerfile.tampered" "${scratch}/Dockerfile.pf" \
        "${scratch}/builder.sh" "${scratch}/workflow.yml" \
        >"${scratch}/tampered.out" 2>"${scratch}/tampered.err"; then
    echo "FAIL: package-list negative control passed without squashfs-tools" >&2
    exit 1
fi
grep -Fq 'owned build-container recipe missing squashfs-tools' "${scratch}/tampered.err"

check_contract "${base_dockerfile}" "${dockerfile}" "${builder}" "${workflow}"
echo 'PASS: app-root build toolchain is snapshot-pinned and preflighted in the real container'
