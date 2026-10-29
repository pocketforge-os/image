#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="${root}/scripts/install-steamlink-first-run.sh"
bind_checker="${root}/scripts/check-app-root-bind-targets.py"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/steamlink-first-run-install.XXXXXX")
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT HUP INT TERM

bin="${scratch}/bin"
mkdir -p "${bin}"
cat >"${bin}/root-builder" <<'EOF'
#!/bin/sh
set -eu
output=
overlay=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        --overlay) overlay=$2; shift 2 ;;
        *) shift ;;
    esac
done
test -x "${overlay}/opt/pocketforge/apps/org.pocketforge.steamlink/pf-launch"
test -x "${overlay}/opt/pocketforge/apps/org.pocketforge.steamlink/steamlink-fetch.py"
test -f "${overlay}/opt/pocketforge/apps/org.pocketforge.steamlink/valve-steamlink-release-key.asc"
if find "${overlay}" -name '*.tar.gz' -o -name '*.sig' | grep -q .; then
    echo 'Valve payload reached app-root overlay' >&2
    exit 1
fi
mkdir -p "${output}"
# The root-image auditor consumes unsquashfs's file list, so this fixture keeps
# the test hermetic by storing the same relative-path inventory as plain text.
# Production still builds and audits the real SquashFS in build-rootfs.sh.
find "${overlay}" -mindepth 1 -printf '%P\n' | LC_ALL=C sort >"${output}/root.raw"
digest=$(sha256sum "${output}/root.raw" | awk '{print $1}')
[ "${PF_TEST_BAD_METADATA:-0}" = 0 ] || digest=$(printf '%064d' 0)
printf '{"schema_version":1,"distribution":"debian-13","suite":"trixie","architecture":"arm64","sha256":"%s"}\n' \
    "${digest}" >"${output}/root.metadata.json"
EOF
cat >"${bin}/unsquashfs" <<'EOF'
#!/usr/bin/env python3
import os
import pathlib
import sys

image = pathlib.Path(sys.argv[-1])
drop = os.environ.get("PF_TEST_DROP_BIND_TARGET", "")
print("squashfs-root")
for raw in image.read_text(encoding="utf-8").splitlines():
    relative = raw.strip().lstrip("/")
    if not relative or "/" + relative == drop:
        continue
    print("squashfs-root/" + relative)
EOF
cat >"${bin}/root-renderer" <<'EOF'
#!/usr/bin/env python3
import argparse, json, os, pathlib, runpy, tomllib
p = argparse.ArgumentParser()
for name in ("manifest", "inventory", "platform-contract", "policy-renderer", "policy-output", "output", "app-root-store", "platform-runtime-store"):
    p.add_argument("--" + name, required=True)
a = p.parse_args()
with open(a.manifest, "rb") as source:
    manifest = tomllib.load(source)
runtime = manifest["runtime"]["root"]
assert runtime["distribution"] == "debian-13"
assert runtime["digest"] != "sha256:" + "0" * 64
assert runtime["platform-runtime-version"] != "sha256:" + "0" * 64
renderer = runpy.run_path(os.environ["PF_REAL_ROOT_RENDERER"])
inventory = renderer["load_inventory"](pathlib.Path(a.inventory))
assert inventory["platform_runtime_version"] == runtime["platform-runtime-version"]
assert inventory["platform_runtime"] == runtime["platform-runtime"]
assert inventory["platform_runtime_abi"] == runtime["platform-runtime-abi"]
assert all(inventory["resources"].values())

# Exercise the remaining descriptor/inventory validation and render path using
# the installer's exact transformed inputs. Artifact integrity and Rust policy
# compilation have their own hermetic suites; replacing only those two leaves
# this test focused on the producer boundary that failed the owned image build.
globals_ = renderer["render"].__globals__
globals_["require_artifacts"] = lambda **kwargs: None
policy_lines = [
    line for line in pathlib.Path(os.environ["PF_REAL_POLICY_FRAGMENT"])
    .read_text(encoding="utf-8").splitlines()
    if line and line != "[Service]"
]
globals_["compile_policy"] = lambda **kwargs: (
    {"schema_version": 1, "manifest_sha256": "fixture"}, policy_lines
)
rendered = renderer["render"](
    renderer["load_toml"](pathlib.Path(a.manifest)),
    inventory,
    pathlib.Path(a.app_root_store),
    pathlib.Path(a.platform_runtime_store),
    manifest_path=pathlib.Path(a.manifest),
    platform_contract=pathlib.Path(a.platform_contract),
    policy_renderer=pathlib.Path(a.policy_renderer),
)
assert rendered is not None
assert "# runtime root distribution: debian-13 (trixie)" in rendered
assert "SupplementaryGroups=audio input pf-session video" in rendered
resources = json.dumps({
    "platform_runtime": "/run/pocketforge/platform-runtime",
    "resources": inventory["resources"],
}, sort_keys=True, separators=(",", ":")) + "\n"
for target, body in ((a.output, rendered), (a.policy_output, resources)):
    path = pathlib.Path(target)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
EOF
cat >"${bin}/policy-renderer" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "${bin}/root-builder" "${bin}/unsquashfs" \
    "${bin}/root-renderer" "${bin}/policy-renderer"

make_rootfs() {
    local target=$1 digest
    mkdir -p \
        "${target}/usr/lib/pocketforge/platform-runtimes/pocketforge-bookworm-aarch64" \
        "${target}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1" \
        "${target}/usr/share/pocketforge" \
        "${target}/etc/systemd/system/pf-app@org.pocketforge.steamlink.service.d"
    printf '%s\n' legacy-host-root-policy \
        >"${target}/etc/systemd/system/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf"
    digest=$(printf '%064d' 1)
    mkdir "${target}/usr/lib/pocketforge/platform-runtimes/pocketforge-bookworm-aarch64/sha256-${digest}"
    printf '%s\n' "${digest}" \
        >"${target}/usr/lib/pocketforge/platform-runtimes/pocketforge-bookworm-aarch64/sha256-${digest}/.manifest-sha256"
    printf '%s\n' 'schema_version = 1' \
        >"${target}/usr/share/pocketforge/platform-capabilities.toml"
}

rootfs="${scratch}/rootfs"
make_rootfs "${rootfs}"
PF_STEAMLINK_ROOT_BUILDER="${bin}/root-builder" \
PF_STEAMLINK_ROOT_RENDERER="${bin}/root-renderer" \
PF_STEAMLINK_POLICY_RENDERER="${bin}/policy-renderer" \
PF_REAL_ROOT_RENDERER="${root}/scripts/render-app-runtime-root.py" \
PF_REAL_POLICY_FRAGMENT="${root}/build/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf" \
    "${installer}" "${rootfs}" 20261010T000000Z root

manifest="${rootfs}/opt/pocketforge/apps/org.pocketforge.steamlink/app.toml"
python3 - "${manifest}" <<'PY'
import pathlib, sys, tomllib
path = pathlib.Path(sys.argv[1])
with path.open("rb") as source:
    root = tomllib.load(source)["runtime"]["root"]
assert root["distribution"] == "debian-13"
assert root["digest"] != "sha256:" + "0" * 64
assert root["platform-runtime-version"] != "sha256:" + "0" * 64
assert sorted(path.parent.iterdir()) == [path]
PY
dropin="${rootfs}/etc/systemd/system/pf-app@org.pocketforge.steamlink.service.d/20-runtime-root.conf"
grep -Fx 'BindReadOnlyPaths=/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1' "${dropin}" >/dev/null
grep -F 'steamlink-ffmpeg59/v1/lib/aarch64-linux-gnu' "${dropin}" >/dev/null
test ! -e "${rootfs}/etc/systemd/system/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf"
python3 "${bind_checker}" --root "${rootfs}" --unsquashfs "${bin}/unsquashfs"

missing_target="/opt/pocketforge/apps/org.pocketforge.steamlink/app.toml"
if PF_TEST_DROP_BIND_TARGET="${missing_target}" \
    python3 "${bind_checker}" --root "${rootfs}" --unsquashfs "${bin}/unsquashfs" \
        >"${scratch}/missing-bind.out" 2>"${scratch}/missing-bind.err"; then
    echo 'missing RootImage bind destination was accepted' >&2
    exit 1
fi
grep -F "destination missing from RootImage: ${missing_target}" \
    "${scratch}/missing-bind.err" >/dev/null

bad_rootfs="${scratch}/bad-rootfs"
make_rootfs "${bad_rootfs}"
if PF_TEST_BAD_METADATA=1 \
    PF_STEAMLINK_ROOT_BUILDER="${bin}/root-builder" \
    PF_STEAMLINK_ROOT_RENDERER="${bin}/root-renderer" \
    PF_STEAMLINK_POLICY_RENDERER="${bin}/policy-renderer" \
    PF_REAL_ROOT_RENDERER="${root}/scripts/render-app-runtime-root.py" \
    PF_REAL_POLICY_FRAGMENT="${root}/build/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf" \
        "${installer}" "${bad_rootfs}" 20261010T000000Z root \
        >"${scratch}/bad.out" 2>"${scratch}/bad.err"; then
    echo 'metadata mismatch was accepted' >&2
    exit 1
fi
grep -F 'root metadata sha256 differs' "${scratch}/bad.err" >/dev/null
test ! -e "${bad_rootfs}/opt/pocketforge/apps/org.pocketforge.steamlink"

echo 'Steam Link first-run root install: PASS (positive and negative controls)'
