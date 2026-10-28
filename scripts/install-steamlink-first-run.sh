#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: install-steamlink-first-run.sh ROOTFS SNAPSHOT ROOT-BUILDER-MODE" >&2
    exit 2
fi

rootfs=$1
snapshot=$2
builder_mode=$3
src=$(cd "$(dirname "$0")/.." && pwd)
app_id=org.pocketforge.steamlink
app_source="${src}/apps/steamlink"
root_builder=${PF_STEAMLINK_ROOT_BUILDER:-${src}/scripts/build-debian-app-root.sh}
root_renderer=${PF_STEAMLINK_ROOT_RENDERER:-${src}/scripts/render-app-runtime-root.py}
policy_renderer=${PF_STEAMLINK_POLICY_RENDERER:-${RUNTIME_DIR:-/work/runtime}/build-tools/pf-app-policy-render}
platform_store="${rootfs}/usr/lib/pocketforge/platform-runtimes/pocketforge-bookworm-aarch64"
ffmpeg_runtime="${rootfs}/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1"

for path in "${rootfs}" "${app_source}" "${root_builder}" "${root_renderer}" \
    "${policy_renderer}" "${platform_store}" "${ffmpeg_runtime}"; do
    [ -e "${path}" ] || { echo "steamlink-first-run: missing path: ${path}" >&2; exit 66; }
done
case "${builder_mode}" in root|unshare|fakechroot) ;; *) exit 64 ;; esac

work=$(mktemp -d "${TMPDIR:-/tmp}/pf-steamlink-first-run.XXXXXX")
cleanup() {
    find "${work}" -mindepth 1 -delete
    rmdir "${work}"
}
trap cleanup EXIT HUP INT TERM

app_root_overlay="${work}/overlay"
app_overlay="${app_root_overlay}/opt/pocketforge/apps/${app_id}"
mkdir -p "${app_overlay}"
install -m 0755 "${app_source}/pf-launch" "${app_overlay}/pf-launch"
install -m 0755 "${app_source}/steamlink-fetch.py" "${app_overlay}/steamlink-fetch.py"
install -m 0644 "${app_source}/valve-steamlink-release-key.asc" \
    "${app_overlay}/valve-steamlink-release-key.asc"

root_output="${work}/root-output"
"${root_builder}" \
    --distribution debian-13 \
    --architecture arm64 \
    --snapshot "${snapshot}" \
    --mode "${builder_mode}" \
    --package python3-minimal \
    --package gnupg \
    --overlay "${app_root_overlay}" \
    --output "${root_output}"

root_digest=$(sha256sum "${root_output}/root.raw" | awk '{print $1}')
[ "${#root_digest}" -eq 64 ] || { echo "steamlink-first-run: invalid root digest" >&2; exit 65; }
python3 - "${root_output}/root.metadata.json" "${root_digest}" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
expected = {"schema_version": 1, "distribution": "debian-13", "suite": "trixie", "architecture": "arm64", "sha256": sys.argv[2]}
for key, wanted in expected.items():
    if value.get(key) != wanted:
        raise SystemExit(f"steamlink-first-run: root metadata {key} differs")
PY

platforms=$(find "${platform_store}" -mindepth 1 -maxdepth 1 -type d -name 'sha256-*' -printf '%f\n')
[ "$(printf '%s\n' "${platforms}" | grep -c .)" -eq 1 ] || {
    echo "steamlink-first-run: expected one app platform runtime" >&2
    exit 65
}
platform_digest=${platforms#sha256-}
[ "${#platform_digest}" -eq 64 ] || { echo "steamlink-first-run: invalid platform digest" >&2; exit 65; }
[ "$(cat "${platform_store}/${platforms}/.manifest-sha256")" = "${platform_digest}" ] || {
    echo "steamlink-first-run: platform runtime identity differs" >&2
    exit 65
}

manifest="${work}/app.toml"
inventory="${work}/inventory.json"
python3 - "${app_source}/app.toml" "${manifest}" "${root_digest}" \
    "${platform_digest}" "${src}/build/app-policy-a133-open-g1-v1.json" "${inventory}" <<'PY'
import json, pathlib, sys
source, output, root_digest, platform_digest, inventory_source, inventory_output = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
sentinel = "sha256:" + "0" * 64
if text.count(sentinel) != 2:
    raise SystemExit("steamlink-first-run: descriptor digest sentinels differ")
text = text.replace(sentinel, "sha256:" + root_digest, 1)
text = text.replace(sentinel, "sha256:" + platform_digest, 1)
pathlib.Path(output).write_text(text, encoding="utf-8")
inventory = json.loads(pathlib.Path(inventory_source).read_text(encoding="utf-8"))
inventory.update({
    "schema_version": 1,
    "platform_runtime": "pocketforge/bookworm-aarch64",
    "platform_runtime_abi": "1",
    "platform_runtime_version": "sha256:" + platform_digest,
})
pathlib.Path(inventory_output).write_text(json.dumps(inventory, sort_keys=True), encoding="utf-8")
PY

root_store="${rootfs}/var/lib/pocketforge/app-roots/${app_id}"
app_host="${rootfs}/opt/pocketforge/apps/${app_id}"
dropin="${rootfs}/etc/systemd/system/pf-app@${app_id}.service.d/20-runtime-root.conf"
mkdir -p "${root_store}" "${app_host}"
install -m 0644 "${root_output}/root.raw" "${root_store}/sha256-${root_digest}.raw"
install -m 0644 "${root_output}/root.metadata.json" \
    "${root_store}/sha256-${root_digest}.metadata.json"
install -m 0644 "${manifest}" "${app_host}/app.toml"

# The root renderer recompiles the capability policy into this exact-instance
# fragment. Remove the legacy host-root copy so list-valued systemd directives
# are not applied twice.
rm -f "${rootfs}/etc/systemd/system/pf-app@${app_id}.service.d/10-policy.conf"

python3 "${root_renderer}" \
    --manifest "${app_host}/app.toml" \
    --inventory "${inventory}" \
    --platform-contract "${rootfs}/usr/share/pocketforge/platform-capabilities.toml" \
    --policy-renderer "${policy_renderer}" \
    --policy-output "${rootfs}/usr/share/pocketforge/app-policy/${app_id}.resources.json" \
    --output "${dropin}" \
    --app-root-store "${rootfs}/var/lib/pocketforge/app-roots" \
    --platform-runtime-store "${rootfs}/usr/lib/pocketforge/platform-runtimes"

cat >>"${dropin}" <<'EOF'
# Steam Link's sealed FFmpeg59 ABI is separate from the graphics platform slice.
BindReadOnlyPaths=/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1
Environment="LD_LIBRARY_PATH=/usr/lib/pocketforge/platform-runtimes/steamlink-ffmpeg59/v1/lib/aarch64-linux-gnu:/run/pocketforge/platform-runtime/usr/local/lib:/run/pocketforge/platform-runtime/usr/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu"
EOF

printf 'steamlink-first-run=PASS root=sha256:%s platform=sha256:%s\n' \
    "${root_digest}" "${platform_digest}"
