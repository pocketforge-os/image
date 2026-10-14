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
    "/run/generated/dropin":{"unit":"fixture-producer.service"},
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

# Only tmpfiles directives that create the exact path are producers. Removal,
# exclusion, metadata-only and write-if-present entries must not make a
# required policy source pass merely by naming it.
for nonproducer_type in r R x X z Z t T h H a A w 'w+'; do
    printf '%s /run/from-tmpfiles - - - - -\n' "${nonproducer_type}" \
        > "${fixture}/usr/lib/tmpfiles.d/fixture.conf"
    if "${checker}" \
        --root "${fixture}" \
        --unit "${scratch}/pf-app@org.pocketforge.fixture.service" \
        --producers "${scratch}/all-producers.json" \
        > "${scratch}/tmpfiles-${nonproducer_type//+/plus}.out" 2>&1; then
        fail "audit accepted tmpfiles ${nonproducer_type} as a producer"
    fi
    grep -F 'missing producer: /run/from-tmpfiles: consumer=' \
        "${scratch}/tmpfiles-${nonproducer_type//+/plus}.out" >/dev/null
done

cat > "${scratch}/wildcard-inventory.json" <<'EOF'
{"resources":{"display-sockets":["/run/from-*"]}}
EOF
printf 'd /run/from-* 0755 root root -\n' \
    > "${fixture}/usr/lib/tmpfiles.d/fixture.conf"
if "${checker}" \
    --root "${fixture}" \
    --inventory "${scratch}/wildcard-inventory.json" \
    --producers "${scratch}/all-producers.json" \
    > "${scratch}/tmpfiles-wildcard.out" 2>&1; then
    fail "audit accepted a wildcard tmpfiles path as an exact producer"
fi
grep -F 'missing producer: /run/from-*: consumer=' \
    "${scratch}/tmpfiles-wildcard.out" >/dev/null

# A manifest's named tmpfiles file is still evidence, not an exemption: that
# file must contain an exact creation-capable declaration for the named path.
cat > "${scratch}/named-tmpfiles-inventory.json" <<'EOF'
{"resources":{"display-sockets":["/run/from-named-tmpfiles"]}}
EOF
cat > "${scratch}/named-tmpfiles-producers.json" <<'EOF'
{"schema":"pocketforge.runtime-path-producers/v1","producers":{"/run/from-named-tmpfiles":{"tmpfiles":"fixture.conf"}},"optional":[]}
EOF
printf 'r /run/from-named-tmpfiles - - - - -\n' \
    > "${fixture}/usr/lib/tmpfiles.d/fixture.conf"
if "${checker}" \
    --root "${fixture}" \
    --inventory "${scratch}/named-tmpfiles-inventory.json" \
    --producers "${scratch}/named-tmpfiles-producers.json" \
    > "${scratch}/named-tmpfiles-nonproducer.out" 2>&1; then
    fail "audit accepted a named non-producing tmpfiles entry"
fi
grep -F 'producer tmpfiles does not create exact path: /run/from-named-tmpfiles: fixture.conf' \
    "${scratch}/named-tmpfiles-nonproducer.out" >/dev/null

printf 'd /run/from-named-tmpfiles 0755 root root -\n' \
    > "${fixture}/usr/lib/tmpfiles.d/fixture.conf"
"${checker}" \
    --root "${fixture}" \
    --inventory "${scratch}/named-tmpfiles-inventory.json" \
    --producers "${scratch}/named-tmpfiles-producers.json"

# Restore the creation-capable positive control for installed-unit discovery.
printf 'd /run/from-tmpfiles 0755 root root -\n' \
    > "${fixture}/usr/lib/tmpfiles.d/fixture.conf"

# The production Poolsuite policy is one flattened full instance unit, not a
# drop-in. Prove rootfs discovery audits that shape and any accompanying
# instance drop-ins without requiring explicit --unit arguments.
cp "${scratch}/pf-app@org.pocketforge.fixture.service" \
    "${fixture}/etc/systemd/system/pf-app@org.pocketforge.fixture.service"
mkdir -p \
    "${fixture}/etc/systemd/system/pf-app@org.pocketforge.fixture.service.d"
cat > "${fixture}/etc/systemd/system/pf-app@org.pocketforge.fixture.service.d/50-policy.conf" <<'EOF'
[Service]
BindReadOnlyPaths=/run/generated/dropin:/inside/dropin
EOF
"${checker}" \
    --root "${fixture}" \
    --producers "${scratch}/all-producers.json" \
    > "${scratch}/installed-units.out"
grep -F 'units=2' "${scratch}/installed-units.out" >/dev/null

python3 - "${scratch}/all-producers.json" "${scratch}/missing-dropin.json" <<'PY'
import json
from pathlib import Path
import sys

source, output = map(Path, sys.argv[1:])
data = json.loads(source.read_text(encoding="utf-8"))
del data["producers"]["/run/generated/dropin"]
output.write_text(json.dumps(data), encoding="utf-8")
PY
if "${checker}" \
    --root "${fixture}" \
    --producers "${scratch}/missing-dropin.json" \
    > "${scratch}/missing-dropin.out" 2>&1; then
    fail "audit skipped an installed instance drop-in"
fi
grep -F 'missing producer: /run/generated/dropin: consumer=' \
    "${scratch}/missing-dropin.out" >/dev/null
grep -F 'pf-app@org.pocketforge.fixture.service.d/50-policy.conf:BindReadOnlyPaths' \
    "${scratch}/missing-dropin.out" >/dev/null

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
