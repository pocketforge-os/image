#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
checker="${root}/scripts/check-runtime-path-producers.py"
inventory="${root}/build/app-policy-a133-open-v1.json"
builder="${root}/scripts/build-rootfs.sh"
hermetic_workflow="${root}/.github/workflows/hermetic-tests.yml"
pair_workflow="${root}/.github/workflows/app-policy-pair.yml"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/runtime-path-producers.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

fixture="${scratch}/root"
mkdir -p \
    "${fixture}/etc/systemd/system" \
    "${fixture}/usr/lib/tmpfiles.d" \
    "${fixture}/usr/share/pocketforge" \
    "${fixture}/opt/static"
cp "${root}/rootfs-overlay/usr/share/pocketforge/runtime-path-producers.json" \
    "${fixture}/usr/share/pocketforge/runtime-path-producers.json"
printf '[Service]\nExecStart=/usr/bin/pf-prefsd\n' \
    > "${fixture}/etc/systemd/system/pf-prefsd.service"
printf '[Socket]\nListenStream=/run/dbus/system_bus_socket\n' \
    > "${fixture}/etc/systemd/system/dbus.socket"
printf 'd /run/from-tmpfiles 0755 root root -\n' \
    > "${fixture}/usr/lib/tmpfiles.d/fixture.conf"

grep -F 'tests/test-runtime-path-producers.sh' "${hermetic_workflow}" >/dev/null
grep -F 'tests/test-runtime-path-producers.sh' "${pair_workflow}" >/dev/null
grep -F '/work/src/scripts/check-runtime-path-producers.py' "${builder}" >/dev/null
grep -F 'rootfs-overlay/usr/share/pocketforge/runtime-path-producers.json' \
    "${builder}" >/dev/null

# Positive control in the RED invocation: kernel-produced device resources do
# not require a build-time producer record.
cat > "${scratch}/devices-only.json" <<'EOF'
{"resources":{"audio-devices":["/dev/snd/controlC0"],"display-devices":["/dev/fb0"]}}
EOF
"${checker}" \
    --root "${fixture}" \
    --inventory "${scratch}/devices-only.json" \
    --producers "${fixture}/usr/share/pocketforge/runtime-path-producers.json"

# RED on the pre-fix inventory: audio-0, wayland-0 and environment have no
# producer in the default framebuffer profile. GREEN is the same inventory
# after it contains only direct device routes.
"${checker}" \
    --root "${fixture}" \
    --inventory "${inventory}" \
    --producers "${fixture}/usr/share/pocketforge/runtime-path-producers.json"

printf '[Service]\nExecStart=/bin/true\n' \
    > "${fixture}/etc/systemd/system/fixture-producer.service"
printf '[Service]\nExecStart=/bin/true\n' \
    > "${fixture}/etc/systemd/system/pocketforge-session-publisher.service"

cat > "${scratch}/all-producers.json" <<'EOF'
{
  "schema":"pocketforge.runtime-path-producers/v1",
  "producers":{
    "/run/generated/bind":{"unit":"fixture-producer.service"},
    "/run/generated/ro":{"unit":"fixture-producer.service"},
    "/run/generated/inaccessible":{"unit":"fixture-producer.service"},
    "/run/generated/readonly":{"unit":"fixture-producer.service"},
    "/run/generated/readwrite":{"unit":"fixture-producer.service"},
    "/run/pocketforge/session/environment":{"unit":"pocketforge-session-publisher.service"},
    "/run/pocketforge/session/wayland-0":{"unit":"pocketforge-session-publisher.service"}
  },
  "optional":[]
}
EOF
cat > "${scratch}/pf-app@org.pocketforge.fixture.service" <<'EOF'
[Service]
StateDirectory=pocketforge/apps/%i
CacheDirectory=pocketforge/apps/%i
BindPaths=/run/generated/bind:/inside/bind /dev/fb0
BindReadOnlyPaths=/run/generated/ro:/inside/ro /opt/static
InaccessiblePaths=/run/generated/inaccessible -/run/generated/optional
ReadOnlyPaths=/run/generated/readonly /run/from-tmpfiles
ReadWritePaths=/run/generated/readwrite /var/lib/pocketforge/apps/%i /var/cache/pocketforge/apps/%i
InaccessiblePaths=/run/dbus/system_bus_socket
EOF
"${checker}" \
    --root "${fixture}" \
    --unit "${scratch}/pf-app@org.pocketforge.fixture.service" \
    --producers "${scratch}/all-producers.json"

# Every non-optional path directive is enforced and reports its consumer.
for missing in bind ro inaccessible readonly readwrite; do
    python3 - "${scratch}/all-producers.json" "${scratch}/missing-${missing}.json" "$missing" <<'PY'
import json
from pathlib import Path
import sys

source = Path(sys.argv[1])
output = Path(sys.argv[2])
missing = sys.argv[3]
data = json.loads(source.read_text(encoding="utf-8"))
del data["producers"][f"/run/generated/{missing}"]
output.write_text(json.dumps(data), encoding="utf-8")
PY
    if "${checker}" --root "${fixture}" \
        --unit "${scratch}/pf-app@org.pocketforge.fixture.service" \
        --producers "${scratch}/missing-${missing}.json" \
        > "${scratch}/missing-${missing}.out" 2>&1; then
        fail "audit accepted missing ${missing} producer"
    fi
    grep -F "missing producer: /run/generated/${missing}: consumer=" \
        "${scratch}/missing-${missing}.out" >/dev/null
done

# A record is not enough: its named unit must ship in the audited rootfs.
python3 - "${scratch}/all-producers.json" "${scratch}/missing-unit.json" <<'PY'
import json
from pathlib import Path
import sys

source, output = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8"))
data["producers"]["/run/generated/bind"]["unit"] = "absent.service"
output.write_text(json.dumps(data), encoding="utf-8")
PY
if "${checker}" --root "${fixture}" \
    --unit "${scratch}/pf-app@org.pocketforge.fixture.service" \
    --producers "${scratch}/missing-unit.json" > "${scratch}/missing-unit.out" 2>&1; then
    fail "audit accepted an unshipped named producer"
fi
grep -F 'producer unit missing: /run/generated/bind: absent.service' \
    "${scratch}/missing-unit.out" >/dev/null

# The schema cannot waive a required inventory or unit source: optionality is
# expressed only by a '-' prefix on the systemd path itself.
python3 - "${scratch}/all-producers.json" "${scratch}/optional-exemption.json" <<'PY'
import json
from pathlib import Path
import sys

source, output = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8"))
data["optional"] = ["/run/generated/bind"]
output.write_text(json.dumps(data), encoding="utf-8")
PY
if "${checker}" --root "${fixture}" \
    --unit "${scratch}/pf-app@org.pocketforge.fixture.service" \
    --producers "${scratch}/optional-exemption.json" \
    > "${scratch}/optional-exemption.out" 2>&1; then
    fail "audit accepted a manifest-level optional exemption"
fi
grep -F "optional producer exemptions are unsupported" \
    "${scratch}/optional-exemption.out" >/dev/null

# Steam Link's session route stays valid when sess's publisher ships and names
# both ABI paths. Removing either declaration fails closed.
cat > "${scratch}/session-route.json" <<'EOF'
{"resources":{"display-sockets":["/run/pocketforge/session/wayland-0"],"session-environment":["/run/pocketforge/session/environment"]}}
EOF
"${checker}" \
    --root "${fixture}" \
    --inventory "${scratch}/session-route.json" \
    --producers "${scratch}/all-producers.json"
python3 - "${scratch}/all-producers.json" "${scratch}/missing-session.json" <<'PY'
import json
from pathlib import Path
import sys

source, output = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8"))
del data["producers"]["/run/pocketforge/session/environment"]
output.write_text(json.dumps(data), encoding="utf-8")
PY
if "${checker}" --root "${fixture}" \
    --inventory "${scratch}/session-route.json" \
    --producers "${scratch}/missing-session.json" \
    > "${scratch}/missing-session.out" 2>&1; then
    fail "audit accepted a partial session producer"
fi
grep -F 'missing producer: /run/pocketforge/session/environment' \
    "${scratch}/missing-session.out" >/dev/null

echo 'PASS: runtime resource and systemd path producers are complete'
