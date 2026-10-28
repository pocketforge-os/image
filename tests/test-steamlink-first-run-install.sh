#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="${root}/scripts/install-steamlink-first-run.sh"
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
printf '%s\n' source-owned-fetch-root >"${output}/root.raw"
digest=$(sha256sum "${output}/root.raw" | awk '{print $1}')
[ "${PF_TEST_BAD_METADATA:-0}" = 0 ] || digest=$(printf '%064d' 0)
printf '{"schema_version":1,"distribution":"debian-13","suite":"trixie","architecture":"arm64","sha256":"%s"}\n' \
    "${digest}" >"${output}/root.metadata.json"
EOF
cat >"${bin}/root-renderer" <<'EOF'
#!/usr/bin/env python3
import argparse, json, pathlib, tomllib
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
inventory = json.loads(pathlib.Path(a.inventory).read_text())
assert inventory["platform_runtime_version"] == runtime["platform-runtime-version"]
for target, body in ((a.output, "[Service]\nRootImage=fixture\n"), (a.policy_output, "{}\n")):
    path = pathlib.Path(target)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
EOF
cat >"${bin}/policy-renderer" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "${bin}/root-builder" "${bin}/root-renderer" "${bin}/policy-renderer"

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

bad_rootfs="${scratch}/bad-rootfs"
make_rootfs "${bad_rootfs}"
if PF_TEST_BAD_METADATA=1 \
    PF_STEAMLINK_ROOT_BUILDER="${bin}/root-builder" \
    PF_STEAMLINK_ROOT_RENDERER="${bin}/root-renderer" \
    PF_STEAMLINK_POLICY_RENDERER="${bin}/policy-renderer" \
        "${installer}" "${bad_rootfs}" 20261010T000000Z root \
        >"${scratch}/bad.out" 2>"${scratch}/bad.err"; then
    echo 'metadata mismatch was accepted' >&2
    exit 1
fi
grep -F 'root metadata sha256 differs' "${scratch}/bad.err" >/dev/null
test ! -e "${bad_rootfs}/opt/pocketforge/apps/org.pocketforge.steamlink"

echo 'Steam Link first-run root install: PASS (positive and negative controls)'
