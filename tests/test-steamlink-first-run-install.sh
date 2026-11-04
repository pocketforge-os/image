#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
installer="${root}/scripts/install-steamlink-first-run.sh"
export PF_TEST_SOURCE_DESCRIPTOR="${root}/apps/steamlink/app.toml"
bind_checker="${root}/scripts/check-app-root-bind-targets.py"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/steamlink-first-run-install.XXXXXX")
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT HUP INT TERM

export PF_TEST_CAPTURE_OVERLAY="${scratch}/captured-overlay"
export PF_TEST_CAPTURE_RUNTIME_ROOT="${scratch}/captured-runtime-root"
bin="${scratch}/bin"
mkdir -p "${bin}"
cat >"${bin}/root-builder" <<'EOF'
#!/bin/sh
set -eu
output=
overlay=
packages=
systemd_resolved_stub=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output=$2; shift 2 ;;
        --overlay) overlay=$2; shift 2 ;;
        --package) packages="${packages}${packages:+ }$2"; shift 2 ;;
        --systemd-resolved-stub) systemd_resolved_stub=true; shift ;;
        *) shift ;;
    esac
done
python3 - "${PF_TEST_SOURCE_DESCRIPTOR}" "${overlay}" <<'PYTHON'
import pathlib, sys, tomllib
manifest = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
executable = pathlib.Path(sys.argv[2]) / "opt/pocketforge/apps" / manifest["app"]["id"] / manifest["launch"]["exec"]
assert executable.is_file() and executable.stat().st_mode & 0o111, executable
PYTHON
test -x "${overlay}/opt/pocketforge/apps/org.pocketforge.steamlink/steamlink-fetch.py"
test -f "${overlay}/opt/pocketforge/apps/org.pocketforge.steamlink/valve-steamlink-release-key.gpg"
if find "${overlay}" -name '*.tar.gz' -o -name '*.sig' | grep -q .; then
    echo 'Valve payload reached app-root overlay' >&2
    exit 1
fi
mkdir -p "${output}"
if [ ! -e "${PF_TEST_CAPTURE_OVERLAY}" ]; then cp -a "${overlay}" "${PF_TEST_CAPTURE_OVERLAY}"; fi
# Model the package split at the producer seam with the host's complete stdlib:
# python3 supplies it, while python3-minimal deliberately omits http.  The
# resulting root executes the packaged helper without network or host imports.
runtime_layout="${output}-runtime"
python3 - "${overlay}" "${runtime_layout}" "${packages}" \
    "${systemd_resolved_stub}" <<'PYTHON'
import pathlib
import shutil
import sys
import sysconfig

overlay = pathlib.Path(sys.argv[1])
runtime = pathlib.Path(sys.argv[2])
package_text = sys.argv[3]
systemd_resolved_stub = sys.argv[4] == "true"
packages = set(str(package_text).split())
shutil.copytree(overlay, runtime)
# Model the package/bootstrap resolver leak at the real producer seam. The
# shipped root must replace this build-network address with its runtime DNS
# contract while preserving glibc's DNS NSS closure.
etc = runtime / "etc"
etc.mkdir(exist_ok=True)
(etc / "resolv.conf").write_text("nameserver 192.168.151.1\n", encoding="utf-8")
(etc / "nsswitch.conf").write_text("hosts: files dns\n", encoding="utf-8")
nss_dns = runtime / "usr" / "lib" / "aarch64-linux-gnu" / "libnss_dns.so.2"
nss_dns.parent.mkdir(parents=True, exist_ok=True)
nss_dns.write_bytes(b"fixture libnss_dns closure\n")
if systemd_resolved_stub:
    (etc / "resolv.conf").write_text("nameserver 127.0.0.53\n", encoding="utf-8")
stdlib = pathlib.Path(sysconfig.get_path("stdlib"))
target = runtime / "usr" / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}"
shutil.copytree(stdlib, target)
for name in ("site-packages", "dist-packages"):
    shutil.rmtree(target / name, ignore_errors=True)
for cache in target.rglob("__pycache__"):
    shutil.rmtree(cache)
python = runtime / "usr" / "bin" / "python3"
python.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(sys.executable, python, follow_symlinks=True)
if "python3" not in packages:
    shutil.rmtree(target / "http")
PYTHON
if [ ! -e "${PF_TEST_CAPTURE_RUNTIME_ROOT}" ]; then
    cp -a "${runtime_layout}" "${PF_TEST_CAPTURE_RUNTIME_ROOT}"
fi
# The root-image auditor consumes unsquashfs's file list, so this fixture keeps
# the test hermetic by storing the same relative-path inventory as plain text.
# Production still builds and audits the real SquashFS in build-rootfs.sh.
find "${runtime_layout}" -mindepth 1 -printf '%y %P\n' | LC_ALL=C sort >"${output}/root.raw"
if [ "${PF_TEST_REAL_SQUASHFS:-0}" = 1 ]; then
    rm "${output}/root.raw"
    mksquashfs "${runtime_layout}" "${output}/root.raw" -noappend -no-progress -processors 1 > /dev/null
fi
digest=$(sha256sum "${output}/root.raw" | awk '{print $1}')
[ "${PF_TEST_BAD_METADATA:-0}" = 0 ] || digest=$(printf '%064d' 0)
python3 - "${output}/root.metadata.json" "${digest}" "${packages}" <<'PYTHON'
import json, os, pathlib, sys
packages = {"ca-certificates", "libc6", "libgcc-s1", "libstdc++6"}
packages.update(sys.argv[3].split())
if os.environ.get("PF_TEST_BAD_PACKAGES") == "1":
    packages.discard("python3")
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "schema_version": 1, "distribution": "debian-13", "suite": "trixie",
    "architecture": "arm64", "packages": sorted(packages), "sha256": sys.argv[2],
}, sort_keys=True, separators=(",", ":")) + "\n")
PYTHON
EOF
cat >"${bin}/unsquashfs" <<'EOF'
#!/usr/bin/env python3
import os
import pathlib
import sys

image = pathlib.Path(sys.argv[-1])
drop = os.environ.get("PF_TEST_DROP_BIND_TARGET", "")
print("drwxr-xr-x 0/0 0 2026-01-01 00:00 squashfs-root")
for raw in image.read_text(encoding="utf-8").splitlines():
    kind, relative = raw.split(" ", 1)
    kind = "-" if kind == "f" else kind
    if not relative or "/" + relative == drop:
        continue
    if os.environ.get("PF_TEST_WRONG_TYPE") == "/" + relative:
        kind = os.environ.get("PF_TEST_TARGET_TYPE", "-")
    print(kind + "rwxr-xr-x 0/0 0 2026-01-01 00:00 squashfs-root/" + relative)
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
    install -m 0644 "${root}/rootfs-overlay/etc/systemd/system/pf-app@.service" \
        "${target}/etc/systemd/system/pf-app@.service"
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

runtime_python="${PF_TEST_CAPTURE_RUNTIME_ROOT}/usr/bin/python3"
runtime_helper="${PF_TEST_CAPTURE_RUNTIME_ROOT}/opt/pocketforge/apps/org.pocketforge.steamlink/steamlink-fetch.py"
runtime_home="${PF_TEST_CAPTURE_RUNTIME_ROOT}/usr"
python3 - "${PF_TEST_CAPTURE_RUNTIME_ROOT}" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
resolver = (root / "etc/resolv.conf").read_text(encoding="utf-8")
assert resolver == "nameserver 127.0.0.53\n", f"build resolver survived: {resolver!r}"
assert "hosts: files dns" in (root / "etc/nsswitch.conf").read_text(encoding="utf-8").splitlines()
assert (root / "usr/lib/aarch64-linux-gnu/libnss_dns.so.2").is_file()
leaked = [
    str(path.relative_to(root))
    for path in root.rglob("*")
    if path.is_file() and b"192.168.151.1" in path.read_bytes()
]
assert not leaked, f"fixture/build nameserver survived in app root: {leaked}"
print("Steam Link runtime DNS closure: PASS (systemd-resolved stub; NSS files+dns; no build resolver)")
PY
if ! env -i PATH=/usr/bin:/bin PYTHONHOME="${runtime_home}" PYTHONDONTWRITEBYTECODE=1 \
    "${runtime_python}" -S "${runtime_helper}" --help \
    >"${scratch}/python-closure.out" 2>"${scratch}/python-closure.err"; then
    cat "${scratch}/python-closure.err" >&2
    echo 'packaged Steam Link fetch helper cannot import its Python stdlib closure' >&2
    exit 1
fi
transitive_module=$(find "${runtime_home}" -path '*/email/parser.py' -print -quit)
test -n "${transitive_module}"
mv "${transitive_module}" "${transitive_module}.missing"
if env -i PATH=/usr/bin:/bin PYTHONHOME="${runtime_home}" PYTHONDONTWRITEBYTECODE=1 \
    "${runtime_python}" -S "${runtime_helper}" --help \
    >"${scratch}/python-negative.out" 2>"${scratch}/python-negative.err"; then
    echo 'packaged Steam Link fetch helper accepted a missing transitive stdlib module' >&2
    exit 1
fi
grep -F "No module named 'email.parser'" "${scratch}/python-negative.err" >/dev/null
mv "${transitive_module}.missing" "${transitive_module}"
echo 'Steam Link packaged Python stdlib closure: PASS (helper imports; missing email.parser refused)'

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
if [ "${PF_APP_REQUIRE_NAMESPACE:-0}" = 1 ]; then
    : "${PF_APP_LAUNCH:?required namespace needs the production helper}"
    : "${PF_APP_POLICY_RENDER:?required namespace needs the production renderer}"
fi
if [ -n "${PF_APP_LAUNCH:-}" ]; then
    namespace_args=(
        "${root}/tests/test-steamlink-rooted-launch.py"
        --manifest "${manifest}" --layout "${PF_TEST_CAPTURE_OVERLAY}"
        --inventory "${rootfs}/usr/share/pocketforge/app-policy/org.pocketforge.steamlink.resources.json"
        --contract "${root}/tests/fixtures/app-policy/platform-capabilities-a133-open.toml"
        --helper "${PF_APP_LAUNCH}" --renderer "${PF_APP_POLICY_RENDER:?}"
    )
    required=()
    if [ "${PF_APP_REQUIRE_NAMESPACE:-0}" = 1 ]; then required=(--require-namespace); fi
    python_command=$(command -v python3)
    "${python_command}" "${namespace_args[@]}" "${required[@]}"

    # Missing tooling is explicit partial coverage, never enforcement evidence.
    # Requiring the namespace turns that same capability absence into a failure.
    mkdir "${scratch}/no-namespace-tools"
    PATH="${scratch}/no-namespace-tools" "${python_command}" "${namespace_args[@]}" \
        >"${scratch}/missing-bwrap.out"
    grep -Fx 'rooted-launch=PARTIAL namespace=UNAVAILABLE reason=bwrap_missing enforcement=unverified' \
        "${scratch}/missing-bwrap.out" >/dev/null
    if PATH="${scratch}/no-namespace-tools" "${python_command}" "${namespace_args[@]}" \
        --require-namespace >"${scratch}/required-bwrap.out"; then
        echo 'required namespace accepted missing bwrap' >&2; exit 1
    else
        [ "$?" -eq 77 ] || exit 1
    fi
    grep -F 'reason=bwrap_missing' "${scratch}/required-bwrap.out" >/dev/null

    # Permission-limited namespace hosts follow the same explicit boundary.
    for permission in \
        'Creating new namespace failed: Operation not permitted' \
        'No permissions to create new namespace' \
        'setting up uid map: Permission denied'; do
        printf '#!/bin/sh\nprintf "%%s\\n" "%s" >&2\nexit 1\n' "${permission}" \
            >"${scratch}/no-namespace-tools/bwrap"
        chmod +x "${scratch}/no-namespace-tools/bwrap"
        PATH="${scratch}/no-namespace-tools" "${python_command}" "${namespace_args[@]}" \
            >"${scratch}/permission-bwrap.out"
        grep -F 'namespace=UNAVAILABLE reason=namespace_permission_required' \
            "${scratch}/permission-bwrap.out" >/dev/null
        if PATH="${scratch}/no-namespace-tools" "${python_command}" "${namespace_args[@]}" \
            --require-namespace >"${scratch}/required-permission.out"; then
            echo 'required namespace accepted missing permission' >&2; exit 1
        else
            [ "$?" -eq 77 ] || exit 1
        fi
    done

    # A present but broken tool is an error even when capability absence is allowed.
    cat >"${scratch}/no-namespace-tools/bwrap" <<'BWRAP'
#!/bin/sh
printf '%s\n' 'synthetic unexpected namespace failure' >&2
exit 1
BWRAP
    chmod +x "${scratch}/no-namespace-tools/bwrap"
    if PATH="${scratch}/no-namespace-tools" "${python_command}" "${namespace_args[@]}" \
        >"${scratch}/broken-bwrap.out" 2>"${scratch}/broken-bwrap.err"; then
        echo 'broken namespace tool was accepted' >&2; exit 1
    fi
    grep -F 'namespace probe failed unexpectedly' "${scratch}/broken-bwrap.err" >/dev/null
    if PATH="${scratch}/no-namespace-tools" "${python_command}" "${namespace_args[@]}" \
        --require-namespace >"${scratch}/required-broken.out" 2>"${scratch}/required-broken.err"; then
        echo 'required namespace accepted a broken tool' >&2; exit 1
    fi
    grep -F 'namespace probe failed unexpectedly' "${scratch}/required-broken.err" >/dev/null
    echo 'Namespace capability controls: PASS optional=partial required=refused missing=checked permission=3 broken=refused-both'

fi
dropin="${rootfs}/etc/systemd/system/pf-app@org.pocketforge.steamlink.service.d/20-runtime-root.conf"
grep -Fx 'BindReadOnlyPaths=/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1' "${dropin}" >/dev/null
grep -Fx 'BindPaths=/var/lib/pocketforge/apps/org.pocketforge.steamlink/state/steamlink-fetch/builds:/opt/pocketforge/apps/org.pocketforge.steamlink/verified-builds:rbind' "${dropin}" >/dev/null
grep -F 'steamlink-ffmpeg59/v1/lib/aarch64-linux-gnu' "${dropin}" >/dev/null
tmpfiles="${rootfs}/usr/lib/tmpfiles.d/pf-steamlink-exec.conf"
grep -Fx 'd /var/lib/pocketforge/apps/org.pocketforge.steamlink/state/steamlink-fetch 0700 gamer gamer -' "${tmpfiles}" >/dev/null
grep -Fx 'd /var/lib/pocketforge/apps/org.pocketforge.steamlink/state/steamlink-fetch/builds 0700 gamer gamer -' "${tmpfiles}" >/dev/null
test -d "${PF_TEST_CAPTURE_OVERLAY}/opt/pocketforge/apps/org.pocketforge.steamlink/verified-builds"
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

for target in /var/lib/pocketforge/apps/org.pocketforge.steamlink \
    /var/cache/pocketforge/apps/org.pocketforge.steamlink /run/pf-app/org.pocketforge.steamlink; do
    if PF_TEST_DROP_BIND_TARGET="${target}" python3 "${bind_checker}" --root "${rootfs}" \
        --unsquashfs "${bin}/unsquashfs" >"${scratch}/negative.out" 2>"${scratch}/negative.err"; then
        echo "missing writable destination accepted: ${target}" >&2; exit 1
    fi
    grep -F "destination missing from RootImage: ${target}" "${scratch}/negative.err" >/dev/null
    if PF_TEST_WRONG_TYPE="${target}" python3 "${bind_checker}" --root "${rootfs}" \
        --unsquashfs "${bin}/unsquashfs" >"${scratch}/negative.out" 2>"${scratch}/negative.err"; then
        echo "wrong writable destination type accepted: ${target}" >&2; exit 1
    fi
    grep -F "destination is not a directory: ${target}" "${scratch}/negative.err" >/dev/null
done
if PF_TEST_WRONG_TYPE="${missing_target}" PF_TEST_TARGET_TYPE=d python3 "${bind_checker}" --root "${rootfs}" \
    --unsquashfs "${bin}/unsquashfs" >"${scratch}/negative.out" 2>"${scratch}/negative.err"; then
    echo 'directory accepted for explicit file bind destination' >&2; exit 1
fi
grep -F "file destination is a directory: ${missing_target}" "${scratch}/negative.err" >/dev/null
if PF_TEST_WRONG_TYPE="${missing_target}" python3 "${bind_checker}" --root "${rootfs}" \
    --unsquashfs "${bin}/unsquashfs" >"${scratch}/negative.out" 2>"${scratch}/negative.err"; then
    # The shim sets this to a file, so the unchanged regular placeholder passes.
    :
else
    echo 'regular explicit bind destination rejected' >&2; exit 1
fi
if PF_TEST_WRONG_TYPE=/var/lib/pocketforge python3 "${bind_checker}" --root "${rootfs}" \
    --unsquashfs "${bin}/unsquashfs" >"${scratch}/negative.out" 2>"${scratch}/negative.err"; then
    echo 'wrong parent type accepted' >&2; exit 1
fi
grep -F 'parent is not a directory: /var/lib/pocketforge' "${scratch}/negative.err" >/dev/null

# Base template plus lexically merged template/instance drop-ins, list resets,
# instance same-name precedence, and a section that must not change Service.
python3 - "${bind_checker}" "${scratch}" <<'PYTEST'
import pathlib, runpy, sys
api = runpy.run_path(sys.argv[1])
units = pathlib.Path(sys.argv[2]) / "merge-units"
units.mkdir()
(units / "pf-app@.service").write_text("[Service]\nRootImage=/root.raw\nReadWritePaths=/base/%i\nStateDirectory=old/%i\n")
for name in ("pf-app@.service.d", "pf-app@sample.service.d"):
    (units / name).mkdir()
(units / "pf-app@.service.d/10-common.conf").write_text("[Service]\nReadWritePaths=/shadowed\n")
(units / "pf-app@sample.service.d/10-common.conf").write_text("[Service]\nReadWritePaths=\nReadWritePaths=/replacement/%i\nStateDirectory=\nStateDirectory=new/%i\n[Unit]\nReadWritePaths=/wrong-section\n")
(units / "pf-app@.service.d/20-later.conf").write_text("[Service]\nReadWritePaths=/later/%i\n")
paths = api["unit_paths"](units)["sample"]
image, values = api["parse_unit"](paths, "sample")
assert image == "/root.raw"
assert values == [("ReadWritePaths", "/replacement/sample"), ("ReadWritePaths", "/later/sample"), ("StateDirectory", "new/sample")], values
(units / "pf-app@sample.service").write_text("[Service]\nRootImage=/instance.raw\n")
assert api["parse_unit"](api["unit_paths"](units)["sample"], "sample")[0] == "/instance.raw"
# Exhaust the shared bind-reset domain across empty/RO/RW/both initial lists,
# either resetting directive, optional later RO/RW entries, and reset placement
# in the base unit or a drop-in. Unrelated writable/directory lists must survive.
from itertools import product
cases = 0
for initial, reset, later, placement in product(range(4), ("BindPaths", "BindReadOnlyPaths", None), (None, "BindPaths", "BindReadOnlyPaths"), ("base", "dropin")):
    if reset is None and later is not None:
        continue
    fixture = units / f"matrix-{cases}"
    fixture.mkdir()
    base = "[Service]\nRootImage=/root.raw\nReadWritePaths=/keep-rw\nStateDirectory=keep-state\n"
    initial_values = []
    for bit, key in ((1, "BindPaths"), (2, "BindReadOnlyPaths")):
        if initial & bit:
            base += f"{key}=/initial-{bit}\n"
            initial_values.append((key, f"/initial-{bit}"))
    tail = f"{reset}=\n" if reset else ""
    if later:
        tail += f"{later}=/later\n"
    if placement == "base":
        base += tail
    else:
        directory = fixture / "pf-app@sample.service.d"
        directory.mkdir()
        (directory / "10-reset.conf").write_text("[Service]\n" + tail)
    (fixture / "pf-app@.service").write_text(base)
    # Ensure instance discovery for the base-only case too.
    (fixture / "pf-app@sample.service.d").mkdir(exist_ok=True)
    actual = api["parse_unit"](api["unit_paths"](fixture)["sample"], "sample")[1]
    expected = [("ReadWritePaths", "/keep-rw"), ("StateDirectory", "keep-state")]
    expected += ([(later, "/later")] if later else []) if reset else initial_values
    assert sorted(actual) == sorted(expected), (initial, reset, later, placement, actual)
    cases += 1
assert cases == 56, cases
print(f"Bind reset property sweep: PASS cases={cases} initial=empty,RO,RW,both reset=RO,RW,none placement=base,dropin later=none,RO,RW unrelated=preserved")
PYTEST

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

bad_packages_rootfs="${scratch}/bad-packages-rootfs"
make_rootfs "${bad_packages_rootfs}"
if PF_TEST_BAD_PACKAGES=1 \
    PF_STEAMLINK_ROOT_BUILDER="${bin}/root-builder" \
    PF_STEAMLINK_ROOT_RENDERER="${bin}/root-renderer" \
    PF_STEAMLINK_POLICY_RENDERER="${bin}/policy-renderer" \
    PF_REAL_ROOT_RENDERER="${root}/scripts/render-app-runtime-root.py" \
    PF_REAL_POLICY_FRAGMENT="${root}/build/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf" \
        "${installer}" "${bad_packages_rootfs}" 20261010T000000Z root \
        >"${scratch}/bad-packages.out" 2>"${scratch}/bad-packages.err"; then
    echo 'root receipt without the Python package closure was accepted' >&2
    exit 1
fi
grep -F 'root metadata package closure differs' "${scratch}/bad-packages.err" >/dev/null
test ! -e "${bad_packages_rootfs}/opt/pocketforge/apps/org.pocketforge.steamlink"

if [ "${PF_TEST_REQUIRE_REAL_SQUASHFS:-0}" = 1 ]; then
    command -v mksquashfs >/dev/null
    command -v unsquashfs >/dev/null
    real_rootfs="${scratch}/real-rootfs"
    make_rootfs "${real_rootfs}"
    PF_TEST_REAL_SQUASHFS=1 \
    PF_STEAMLINK_ROOT_BUILDER="${bin}/root-builder" \
    PF_STEAMLINK_ROOT_RENDERER="${bin}/root-renderer" \
    PF_STEAMLINK_POLICY_RENDERER="${bin}/policy-renderer" \
    PF_REAL_ROOT_RENDERER="${root}/scripts/render-app-runtime-root.py" \
    PF_REAL_POLICY_FRAGMENT="${root}/build/pf-app@org.pocketforge.steamlink.service.d/10-policy.conf" \
        "${installer}" "${real_rootfs}" 20261010T000000Z root
    python3 "${bind_checker}" --root "${real_rootfs}"
    image=$(find "${real_rootfs}/var/lib/pocketforge/app-roots" -name '*.raw')
    python3 - "${image}" <<'PYREAL'
import pathlib, subprocess, sys, tempfile
with tempfile.TemporaryDirectory() as scratch:
    root = pathlib.Path(scratch) / "root"
    subprocess.run(["unsquashfs", "-no-progress", "-d", str(root), sys.argv[1]], check=True, stdout=subprocess.DEVNULL)
    assert (root / "etc/resolv.conf").read_text(encoding="utf-8") == "nameserver 127.0.0.53\n"
    assert "hosts: files dns" in (root / "etc/nsswitch.conf").read_text(encoding="utf-8").splitlines()
    assert (root / "usr/lib/aarch64-linux-gnu/libnss_dns.so.2").is_file()
    assert not any(
        path.is_file() and b"192.168.151.1" in path.read_bytes()
        for path in root.rglob("*")
    )
    for relative in (
        "var/lib/pocketforge/apps/org.pocketforge.steamlink",
        "var/cache/pocketforge/apps/org.pocketforge.steamlink",
        "run/pf-app/org.pocketforge.steamlink",
        "opt/pocketforge/apps/org.pocketforge.steamlink/verified-builds",
    ):
        target = root / relative
        assert target.is_dir() and not list(target.iterdir()), target
print("Steam Link real SquashFS producer: PASS (runtime DNS/NSS closure; no build resolver; four empty destinations)")
PYREAL
fi

echo 'Steam Link first-run root install: PASS (positive and negative controls)'
