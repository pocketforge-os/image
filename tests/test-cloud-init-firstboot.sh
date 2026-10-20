#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${repo_dir}/build/Dockerfile.pf"
builder="${repo_dir}/scripts/build-rootfs.sh"
fixture="${repo_dir}/tests/fixtures/cloud-init-firstboot"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-cloud-init-firstboot.XXXXXX")"
trap 'find "${scratch}" -mindepth 1 -delete; rmdir "${scratch}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The image build owns the source-to-package boundary. The receipt check keeps a
# mismatched named context from being labeled with the requested revision, and
# the behavioral fixture runs before the package can enter the rootfs.
grep -Fq 'COPY --from=cloud-init-src . /work/src' "${dockerfile}" \
    || fail "cloud-init source context is not consumed"
grep -Fq '[ "$(cat /work/src/.pf-source-revision)" = "${PF_CLOUD_INIT_SHA}" ]' "${dockerfile}" \
    || fail "cloud-init source receipt is not checked"
grep -Fq 'PF_CLOUD_INIT_TREE=/work/src /work/image/tests/test-cloud-init-firstboot.sh' "${dockerfile}" \
    || fail "image-owned cloud-init fixture is not run in the package stage"
grep -Fq 'cloud-init-pocketforge.deb' "${dockerfile}" \
    || fail "PocketForge cloud-init package is not emitted"
grep -Fq 'COPY --from=cloud-init /out /work/cloud-init' "${dockerfile}" \
    || fail "rootfs does not consume the cloud-init package stage"
grep -Fq 'PF_CLOUD_INIT_SHA="${PF_CLOUD_INIT_SHA}"' "${dockerfile}" \
    || fail "cloud-init revision does not reach rootfs provenance"
grep -Fq "printf 'cloud_init=%s" "${repo_dir}/scripts/generate-build-id.sh" \
    || fail "cloud-init revision is absent from the image build-id"

grep -Fq 'CLOUD_INIT_DIR="${CLOUD_INIT_DIR:-/work/cloud-init}"' "${builder}" \
    || fail "rootfs builder has no cloud-init package input"
grep -Fq -- '--include="${CLOUD_INIT_DEB}"' "${builder}" \
    || fail "cloud-init package is not the first local package"
for package in netcat-openbsd procps python3 python3-configobj python3-debconf \
    python3-jinja2 python3-jsonpatch python3-jsonschema python3-oauthlib \
    python3-requests python3-yaml; do
    grep -Fxq "${package}" "${repo_dir}/rootfs-packages.txt" \
        || fail "cloud-init runtime dependency is absent: ${package}"
done

# The published image is never pre-seeded. Active seed material is injected by
# node-recover only after whole-image verification; this repo may ship examples.
if rg -n 'id=wifi|PF_WIFI_SHA|generate-wifi-config|authorized_keys\.d' \
    "${dockerfile}" "${repo_dir}/Makefile" "${builder}" >"${scratch}/legacy.out"; then
    cat "${scratch}/legacy.out" >&2
    fail "legacy build-time Wi-Fi or baked SSH-key path remains"
fi
examples_only() {
    local root="$1"
    ! find "${root}" -maxdepth 1 -type f ! -name '*.example' -print -quit \
        | grep -q .
}
examples_only "${repo_dir}/boards/tsp/boot-resource" \
    || fail "active seed found in the tracked POCKETFORGE FAT input"

# RED-first controls for the published-image gate. Both legacy wifi.txt and a
# standards-shaped active seed must turn an otherwise accepted example tree red.
mkdir -p "${scratch}/no-seed-wifi" "${scratch}/no-seed-cloud"
cp -a "${repo_dir}/boards/tsp/boot-resource/." "${scratch}/no-seed-wifi/"
printf 'SSID=planted\nPSK=not-a-secret\n' >"${scratch}/no-seed-wifi/wifi.txt"
if examples_only "${scratch}/no-seed-wifi"; then
    fail "no-seed gate accepted a planted wifi.txt"
fi
cp -a "${repo_dir}/boards/tsp/boot-resource/." "${scratch}/no-seed-cloud/"
cp "${fixture}/user-data" "${scratch}/no-seed-cloud/user-data"
if examples_only "${scratch}/no-seed-cloud"; then
    fail "no-seed gate accepted a planted NoCloud seed"
fi
grep -Fq 'for f in "${BOOT_RES_DIR}"/*.example' \
    "${repo_dir}/scripts/build-sd-image.sh" \
    || fail "FAT assembly is not restricted to example configuration"

grep -Fq 'fmask=0177,dmask=0077' "${builder}" \
    || fail "POCKETFORGE FAT is not root-only"
grep -Fq 'LoadCredentialEncrypted=wpa-psks:/etc/credstore.encrypted/wpa-psks' \
    "${repo_dir}/rootfs-overlay/etc/systemd/system/wpa_supplicant@wlan0.service.d/pocketforge-firstboot.conf" \
    || fail "wpa_supplicant does not load the encrypted PMK credential"
grep -Fq 'After=cloud-init-local.service' \
    "${repo_dir}/rootfs-overlay/etc/systemd/system/wpa_supplicant@wlan0.service.d/pocketforge-firstboot.conf" \
    || fail "wpa_supplicant is not ordered after seed installation"

# The runtime generator owns this artifact. The overlay copy is the pinned
# pre-frA fallback and must stay semantically identical when a runtime-stage
# generator output is present.
schema="${repo_dir}/rootfs-overlay/usr/share/pocketforge/prefs.schema.json"
[ -s "${schema}" ] || fail "pinned pf-prefs seed schema is missing"
schema_xkb_checker="${repo_dir}/scripts/verify-prefs-schema-xkb.py"
[ -x "${schema_xkb_checker}" ] || fail "pf-prefs schema XKB checker is missing"
grep -Fq 'verify-prefs-schema-xkb.py' "${builder}" \
    || fail "rootfs builder does not validate the schema against shipped XKB"
grep -Fq '/usr/share/X11/xkb/rules/evdev.xml' "${builder}" \
    || fail "rootfs builder does not use the installed evdev.xml"
cat >"${scratch}/evdev.xml" <<'XML'
<?xml version="1.0"?>
<xkbConfigRegistry version="1.1">
  <layoutList>
    <layout>
      <configItem><name>us</name></configItem>
      <variantList>
        <variant><configItem><name>dvorak</name></configItem></variant>
      </variantList>
    </layout>
  </layoutList>
</xkbConfigRegistry>
XML
cat >"${scratch}/schema.json" <<'JSON'
{
  "properties": {"keyboardLayout": {"enum": ["us", "us(dvorak)"]}}
}
JSON
python3 "${schema_xkb_checker}" "${scratch}/evdev.xml" "${scratch}/schema.json" \
    || fail "schema/XKB compatibility positive control failed"
sed 's/us(dvorak)/us(qwerty)/' "${scratch}/schema.json" >"${scratch}/bad-schema.json"
if python3 "${schema_xkb_checker}" "${scratch}/evdev.xml" "${scratch}/bad-schema.json"; then
    fail "schema/XKB compatibility negative control accepted an unknown variant"
fi
grep -Fq 'PREFS_SCHEMA_RUNTIME' "${builder}" \
    || fail "rootfs builder has no runtime-generated schema input"
grep -Fq 'PREFS_SCHEMA_FALLBACK' "${builder}" \
    || fail "rootfs builder has no pinned schema fallback"
grep -Fq '/usr/share/pocketforge/prefs.schema.json' "${builder}" \
    || fail "rootfs builder does not install the contract schema path"
python3 - "${schema}" "${PF_TEST_RUNTIME_SCHEMA:-}" <<'PY'
import json
import sys
from pathlib import Path

fallback = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert fallback["type"] == "object"
assert fallback["additionalProperties"] is False
assert fallback["$id"] == "pocketforge-prefs.schema.json"
properties = fallback["properties"]
expected = {
    "appearance": ("string", None),
    "textScale": ("string", None),
    "keyboardLayout": ("string", None),
    "highContrast": ("boolean", None),
    "reduceFlashing": ("boolean", None),
    "reduceMotion": ("boolean", None),
    "hapticsEnabled": ("boolean", None),
    "monoAudio": ("boolean", None),
    "brightness": ("integer", (0, 100)),
    "volumeSpeaker": ("integer", (0, 100)),
    "volumeHeadphones": ("integer", (0, 100)),
    "muted": ("boolean", None),
    "auto_rotate": ("boolean", None),
    "user_rotation": ("string", None),
}
assert set(properties) == set(expected), sorted(set(properties) ^ set(expected))
for key, (kind, bounds) in expected.items():
    assert properties[key]["type"] == kind, key
    if bounds:
        assert (properties[key]["minimum"], properties[key]["maximum"]) == bounds, key
    assert "default" in properties[key], key

runtime = sys.argv[2]
if runtime:
    runtime_value = json.loads(Path(runtime).read_text(encoding="utf-8"))
    assert runtime_value == fallback, "runtime-generated schema drifted from pinned fallback"
PY

sshd_config="${repo_dir}/rootfs-overlay/etc/ssh/sshd_config.d/00-pocketforge.conf"
for directive in \
    'PermitRootLogin no' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'AuthenticationMethods publickey' \
    'AllowUsers gamer'; do
    grep -Fxq "${directive}" "${sshd_config}" \
        || fail "missing sshd directive: ${directive}"
done
ssh_dropin="${repo_dir}/rootfs-overlay/etc/systemd/system/ssh.service.d/pocketforge-firstboot.conf"
grep -Fq 'After=cloud-init-network.service ssh-keygen-firstboot.service' "${ssh_dropin}" \
    || fail "ssh is not ordered after accepted user-data"
grep -Fq 'ConditionPathExists=/home/gamer/.ssh/authorized_keys' "${ssh_dropin}" \
    || fail "ssh can listen without an accepted gamer key"

graph_fixture="${scratch}/cloud-init-unit-graph"
mkdir -p "${graph_fixture}/pf-prefsd.service.d"
cp "${repo_dir}/rootfs-overlay/etc/systemd/system/pf-kbd-layout-env.service" \
    "${graph_fixture}/pf-kbd-layout-env.service"
cp "${repo_dir}/rootfs-overlay/etc/systemd/system/pf-shell-selected.service" \
    "${graph_fixture}/pf-shell-selected.service"
cat >"${graph_fixture}/pf-prefsd.service" <<'EOF'
[Unit]
Description=fixture pf-prefsd
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/true
EOF
cp "${repo_dir}/rootfs-overlay/etc/systemd/system/pf-prefsd.service.d/10-cloud-init-firstboot.conf" \
    "${graph_fixture}/pf-prefsd.service.d/10-cloud-init-firstboot.conf"

assert_cloud_init_first() {
    local root="$1" unit="$2"
    local combined="${root}/${unit}.combined"
    {
        cat "${root}/${unit}"
        if [ -d "${root}/${unit}.d" ]; then
            cat "${root}/${unit}.d"/*
        fi
    } >"${combined}"
    grep -Eq '^Wants=(.*[[:space:]])?cloud-config\.service([[:space:]]|$)' "${combined}" \
        || return 1
    grep -Eq '^After=(.*[[:space:]])?cloud-config\.service([[:space:]]|$)' "${combined}" \
        || return 1
    ! grep -Eq '^Requires=(.*[[:space:]])?cloud-config\.service([[:space:]]|$)' "${combined}"
}

for unit in pf-prefsd.service pf-kbd-layout-env.service pf-shell-selected.service; do
    assert_cloud_init_first "${graph_fixture}" "${unit}" \
        || fail "${unit} is not ordered after cloud-config.service fail-open"
done
grep -Fxq 'Restart=on-failure' \
    "${repo_dir}/rootfs-overlay/etc/systemd/system/pf-shell-selected.service" \
    || fail "pf-shell-selected lost its restart-on-failure policy"

# Negative control: changing Wants= to Requires= must be rejected by the same
# unit-graph assertion, proving failed/missing cloud-init remains non-blocking.
negative_graph="${scratch}/cloud-init-unit-graph-negative"
cp -a "${graph_fixture}" "${negative_graph}"
sed -i 's/^Wants=cloud-config\.service$/Requires=cloud-config.service/' \
    "${negative_graph}/pf-prefsd.service.d/10-cloud-init-firstboot.conf"
if assert_cloud_init_first "${negative_graph}" pf-prefsd.service; then
    fail "negative control accepted Requires=cloud-config.service"
fi

grep -Fq '10-cloud-init-firstboot.conf' "${builder}" \
    || fail "rootfs builder does not install pf-prefsd cloud-init ordering drop-in"

# In the package stage PF_CLOUD_INIT_TREE points at the exact source context.
# The static half above still runs in image-only PR CI, while a real image build
# exercises the source-owned validator and installer before packaging.
if [[ -z ${PF_CLOUD_INIT_TREE:-} ]]; then
    echo 'cloud-init-firstboot-test=PASS mode=integration-contract behavioral=deferred-to-package-stage'
    exit 0
fi
[[ -f "${PF_CLOUD_INIT_TREE}/cloudinit/pocketforge.py" ]] \
    || fail "PF_CLOUD_INIT_TREE is not a cloud-init source tree"

cp -a "${fixture}/." "${scratch}/fixture"
mkdir -p "${scratch}/bin"
cat >"${scratch}/bin/systemd-creds" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
payload="$(cat)"
first="${payload%%$'\n'*}"
[[ ${first} == net00=* ]] || exit 64
[[ ${payload} == *$'\n'pw00=* ]] || exit 65
[[ ${payload} == *$'\n'net01=* ]] || exit 66
[[ ${payload} == *$'\n'pw01=* ]] || exit 67
printf 'test-encrypted-credential\n' >"${destination}"
EOF
chmod 0755 "${scratch}/bin/systemd-creds"

PYTHONDONTWRITEBYTECODE=1 \
PATH="${scratch}/bin:${PATH}" \
PF_CLOUD_INIT_TREE="${PF_CLOUD_INIT_TREE}" \
PF_TEST_FIXTURE="${scratch}/fixture" \
PF_TEST_SCRATCH="${scratch}" \
python3 - <<'PY'
import os
import shutil
import stat
import sys
from pathlib import Path

source = Path(os.environ["PF_CLOUD_INIT_TREE"])
fixture = Path(os.environ["PF_TEST_FIXTURE"])
scratch = Path(os.environ["PF_TEST_SCRATCH"])
sys.path.insert(0, str(source))

from cloudinit import pocketforge  # noqa: E402


def seed_dir(name: str, *, user_data: str = "user-data", network: str = "network-config") -> Path:
    root = scratch / name
    root.mkdir()
    shutil.copyfile(fixture / user_data, root / "user-data")
    shutil.copyfile(fixture / network, root / "network-config")
    shutil.copyfile(fixture / "meta-data", root / "meta-data")
    return root


valid = seed_dir("valid")
target = scratch / "valid-target"
target.mkdir()
seed = pocketforge.load_seed(valid)
redacted = pocketforge.install_wifi(seed, target)
wpa = target / "etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
credential = target / "etc/credstore.encrypted/wpa-psks"
assert wpa.is_file() and credential.is_file()
assert stat.S_IMODE(wpa.stat().st_mode) == 0o600
assert stat.S_IMODE(credential.stat().st_mode) == 0o600
assert "psk=ext:net00" in wpa.read_text(encoding="utf-8")
assert "correct horse" not in wpa.read_text(encoding="utf-8")
rendered = wpa.read_text(encoding="utf-8")
access_points = redacted["wifis"]["wlan0"]["access-points"]
assert access_points["Bench Network"] == {"password": "ext:net00"}
assert access_points["Cellar Network"] == {"hidden": True, "password": "ext:net01"}
assert "psk=ext:net01" in rendered
assert rendered.count("key_mgmt=WPA-PSK WPA-PSK-SHA256\n") == 2
assert rendered.count("ieee80211w=1") == 2
assert rendered.count("scan_ssid=1") == 1
assert "SAE" not in rendered and "sae_password" not in rendered
blocks = {chunk.split("\n")[1]: chunk for chunk in rendered.split("network={")[1:]}
bench = blocks[[key for key in blocks if key.endswith("42656e6368204e6574776f726b")][0]]
cellar = blocks[[key for key in blocks if key.endswith("43656c6c6172204e6574776f726b")][0]]
assert "scan_ssid=1" not in bench
assert "scan_ssid=1" in cellar
for path in sorted(target.rglob("*")):
    if path.is_file():
        blob = path.read_bytes()
        assert b"correct horse battery staple" not in blob, path
        assert b"cellar horse battery staple" not in blob, path
        assert b"Y29ycmVjdCBob3JzZSBiYXR0ZXJ5IHN0YXBsZQ==" not in blob, path

finalized = seed_dir("finalize")
pocketforge.finalize_persistent_seed(finalized, cache_paths=[])
consumed_text = (finalized / "network-config").read_text(encoding="utf-8")
for path in sorted(finalized.rglob("*")):
    if path.is_file():
        blob = path.read_bytes()
        assert b"correct horse battery staple" not in blob, path
        assert b"cellar horse battery staple" not in blob, path
        assert b"Y29ycmVjdCBob3JzZSBiYXR0ZXJ5IHN0YXBsZQ==" not in blob, path
assert "pocketforge_seed_consumed: true" in consumed_text
assert "hidden: true" in consumed_text
reloaded = pocketforge.load_seed(finalized)
assert reloaded.network_config_consumed is True
rerendered = pocketforge.render_wpa_config(reloaded.network_config)
assert rerendered.content.count("scan_ssid=1") == 1
assert rerendered.content.count("key_mgmt=WPA-PSK WPA-PSK-SHA256\n") == 2
assert pocketforge.install_wifi(reloaded, scratch / "consumed-target") == reloaded.network_config

for label, user_data, network, expected in (
    ("ssh-pwauth", "refused-ssh-pwauth-user-data", "network-config", "ssh_pwauth"),
    ("unknown-network", "user-data", "refused-unknown-network-config", "surprise"),
):
    root = seed_dir(label, user_data=user_data, network=network)
    refused_target = scratch / f"{label}-target"
    refused_target.mkdir()
    sentinel = refused_target / "sentinel"
    sentinel.write_bytes(b"unchanged")
    before = {path.relative_to(refused_target): path.read_bytes() for path in refused_target.rglob("*") if path.is_file()}
    try:
        refused = pocketforge.load_seed(root)
        pocketforge.install_wifi(refused, refused_target)
    except pocketforge.SeedRefused as error:
        assert expected in str(error)
    else:
        raise AssertionError(f"{label}: malformed seed was accepted")
    after = {path.relative_to(refused_target): path.read_bytes() for path in refused_target.rglob("*") if path.is_file()}
    assert after == before, f"{label}: target changed before full validation"

print("cloud-init-firstboot-behavior=PASS valid=wifi+ssh-key hidden-only-probe=yes boot-akm=WPA-PSK+WPA-PSK-SHA256+pmf sealed=net00+pw00+net01+pw01 plaintext-in-target=0 consumed-seed-renders=yes negative=ssh_pwauth+unknown-network writes-before-refusal=0")
PY

echo 'cloud-init-firstboot-test=PASS mode=package-stage behavioral=executed'
