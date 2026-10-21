#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="${root}/tests/test-session-authority-systemd.sh"
driver="${root}/tests/session-authority-systemd/drive.py"
driver_unit="${root}/tests/session-authority-systemd/session-authority-driver.service"
authority_peer_dropin="${root}/tests/session-authority-systemd/10-test-driver-peer.conf"
session_target="${root}/tests/session-authority-systemd/pocketforge-gamescope-session.target"
real_session_target="${root}/rootfs-overlay/etc/systemd/system/pocketforge-gamescope-session.target"
resident_unit="${root}/rootfs-overlay/etc/systemd/system/pocketforge-gamescope-resident.service"
real_gamescope_unit="${root}/rootfs-overlay/etc/systemd/system/pocketforge-gamescope.service"
fake_gamescope_unit="${root}/tests/session-authority-systemd/pocketforge-gamescope.service"
fake_gamescope="${root}/tests/session-authority-systemd/fake-gamescope"
test_tmpfiles="${root}/tests/session-authority-systemd/session-authority-test-tmpfiles.conf"
real_tmpfiles="${root}/rootfs-overlay/usr/lib/tmpfiles.d/pocketforge-gamescope-x11.conf"
fake_broker="${root}/tests/session-authority-systemd/fake-input-broker"
recipe="${root}/tests/session-authority-systemd/Containerfile"
probe="${root}/tests/probe-session-authority-docker-systemd.sh"
probe_recipe="${root}/tests/session-authority-systemd/probe/Containerfile"
argv_audit="${root}/tests/session-authority-systemd/docker-argv-audit.sh"
probe_diagnostics="${root}/tests/session-authority-systemd/probe-diagnostics.sh"
build_cache_audit="${root}/tests/session-authority-systemd/build-cache-audit.sh"
remount_helper="${root}/tests/session-authority-systemd/remount-cgroup-systemd"
workflow="${root}/.github/workflows/session-authority-systemd.yml"
precondition_verifier="${root}/tests/verify-session-authority-systemd-preconditions.py"
shell_fixture_verifier="${root}/tests/verify-session-authority-shell-fixture.py"
app_fixture_verifier="${root}/tests/verify-session-authority-app-fixture.py"
app_dropin_verifier="${root}/tests/verify-session-authority-app-dropins.py"
app_policy_inventory="${root}/build/app-policy-a133-open-g1-v1.json"
platform_renderer="${root}/scripts/render-platform-capabilities.py"
nonproduction_platform_renderer="${root}/tests/session-authority-systemd/make-nonproduction-platform.py"
platform_descriptor="${root}/tests/session-authority-systemd/capabilities.toml"
handwritten_platform="${root}/tests/session-authority-systemd/platform-capabilities.toml"
app_manifest="${root}/tests/session-authority-systemd/app.toml"
landlock_unavailable_dropin="${root}/tests/session-authority-systemd/10-test-landlock-unavailable.conf"
tmp="$(mktemp -d /tmp/tsp-f3fm-211-safety.XXXXXX)"
fake_root="${tmp}/host"
fake_bin="${fake_root}/.test-bin"
fake_unapproved_root="${tmp}/unapproved-host"
sentinel_bin="${tmp}/sentinel-bin"
sentinel_log="${tmp}/sentinel-docker-calls"
call_log="${tmp}/docker-calls"
df_counter="${tmp}/df-counter"
stdout_log="${tmp}/stdout"
stderr_log="${tmp}/stderr"

cleanup() {
    find "${tmp}" -mindepth 1 -delete
    rmdir "${tmp}"
}
trap cleanup EXIT

verify_driver_peer_fixture() {
    local test_unit="$1"
    local test_dropin="$2"
    local test_harness="$3"

    grep -Fqx 'User=root' "${test_unit}" \
        && grep -Fqx 'ExecStart=/usr/local/libexec/drive.py' "${test_unit}" \
        && ! grep -Eq '^(Requires|BindsTo)=pf-session-authorityd\.service$' "${test_unit}" \
        && grep -Fq -- '--shell-user root --shell-unit session-authority-driver.service' \
            "${test_dropin}" \
        && grep -Fq 'session-authority-driver.service' "${test_harness}" \
        && grep -Fq 'session-authority-driver.service' "${recipe}" \
        && grep -Fq '10-test-driver-peer.conf' "${recipe}" \
        && grep -Fq 'systemd-analyze verify' "${recipe}" \
        && ! grep -Fq '/usr/local/libexec/drive.py 2>&1' "${test_harness}"
}

# Runtime authenticates the process which opens its shell socket. Run the root
# orchestration driver as an explicitly configured test-only service: it must stay
# alive while pf-shell-selected is stopped during an app session. Positive control
# plus a mutation proving that a mismatched peer unit is rejected by this guard.
verify_driver_peer_fixture "${driver_unit}" "${authority_peer_dropin}" "${harness}" || {
    echo 'session-authority systemd-safety: FAIL: driver lacks a matched service peer identity' >&2
    exit 1
}
sed 's/--shell-unit session-authority-driver.service/--shell-unit wrong-driver.service/' \
    "${authority_peer_dropin}" >"${tmp}/mismatched-driver-peer.conf"
if verify_driver_peer_fixture "${driver_unit}" "${tmp}/mismatched-driver-peer.conf" "${harness}"; then
    echo 'session-authority systemd-safety: FAIL: mismatched driver peer unit passed' >&2
    exit 1
fi

verify_session_producer_fixture() {
    local test_target="$1"
    local test_gamescope="$2"
    local directive

    cmp -s "${test_target}" "${real_session_target}" || return 1
    for directive in \
        'PartOf=pocketforge-gamescope-session.target' \
        'Conflicts=pf-shell-selected.service pocketforge-foreground.target' \
        'OnFailure=pocketforge-gamescope-fallback.service' \
        'OnSuccess=pocketforge-gamescope-fallback.service'; do
        grep -Fqx "${directive}" "${real_gamescope_unit}" || return 1
        grep -Fqx "${directive}" "${test_gamescope}" || return 1
    done
    grep -Fq \
            'Requires=pf-input-broker.service pocketforge-gamescope.service pocketforge-session-publisher.service' \
            "${test_target}" \
        && grep -Fqx \
            'After=pf-input-broker.service pocketforge-session-publisher.service' \
            "${test_target}" \
        && grep -Fqx 'Type=notify' "${test_gamescope}" \
        && grep -Fqx 'ExecStart=/usr/local/libexec/fake-gamescope' "${test_gamescope}" \
        && grep -Fq 'WAYLAND = Path("/run/pocketforge/gamescope/gamescope-0")' \
            "${fake_gamescope}" \
        && grep -Fq 'X11 = Path("/run/pocketforge/x11/.X11-unix/X0")' \
            "${fake_gamescope}" \
        && grep -Fqx 'd /run/pocketforge 0775 root gamer -' "${real_tmpfiles}" \
        && grep -Fqx 'd /run/pocketforge/x11/.X11-unix 1777 root root -' \
            "${real_tmpfiles}" \
        && ! grep -Fq '/run/pocketforge/x11' "${test_tmpfiles}" \
        && grep -Fq \
            'COPY pocketforge-gamescope-x11.conf /usr/lib/tmpfiles.d/pocketforge-gamescope-x11.conf' \
            "${recipe}" \
        && grep -Fq 'verify_tmpfiles_contract()' "${driver}" \
        && grep -Fq 'command("systemd-tmpfiles", "--create")' "${driver}" \
        && grep -Fq '"${fixture_root%/}/run/pocketforge/x11/.X11-unix/"X*' \
            "${harness}" \
        && grep -Fq 'for group_name in gamer audio input video pf-session; do' "${recipe}" \
        && grep -Fq 'COPY pocketforge-session-publisher.service' "${recipe}" \
        && grep -Fq 'COPY pf-session-publish /usr/lib/pocketforge/pf-session-publish' "${recipe}" \
        && grep -Fq 'probe["POCKETFORGE_SESSION"] == "/run/pocketforge/session"' "${driver}" \
        && grep -Fq '"wayland_socket": stat.S_ISSOCK(' \
            "${root}/tests/session-authority-systemd/fixture"
}

verify_resident_fixture() {
    local unit=$1
    local test_harness=$2
    local test_recipe=$3

    grep -Fqx 'BindsTo=pocketforge-gamescope-session.target' "${unit}" \
        && grep -Fqx 'After=pocketforge-gamescope-session.target' "${unit}" \
        && grep -Fqx 'Type=oneshot' "${unit}" \
        && grep -Fqx 'RemainAfterExit=yes' "${unit}" \
        && ! grep -q '^\[Install\]$' "${unit}" \
        && grep -Fq 'resident_unit=' "${test_harness}" \
        && grep -Fq 'pocketforge-gamescope-resident.service' "${test_harness}" \
        && grep -Fq \
            'COPY pocketforge-gamescope-resident.service /etc/systemd/system/pocketforge-gamescope-resident.service' \
            "${test_recipe}"
}

verify_residency_scenario_isolation() {
    local test_driver=$1

    grep -Fq 'def reset_owner_start_limit() -> None:' "${test_driver}" \
        && grep -Fq 'command("systemctl", "reset-failed", OWNER_UNIT)' "${test_driver}" \
        && [ "$(grep -Fc 'reset_owner_start_limit()' "${test_driver}")" -eq 4 ]
}

verify_resident_relaunch_fixture() {
    local test_driver=$1

    grep -Fq 'second_scope = launch()' "${test_driver}" \
        && grep -Fq 'second resident app invocation' "${test_driver}" \
        && grep -Fq 'second resident session_idle completion' "${test_driver}" \
        && grep -Fq 'second_scope.session_id != scope.session_id' "${test_driver}" \
        && grep -Fq 'resident_second_session=' "${test_driver}"
}

verify_broker_session_state_fixture() {
    local test_broker=$1
    local test_driver=$2

    grep -Fq '"foreground_target": unit_state("pocketforge-foreground.target")' \
        "${test_broker}" \
        && grep -Fq '"session_target": unit_state("pocketforge-gamescope-session.target")' \
            "${test_broker}" \
        && grep -Fq '"pocketforge-gamescope-session.target"' "${test_broker}" \
        && grep -Fq '"session_target_start_job": unit_has_start_job(' "${test_broker}" \
        && grep -Fq 'start["foreground_target"] == "inactive"' "${test_driver}" \
        && grep -Fq 'start["session_target_start_job"] is True' "${test_driver}" \
        && grep -Fq '"--acquire-sock": "/run/pocketforge/input-broker.sock"' \
            "${test_broker}" \
        && grep -Fq '"--system-menu-sock": "/run/pocketforge/system-menu.sock"' \
            "${test_broker}" \
        && grep -Fq \
            '"--compositor-sock": "/run/pocketforge/input/compositor.sock"' \
            "${test_broker}" \
        && grep -Fq 'BROKER_SOCKET = Path("/run/pocketforge/input-broker.sock")' \
            "${test_driver}" \
        && grep -Fq 'SYSTEM_MENU_SOCKET = Path("/run/pocketforge/system-menu.sock")' \
            "${test_driver}"
}

# A Gamescope session conflicts with the fb0 foreground target. The broker may
# grab only after that owner is inactive and while the Gamescope session target's
# start transaction is pending on the broker's READY notification. Keep the two
# target identities explicit, then prove an aliased job probe is rejected.
verify_broker_session_state_fixture "${fake_broker}" "${driver}" || {
    echo 'session-authority systemd-safety: FAIL: broker session-state probe is incomplete' >&2
    exit 1
}
sed 's/pocketforge-gamescope-session.target/pocketforge-foreground.target/g' \
    "${fake_broker}" >"${tmp}/broker-with-aliased-targets"
if verify_broker_session_state_fixture "${tmp}/broker-with-aliased-targets" "${driver}"; then
    echo 'session-authority systemd-safety: FAIL: broker probe with aliased targets passed' >&2
    exit 1
fi

verify_r4_forced_close_fixture() {
    local test_driver=$1

    grep -Fq 'pending == "ForcedClose"' "${test_driver}" \
        && grep -Fq 'session_events(final_events, scope, "forced_close")' "${test_driver}" \
        && grep -Fq 'history_entry(scope.session_id)["receipt"] == "ForcedClose"' "${test_driver}" \
        && grep -Fq 'R4=ForcedClose systemctl_stop_exit_after_sigkill=' "${test_driver}"
}

# Runtime's v2 close contract escalates at 1500 ms, before the image unit's 2 s
# SIGKILL backstop. Pin the resulting ForcedClose receipt and prove that the old
# Returned expectation cannot satisfy this integration guard.
verify_r4_forced_close_fixture "${driver}" || {
    echo 'session-authority systemd-safety: FAIL: R4 does not require ForcedClose' >&2
    exit 1
}
sed 's/ForcedClose/Returned/g' "${driver}" >"${tmp}/returned-r4-drive.py"
if verify_r4_forced_close_fixture "${tmp}/returned-r4-drive.py"; then
    echo 'session-authority systemd-safety: FAIL: old Returned R4 contract passed' >&2
    exit 1
fi

verify_app_policy_inventory_fixture() {
    local test_inventory="$1"

    if ! python3 - "${test_inventory}" <<'PY'
import json
from pathlib import Path
import sys

inventory = json.loads(Path(sys.argv[1]).read_text())
resources = inventory.get("resources", {})
valid = (
    inventory.get("platform_runtime") == "/usr"
    and resources.get("display-sockets") == ["/run/pocketforge/session/wayland-0"]
    and resources.get("session-environment") == ["/run/pocketforge/session/environment"]
    and resources.get("render-devices") == ["/dev/dri/renderD128"]
)
raise SystemExit(0 if valid else 1)
PY
    then
        return 1
    fi
    grep -Fq 'app_policy_inventory="${root}/build/app-policy-a133-open-g1-v1.json"' \
        "${harness}" \
        && grep -Fq '"${context}/app-policy.resources.json"' "${harness}" \
        && grep -Fq '/usr/share/pocketforge/app-policy' "${recipe}" \
        && grep -Fq \
            'COPY app-policy.resources.json /usr/share/pocketforge/app-policy/org.pocketforge.fixture.resources.json' \
            "${recipe}"
}

verify_platform_policy_producer_fixture() {
    local test_harness="$1"

    [ ! -e "${handwritten_platform}" ] \
        && grep -Fq 'platform_renderer="${root}/scripts/render-platform-capabilities.py"' \
            "${test_harness}" \
        && grep -Fq 'PF_APP_RUNTIME_FAMILY=pocketforge/a133-powervr' "${test_harness}" \
        && grep -Fq 'PF_APP_CAPABILITIES=' "${test_harness}" \
        && grep -Fq '"${platform_renderer}" --soc sun50iw10p1 --gpu-model open' \
            "${test_harness}" \
        && grep -Fq -- '--gamescope-mode g1' "${test_harness}" \
        && grep -Fq -- '--runtime-source "${runtime}"' "${test_harness}" \
        && grep -Fq -- '--descriptor "${fixtures}/capabilities.toml"' "${test_harness}" \
        && grep -Fq -- '--output "${context}/platform-capabilities.production.toml"' "${test_harness}" \
        && grep -Fq '"${nonproduction_platform_renderer}"' "${test_harness}" \
        && grep -Fq '"${context}/platform-capabilities.production.toml"' "${test_harness}" \
        && grep -Fq '"${context}/platform-capabilities.toml"' "${test_harness}" \
        && ! grep -Fq '"${fixtures}/platform-capabilities.toml"' "${test_harness}" \
        && python3 - "${platform_descriptor}" <<'PY'
import sys
import tomllib
from pathlib import Path

descriptor = tomllib.loads(Path(sys.argv[1]).read_text())
primary = [screen for screen in descriptor.get("screens", []) if screen.get("role") == "primary"]
valid = (
    descriptor.get("schema_version") in (2, 3)
    and set(descriptor.get("memory", {})) >= {"physical_mib", "app_budget_mib"}
    and len(primary) == 1
    and set(primary[0].get("render_canvas", {})) == {"w", "h"}
    and bool(descriptor.get("inputs"))
)
raise SystemExit(0 if valid else 1)
PY
}

verify_ci_landlock_fixture() {
    local test_manifest="$1"
    local production_contract="$2"
    local live_contract="$3"
    local test_dropin="$4"

    if ! python3 - "${test_manifest}" "${production_contract}" "${live_contract}" <<'PY'
import sys
import tomllib
from pathlib import Path

manifest = tomllib.loads(Path(sys.argv[1]).read_text())
production = tomllib.loads(Path(sys.argv[2]).read_text())
live = tomllib.loads(Path(sys.argv[3]).read_text())
expected_live = dict(production)
expected_live["production"] = False
expected_live["landlock_mode"] = "best_effort"
raise SystemExit(
    0 if (
        manifest.get("app", {}).get("use") == []
        and production.get("production") is True
        and production.get("landlock_mode") == "required"
        and production.get("landlock_full_min_abi") == 10
        and production.get("landlock_browser_min_abi") == 6
        and live == expected_live
    ) else 1
)
PY
    then
        return 1
    fi
    grep -Fq "PF_APP_CAPABILITIES='audio entropy input settings'" \
        "${harness}" \
        && grep -Fqx '        "landlock_full_min_abi": 10,' "${platform_renderer}" \
        && grep -Fqx '        "landlock_browser_min_abi": 6,' "${platform_renderer}" \
        && ! grep -Eq 'sed .*landlock|landlock_(full|browser)_min_abi=' "${harness}" \
        && grep -Fqx 'SystemCallErrorNumber=EPERM' "${test_dropin}" \
        && grep -Fqx \
            'SystemCallFilter=~landlock_create_ruleset landlock_add_rule landlock_restrict_self' \
            "${test_dropin}" \
        && grep -Fq 'COPY 10-test-landlock-unavailable.conf /etc/systemd/system/pf-app@.service.d/10-test-landlock-unavailable.conf' \
            "${recipe}" \
        && grep -Fq '/etc/systemd/system/pf-app@.service' "${recipe}" \
        && ! grep -Fq 'SystemCallFilter=' "${root}/rootfs-overlay/etc/systemd/system/pf-app@.service"
}

# pf-app@ now consumes the compositor session environment and socket. Exercise
# the real target + publisher bytes around a fake socket-owning Gamescope, and
# prove that dropping the publisher readiness edge is rejected.
verify_session_producer_fixture "${session_target}" "${fake_gamescope_unit}" || {
    echo 'session-authority systemd-safety: FAIL: Gamescope session producer fixture is incomplete' >&2
    exit 1
}
sed 's/ pocketforge-session-publisher.service$//' \
    "${session_target}" >"${tmp}/unordered-session.target"
if verify_session_producer_fixture "${tmp}/unordered-session.target" "${fake_gamescope_unit}"; then
    echo 'session-authority systemd-safety: FAIL: unordered session publisher passed' >&2
    exit 1
fi
sed 's/^Requires=pf-input-broker.service /Requires=/' \
    "${session_target}" >"${tmp}/session-without-router.target"
if verify_session_producer_fixture "${tmp}/session-without-router.target" "${fake_gamescope_unit}"; then
    echo 'session-authority systemd-safety: FAIL: session target without router passed' >&2
    exit 1
fi
sed '/^OnSuccess=pocketforge-gamescope-fallback.service$/d' \
    "${fake_gamescope_unit}" >"${tmp}/incomplete-gamescope.service"
if verify_session_producer_fixture "${session_target}" "${tmp}/incomplete-gamescope.service"; then
    echo 'session-authority systemd-safety: FAIL: compositor without clean-exit fallback passed' >&2
    exit 1
fi
gamescope_self_test="$(python3 "${fake_gamescope}" --self-test)"
grep -Fqx 'fake-gamescope self-test: PASS filesystem_sockets=2 abstract_sockets=0' \
    <<<"${gamescope_self_test}" || exit 1
verify_resident_fixture "${resident_unit}" "${harness}" "${recipe}" || {
    echo 'session-authority systemd-safety: FAIL: resident hold is absent from the live fixture' >&2
    exit 1
}
sed '/^BindsTo=pocketforge-gamescope-session.target$/d' \
    "${resident_unit}" >"${tmp}/resident-without-bind.service"
if verify_resident_fixture "${tmp}/resident-without-bind.service" "${harness}" "${recipe}"; then
    echo 'session-authority systemd-safety: FAIL: unbound resident hold passed' >&2
    exit 1
fi
verify_residency_scenario_isolation "${driver}" || {
    echo 'session-authority systemd-safety: FAIL: residency scenarios share the shell start-rate counter' >&2
    exit 1
}
sed 's/command("systemctl", "reset-failed", OWNER_UNIT)/command("systemctl", "reset-failed", GAMESCOPE_UNIT)/' \
    "${driver}" >"${tmp}/resident-without-owner-reset.py"
if verify_residency_scenario_isolation "${tmp}/resident-without-owner-reset.py"; then
    echo 'session-authority systemd-safety: FAIL: wrong-unit scenario reset passed' >&2
    exit 1
fi
verify_resident_relaunch_fixture "${driver}" || {
    echo 'session-authority systemd-safety: FAIL: resident session does not prove the next launch slot is free' >&2
    exit 1
}
sed 's/second_scope = launch()/second_scope = scope/' \
    "${driver}" >"${tmp}/resident-without-relaunch.py"
if verify_resident_relaunch_fixture "${tmp}/resident-without-relaunch.py"; then
    echo 'session-authority systemd-safety: FAIL: resident relaunch mutation passed' >&2
    exit 1
fi

# The pinned live runtime loads the image-owned resource inventory before compiling
# launch policy. Exercise the same g1 inventory as the image and reject a
# fixture whose compositor route is incomplete.
verify_app_policy_inventory_fixture "${app_policy_inventory}" || {
    echo 'session-authority systemd-safety: FAIL: app resource inventory is not installed' >&2
    exit 1
}
python3 - "${app_policy_inventory}" "${tmp}/incomplete-resources.json" <<'PY'
import json
from pathlib import Path
import sys

inventory = json.loads(Path(sys.argv[1]).read_text())
inventory["resources"].pop("session-environment")
Path(sys.argv[2]).write_text(json.dumps(inventory))
PY
if verify_app_policy_inventory_fixture "${tmp}/incomplete-resources.json"; then
    echo 'session-authority systemd-safety: FAIL: incomplete compositor inventory passed' >&2
    exit 1
fi

# The systemd integration fixture must consume the same image-owned platform
# contract producer as real apps. A hand-written schema-1 contract can drift
# past required policy fields such as the production Landlock declaration.
verify_platform_policy_producer_fixture "${harness}" || {
    echo 'session-authority systemd-safety: FAIL: platform policy bypasses the image producer' >&2
    exit 1
}
sed 's/--gamescope-mode g1/--gamescope-mode not-shipped/' \
    "${harness}" >"${tmp}/wrong-session-platform-harness"
if verify_platform_policy_producer_fixture "${tmp}/wrong-session-platform-harness"; then
    echo 'session-authority systemd-safety: FAIL: non-g1 platform producer passed' >&2
    exit 1
fi


# Keep the real producer's production policy byte path intact, then derive the
# live VM's explicitly non-production contract. The CI kernel may predate the
# production ABI minimum; this lifecycle test must not weaken image policy.
cat >"${tmp}/production-platform.toml" <<'EOF'
schema_version = 2
runtime_family = "pocketforge/a133-powervr"
runtime_abi = "1"
platform_version = "20"
supported_capabilities = ["audio", "entropy", "input", "settings", "x11"]
physical_memory_mib = 970
app_memory_budget_mib = 600
production = true
landlock_mode = "required"
landlock_full_min_abi = 10
landlock_browser_min_abi = 6
gles_max = "3.0"
inputs = ["buttons"]
display = { width = 1280, height = 720 }
EOF
python3 "${nonproduction_platform_renderer}" \
    "${tmp}/production-platform.toml" "${tmp}/live-platform.toml"
verify_ci_landlock_fixture \
    "${app_manifest}" "${tmp}/production-platform.toml" "${tmp}/live-platform.toml" \
    "${landlock_unavailable_dropin}" || {
    echo 'session-authority systemd-safety: FAIL: CI fixture Landlock contract is not isolated' >&2
    exit 1
}
sed 's/landlock_mode = "required"/landlock_mode = "best_effort"/' \
    "${tmp}/production-platform.toml" >"${tmp}/invalid-production-platform.toml"
if python3 "${nonproduction_platform_renderer}" \
    "${tmp}/invalid-production-platform.toml" "${tmp}/invalid-live-platform.toml"; then
    echo 'session-authority systemd-safety: FAIL: non-production source contract passed' >&2
    exit 1
fi
if [ -e "${tmp}/invalid-live-platform.toml" ]; then
    echo 'session-authority systemd-safety: FAIL: refused contract left output' >&2
    exit 1
fi
sed '/^SystemCallFilter=/d' "${landlock_unavailable_dropin}" \
    >"${tmp}/unguarded-landlock.conf"
if verify_ci_landlock_fixture \
    "${app_manifest}" "${tmp}/production-platform.toml" "${tmp}/live-platform.toml" \
    "${tmp}/unguarded-landlock.conf"; then
    echo 'session-authority systemd-safety: FAIL: unguarded Docker Landlock fixture passed' >&2
    exit 1
fi

mkdir -p \
    "${fake_bin}" \
    "${sentinel_bin}" \
    "${fake_root}/etc/pocketforge" \
    "${fake_root}/tmp/.X11-unix" \
    "${fake_root}/run/pocketforge/x11/.X11-unix" \
    "${fake_root}/run/user" \
    "${fake_unapproved_root}/tmp/.X11-unix" \
    "${fake_unapproved_root}/run/pocketforge/x11/.X11-unix" \
    "${fake_unapproved_root}/run/user"
printf 'PF_RUNNER_USER=runner\n' >"${fake_root}/etc/pocketforge/ephemeral-runner.conf"
: >"${call_log}"
: >"${df_counter}"
: >"${sentinel_log}"

cat >"${fake_bin}/hostname" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${FAKE_HOSTNAME:?}"
EOF

cat >"${fake_bin}/loginctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    list-sessions)
        if [ "${FAKE_GRAPHICAL:-0}" -eq 1 ]; then
            echo '7 1000 owner seat0 tty2'
        else
            echo '42 1001 runner - pts/0'
        fi
        ;;
    show-session)
        property=
        for arg in "$@"; do
            case "${arg}" in --property=*) property="${arg#*=}" ;; esac
        done
        case "${property}" in
            Active) echo yes ;;
            Seat) [ "${FAKE_GRAPHICAL:-0}" -eq 0 ] || echo seat0 ;;
            Type)
                if [ "${FAKE_GRAPHICAL:-0}" -eq 1 ]; then echo wayland; else echo tty; fi
                ;;
            *) exit 2 ;;
        esac
        ;;
    *) exit 2 ;;
esac
EOF

cat >"${fake_bin}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    is-active)
        [ "${FAKE_DISPLAY_MANAGER:-0}" -eq 1 ] && exit 0
        exit 3
        ;;
    *) exit 2 ;;
esac
EOF

cat >"${fake_bin}/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    *gdm*|*gdm3*|*sddm*|*lightdm*|*xdm*)
        [ "${FAKE_DISPLAY_PROCESS:-0}" -eq 1 ] && exit 0
        ;;
esac
exit 1
EOF

cat >"${fake_bin}/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
[ ! -s "${FAKE_DF_COUNTER:?}" ] || count="$(<"${FAKE_DF_COUNTER}")"
count=$((count + 1))
printf '%s\n' "${count}" >"${FAKE_DF_COUNTER}"
case "${FAKE_DISK_MODE:-ample}" in
    ample) value=$((9 * 1024 * 1024 * 1024)) ;;
    preflight-low) value=$((7 * 1024 * 1024 * 1024)) ;;
    floor)
        if [ "${count}" -le 6 ]; then
            value=$((9 * 1024 * 1024 * 1024))
        else
            value=$((3 * 1024 * 1024 * 1024))
        fi
        ;;
    *) exit 2 ;;
esac
case "$*" in
    *source,size,used,avail,pcent,target*)
        printf 'Filesystem 1B-blocks Used Available Use%% Mounted on\n'
        printf '/dev/fake-cache 161061273600 151397597184 %s 94%% /var/cache/pf\n' "${value}"
        ;;
    *) printf 'Avail\n%s\n' "${value}" ;;
esac
EOF

cat >"${fake_bin}/du" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="${*: -1}"
printf '65536\t%s\n' "${path}"
EOF

cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cmd=%s\n' "$*" >>"${DOCKER_CALL_LOG:?}"
case "${1:-}" in
    info)
        printf '%s\n' '{"DockerRootDir":"/var/cache/pf/docker","CgroupVersion":"2","CgroupDriver":"systemd","Architecture":"x86_64","ServerVersion":"29.0.1"}'
        ;;
    version)
        echo '29.0.1'
        ;;
    system)
        [ "${2:-}" = df ] || exit 2
        printf '%s\n' \
            'Images=total:1,active:0,size:1GB,reclaimable:500MB' \
            'Containers=total:0,active:0,size:0B,reclaimable:0B' \
            'Local_Volumes=total:0,active:0,size:0B,reclaimable:0B' \
            'Build_Cache=total:2,active:0,size:2GB,reclaimable:2GB'
        ;;
    buildx)
        case "${2:-}" in
            du)
                if [ -n "${FAKE_CACHE_RECORDS:-}" ]; then
                    [ "${3:-}" = --builder ] \
                        && [ "${4:-}" = "${FAKE_CACHE_BUILDER:?}" ] \
                        && [ "${5:-}" = --format ] \
                        && [ "${6:-}" = json ] || exit 2
                    while IFS= read -r record; do
                        [ -z "${record}" ] || printf '%s\n' "${record}"
                    done <"${FAKE_CACHE_RECORDS}"
                    if [ -n "${FAKE_CACHE_DU_COUNTER:-}" ]; then
                        count=0
                        [ ! -s "${FAKE_CACHE_DU_COUNTER}" ] \
                            || count="$(<"${FAKE_CACHE_DU_COUNTER}")"
                        count=$((count + 1))
                        printf '%s\n' "${count}" >"${FAKE_CACHE_DU_COUNTER}"
                        if [ "${count}" -eq 1 ] \
                            && [ -n "${FAKE_CACHE_LATE_RECORD:-}" ]; then
                            printf '%s\n' "${FAKE_CACHE_LATE_RECORD}" \
                                >>"${FAKE_CACHE_RECORDS}"
                        fi
                    fi
                fi
                ;;
            prune)
                if [ -n "${FAKE_CACHE_RECORDS:-}" ]; then
                    [ "${3:-}" = --builder ] \
                        && [ "${4:-}" = "${FAKE_CACHE_BUILDER:?}" ] || exit 2
                    cache_id=
                    previous=
                    for argument in "$@"; do
                        if [ "${previous}" = --filter ]; then
                            cache_id="${argument#id=}"
                        fi
                        previous="${argument}"
                    done
                    [ -n "${cache_id}" ] || exit 2
                    python3 - "${FAKE_CACHE_RECORDS}" "${cache_id}" \
                        "${FAKE_CACHE_STUCK_ID:-}" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
target = sys.argv[2]
stuck = sys.argv[3]
records = [json.loads(line) for line in path.read_text().splitlines() if line]
if target == stuck or any(target in (record.get("Parents") or []) for record in records):
    raise SystemExit(0)
path.write_text("".join(
    json.dumps(record, separators=(",", ":")) + "\n"
    for record in records
    if record.get("ID") != target
))
PY
                fi
                ;;
            *) exit 2 ;;
        esac
        ;;
    exec)
        case "$*" in
            *'systemctl is-system-running --wait'*)
                printf '%s\n' "${FAKE_PROBE_STATE:-running}"
                exit "${FAKE_PROBE_WAIT_RC:-0}"
                ;;
            *'systemctl --failed --no-legend'*)
                [ -z "${FAKE_PROBE_FAILED_OUTPUT:-}" ] \
                    || printf '%s\n' "${FAKE_PROBE_FAILED_OUTPUT}"
                exit "${FAKE_PROBE_FAILED_RC:-0}"
                ;;
            *'/proc/mounts'*)
                [ -z "${FAKE_PROBE_CGROUP_OPTIONS:-}" ] \
                    || printf '%s\n' "${FAKE_PROBE_CGROUP_OPTIONS}"
                exit "${FAKE_PROBE_CGROUP_RC:-0}"
                ;;
            *) exit 2 ;;
        esac
        ;;
    *) exit 2 ;;
esac
EOF

cat >"${sentinel_bin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sentinel=%s\n' "$*" >>"${DOCKER_SENTINEL_LOG:?}"
exit 97
EOF

chmod +x "${fake_bin}"/* "${sentinel_bin}/docker"

reset_logs() {
    : >"${call_log}"
    : >"${df_counter}"
    : >"${stdout_log}"
    : >"${stderr_log}"
}

run_fake() {
    env \
        BASH_ENV=/dev/null \
        PATH="${fake_bin}:${PATH}" \
        GITHUB_ACTIONS="${FAKE_GITHUB_ACTIONS:-true}" \
        DOCKER_CALL_LOG="${call_log}" \
        FAKE_DF_COUNTER="${df_counter}" \
        FAKE_HOSTNAME="${FAKE_HOSTNAME:-mm-eph-build-0}" \
        FAKE_GRAPHICAL="${FAKE_GRAPHICAL:-0}" \
        FAKE_DISPLAY_MANAGER="${FAKE_DISPLAY_MANAGER:-0}" \
        FAKE_DISPLAY_PROCESS="${FAKE_DISPLAY_PROCESS:-0}" \
        FAKE_DISK_MODE="${FAKE_DISK_MODE:-ample}" \
        bash "${harness}" "$@"
}

run_probe_diagnostics() {
    env \
        BASH_ENV=/dev/null \
        PATH="${fake_bin}:${PATH}" \
        DOCKER_CALL_LOG="${call_log}" \
        FAKE_PROBE_STATE="${FAKE_PROBE_STATE:-running}" \
        FAKE_PROBE_WAIT_RC="${FAKE_PROBE_WAIT_RC:-0}" \
        FAKE_PROBE_FAILED_OUTPUT="${FAKE_PROBE_FAILED_OUTPUT:-}" \
        FAKE_PROBE_FAILED_RC="${FAKE_PROBE_FAILED_RC:-0}" \
        FAKE_PROBE_CGROUP_OPTIONS="${FAKE_PROBE_CGROUP_OPTIONS:-rw,nosuid,nodev,noexec}" \
        FAKE_PROBE_CGROUP_RC="${FAKE_PROBE_CGROUP_RC:-0}" \
        bash -c '
            set -euo pipefail
            source "$1"
            collect_systemd_diagnostics fixture-systemd
            if reason="$(candidate_diagnostics_reason)"; then
                result=pass
                status=0
            else
                status=$?
                result=fail
            fi
            echo "probe-diagnostics: result=${result} state=${state} failed_units_rc=${failed_units_rc} failed_units=$(one_line <<<"${failed_units_output}") cgroup_mount_rc=${cgroup_mount_rc} cgroup_mount_options=$(one_line <<<"${cgroup_mount_options}") reason=${reason}"
            exit "${status}"
        ' bash "${probe_diagnostics}"
}

run_probe_fake() {
    env \
        BASH_ENV=/dev/null \
        PATH="${fake_bin}:${PATH}" \
        GITHUB_ACTIONS=true \
        GITHUB_RUN_ID=missing \
        GITHUB_RUN_ATTEMPT=missing \
        DOCKER_CALL_LOG="${call_log}" \
        FAKE_HOSTNAME=mm-eph-build-0 \
        FAKE_GRAPHICAL=0 \
        FAKE_DISPLAY_MANAGER=0 \
        FAKE_DISPLAY_PROCESS=0 \
        bash "${probe}" "$@"
}

reset_logs
if FAKE_PROBE_STATE=degraded \
    FAKE_PROBE_WAIT_RC=1 \
    FAKE_PROBE_FAILED_OUTPUT='broken.service loaded failed failed' \
    FAKE_PROBE_FAILED_RC=0 \
    FAKE_PROBE_CGROUP_OPTIONS=rw,nosuid,nodev,noexec \
    FAKE_PROBE_CGROUP_RC=0 \
    run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: degraded state with failed unit passed probe diagnostics' >&2
    exit 1
fi
grep -Fq 'result=fail' "${stdout_log}" || exit 1
grep -Fq 'reason=failed_units:broken.service_loaded_failed_failed_' "${stdout_log}" || exit 1

reset_logs
if FAKE_PROBE_STATE=running \
    FAKE_PROBE_WAIT_RC=0 \
    FAKE_PROBE_FAILED_OUTPUT='failed-unit query error' \
    FAKE_PROBE_FAILED_RC=5 \
    FAKE_PROBE_CGROUP_OPTIONS=rw,nosuid,nodev,noexec \
    FAKE_PROBE_CGROUP_RC=0 \
    run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: failed-unit probe error passed diagnostics' >&2
    exit 1
fi
grep -Fq 'result=fail' "${stdout_log}" || exit 1
grep -Fq 'reason=failed_units_probe_rc=5' "${stdout_log}" || exit 1

reset_logs
if FAKE_PROBE_STATE=running \
    FAKE_PROBE_WAIT_RC=0 \
    FAKE_PROBE_FAILED_OUTPUT='' \
    FAKE_PROBE_FAILED_RC=0 \
    FAKE_PROBE_CGROUP_OPTIONS='cgroup query failed' \
    FAKE_PROBE_CGROUP_RC=42 \
    run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: failed cgroup probe passed diagnostics' >&2
    exit 1
fi
grep -Fq 'result=fail' "${stdout_log}" || exit 1
grep -Fq 'reason=cgroup_probe_rc=42' "${stdout_log}" || exit 1

reset_logs
if FAKE_PROBE_STATE=running \
    FAKE_PROBE_WAIT_RC=0 \
    FAKE_PROBE_FAILED_OUTPUT='' \
    FAKE_PROBE_FAILED_RC=0 \
    FAKE_PROBE_CGROUP_OPTIONS=ro,nosuid,nodev,noexec \
    FAKE_PROBE_CGROUP_RC=0 \
    run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: read-only cgroup passed probe diagnostics' >&2
    exit 1
fi
grep -Fq 'result=fail' "${stdout_log}" || exit 1
grep -Fq 'reason=cgroup_not_rw' "${stdout_log}" || exit 1

reset_logs
FAKE_PROBE_STATE=running \
FAKE_PROBE_WAIT_RC=0 \
FAKE_PROBE_FAILED_OUTPUT='' \
FAKE_PROBE_FAILED_RC=0 \
FAKE_PROBE_CGROUP_OPTIONS=rw,nosuid,nodev,noexec \
FAKE_PROBE_CGROUP_RC=0 \
run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"
grep -Fq 'probe-diagnostics: result=pass state=running' "${stdout_log}" || exit 1
grep -Fq 'failed_units_rc=0 failed_units=_' "${stdout_log}" || exit 1
grep -Fq 'cgroup_mount_rc=0 cgroup_mount_options=rw,nosuid,nodev,noexec_ reason=none' \
    "${stdout_log}" || exit 1

reset_logs
FAKE_PROBE_STATE=degraded \
FAKE_PROBE_WAIT_RC=1 \
FAKE_PROBE_FAILED_OUTPUT='' \
FAKE_PROBE_FAILED_RC=0 \
FAKE_PROBE_CGROUP_OPTIONS=rw,nosuid,nodev,noexec \
FAKE_PROBE_CGROUP_RC=0 \
run_probe_diagnostics >"${stdout_log}" 2>"${stderr_log}"
grep -Fq 'probe-diagnostics: result=pass state=degraded' "${stdout_log}" || exit 1
grep -Fq 'reason=none' "${stdout_log}" || exit 1

reset_logs
probe_audit_container=tsp-f3fm-211-probe-fixture-host-bind
probe_audit_label=org.pocketforge.session-authority-probe=gha-missing-missing-probe
probe_audit_image=tsp-f3fm-211-systemd-probe:gha-missing-missing-probe
probe_run_base=(
    run --detach --tty
    --name "${probe_audit_container}"
    --label "${probe_audit_label}"
    --cgroupns=private
    --network none
    --tmpfs '/run:rw,nosuid,nodev,mode=755'
    --tmpfs '/run/lock:rw,nosuid,nodev,mode=755'
)
probe_owner_base=(
    "${probe_run_base[@]}"
    --security-opt apparmor=unconfined
    --cap-add=SYS_ADMIN
)
live_owner_base=(
    run --detach --tty
    --name "${probe_audit_container}"
    --label "${probe_audit_label}"
    --hostname tsp-f3fm-211-systemd
    --cgroupns=private
    --network=none
    --tmpfs '/run:rw,nosuid,nodev,mode=755'
    --tmpfs '/run/lock:rw,nosuid,nodev,mode=755'
    --pids-limit=512
    --env=container=docker
    --security-opt apparmor=unconfined
    --cap-add SYS_ADMIN
)

run_fixture_mode_with_sentinel() {
    env \
        BASH_ENV=/dev/null \
        PATH="${sentinel_bin}:${fake_bin}:/usr/bin:/bin" \
        GITHUB_ACTIONS=true \
        GITHUB_RUN_ID=missing \
        GITHUB_RUN_ATTEMPT=missing \
        DOCKER_CALL_LOG="${call_log}" \
        DOCKER_SENTINEL_LOG="${sentinel_log}" \
        FAKE_DF_COUNTER="${df_counter}" \
        FAKE_HOSTNAME=mm-eph-build-0 \
        FAKE_GRAPHICAL=0 \
        FAKE_DISPLAY_MANAGER=0 \
        FAKE_DISPLAY_PROCESS=0 \
        bash "$@"
}

# Complete inventory of caller-controlled fixture-root modes. A marker under
# that root may admit pure guard/argv checks, but an external PATH Docker must
# never be invoked. --check-docker-probe must reject it before its first call.
fixture_root_modes=(
    harness-audit-argv
    harness-audit-systemd-spec
    harness-audit-lifecycle-argv
    harness-check-host-guard
    harness-check-docker-probe
    probe-audit-run-fixture
)
for fixture_mode in "${fixture_root_modes[@]}"; do
    reset_logs
    : >"${sentinel_log}"
    case "${fixture_mode}" in
        harness-audit-argv)
            fixture_command=(
                "${harness}" --audit-argv "${fake_root}" fixture-table
                info --format '{{json .}}'
            )
            ;;
        harness-audit-systemd-spec)
            fixture_command=(
                "${harness}" --audit-systemd-spec "${fake_root}" fixture-table
            )
            ;;
        harness-audit-lifecycle-argv)
            fixture_command=(
                "${harness}" --audit-lifecycle-argv "${fake_root}" fixture-table
            )
            ;;
        harness-check-host-guard)
            fixture_command=("${harness}" --check-host-guard "${fake_root}")
            ;;
        harness-check-docker-probe)
            fixture_command=("${harness}" --check-docker-probe "${fake_root}")
            ;;
        probe-audit-run-fixture)
            fixture_command=(
                "${probe}" --audit-run-fixture "${fake_root}"
                baseline-systemd "${probe_audit_container}"
                "${probe_run_base[@]}" "${probe_audit_image}" /sbin/init
            )
            ;;
        *) exit 2 ;;
    esac
    if run_fixture_mode_with_sentinel "${fixture_command[@]}" \
        >"${stdout_log}" 2>"${stderr_log}"; then
        fixture_status=0
    else
        fixture_status=$?
    fi
    [ ! -s "${sentinel_log}" ] || {
        echo "session-authority systemd-safety: FAIL: fixture-root mode called external Docker mode=${fixture_mode}" >&2
        exit 1
    }
    if [ "${fixture_mode}" = harness-check-docker-probe ]; then
        [ "${fixture_status}" -ne 0 ] || {
            echo 'session-authority systemd-safety: FAIL: external Docker passed fixture shim admission' >&2
            exit 1
        }
        grep -Fq 'UNAPPROVED_TEST_DOCKER: Docker command is outside fixture fake-bin' \
            "${stderr_log}" || exit 1
    else
        [ "${fixture_status}" -eq 0 ] || {
            echo "session-authority systemd-safety: FAIL: pure fixture-root mode failed mode=${fixture_mode}" >&2
            exit 1
        }
    fi
done

expect_probe_admitted_audit_only() {
    local profile="$1"
    shift
    reset_logs
    run_probe_fake --audit-run-fixture \
        "${fake_root}" "${profile}" "${probe_audit_container}" "$@" \
        >"${stdout_log}" 2>"${stderr_log}"
    grep -Fq 'systemd-docker-probe argv-audit: PASS docker run ' \
        "${stdout_log}" || exit 1
    [ ! -s "${call_log}" ] || {
        echo "session-authority systemd-safety: FAIL: admitted probe fixture called Docker profile=${profile}" >&2
        exit 1
    }
}

expect_probe_rejected_no_docker() {
    local label="$1"
    shift
    reset_logs
    if run_probe_fake --audit-run-fixture \
        "${fake_root}" owner-exception "${probe_audit_container}" \
        "${live_owner_base[@]}" "$@" \
        "${probe_audit_image}" /usr/local/libexec/remount-cgroup-systemd \
        >"${stdout_log}" 2>"${stderr_log}"; then
        echo "session-authority systemd-safety: FAIL: probe accepted unapproved run option label=${label}" >&2
        exit 1
    fi
    grep -Fq 'UNSAFE_CONTAINER_ARGV:' "${stderr_log}" || {
        echo "session-authority systemd-safety: FAIL: probe refusal reason missing label=${label}" >&2
        cat "${stderr_log}" >&2
        exit 1
    }
    [ ! -s "${call_log}" ] || {
        echo "session-authority systemd-safety: FAIL: rejected probe option reached Docker label=${label}" >&2
        exit 1
    }
}

expect_probe_admitted_audit_only baseline-systemd \
    "${probe_run_base[@]}" "${probe_audit_image}" /sbin/init
expect_probe_admitted_audit_only positive-control \
    "${probe_run_base[@]}" --entrypoint /bin/sleep \
    "${probe_audit_image}" infinity
expect_probe_admitted_audit_only owner-exception \
    "${probe_owner_base[@]}" "${probe_audit_image}" \
    /usr/local/libexec/remount-cgroup-systemd

expect_probe_rejected_no_docker device-cgroup-rule \
    --device-cgroup-rule 'b *:* rwm'
expect_probe_rejected_no_docker root-volume -v /:/host
expect_probe_rejected_no_docker root-mount \
    --mount type=bind,source=/,target=/host
expect_probe_rejected_no_docker nonnormalized-dev-volume -v //dev:/hostdev
expect_probe_rejected_no_docker docker-socket-volume \
    -v /var/run/docker.sock:/var/run/docker.sock
expect_probe_rejected_no_docker host-ipc --ipc=host
expect_probe_rejected_no_docker host-uts --uts=host
expect_probe_rejected_no_docker other-container-pid --pid=container:other
expect_probe_rejected_no_docker host-cgroup-bind \
    --mount type=bind,source=/sys/fs/cgroup,target=/sys/fs/cgroup

reset_logs
FAKE_GRAPHICAL=1
if run_fake >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: graphical host passed guard' >&2
    exit 1
fi
FAKE_GRAPHICAL=0
grep -Fq 'INTERACTIVE_WORKSTATION: active session=7 seat=seat0 type=wayland' \
    "${stderr_log}" || exit 1
[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-safety: FAIL: graphical refusal reached Docker' >&2
    exit 1
}

reset_logs
run_fake --check-host-guard "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"
grep -Fqx \
    'session-authority host-guard: PASS host=mm-eph-build-0 ephemeral_slot=true' \
    "${stdout_log}" || exit 1

reset_logs
FAKE_DISPLAY_MANAGER=1
if run_fake --check-host-guard "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: display manager passed guard' >&2
    exit 1
fi
FAKE_DISPLAY_MANAGER=0
grep -Fq 'INTERACTIVE_WORKSTATION: active display-manager.service' "${stderr_log}" || exit 1

reset_logs
FAKE_GITHUB_ACTIONS=false
if run_fake --check-host-guard "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: non-Actions host passed guard' >&2
    exit 1
fi
FAKE_GITHUB_ACTIONS=true
grep -Fq 'UNAPPROVED_HOST: GITHUB_ACTIONS=true is required' "${stderr_log}" || exit 1

reset_logs
if run_fake --check-host-guard "${fake_unapproved_root}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: unmarked host passed guard' >&2
    exit 1
fi
grep -Fq 'UNAPPROVED_HOST: ephemeral runner marker missing' "${stderr_log}" || exit 1

for x_socket in \
    "${fake_root}/tmp/.X11-unix/X77" \
    "${fake_root}/run/pocketforge/x11/.X11-unix/X77"; do
python3 - "${x_socket}" <<'PY'
import socket
import sys

with socket.socket(socket.AF_UNIX) as display:
    display.bind(sys.argv[1])
PY
    reset_logs
    if run_fake --check-host-guard "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
        echo "session-authority systemd-safety: FAIL: X socket passed guard path=${x_socket}" >&2
        exit 1
    fi
    grep -Fq 'INTERACTIVE_WORKSTATION: graphical socket=' "${stderr_log}" || exit 1
    find "$(dirname "${x_socket}")" -mindepth 1 -delete
done

reset_logs
FAKE_DISK_MODE=preflight-low
if run_fake --check-docker-probe "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: low Docker-root disk passed admission' >&2
    exit 1
fi
FAKE_DISK_MODE=ample
grep -Fq 'INSUFFICIENT_DISK: docker_root=/var/cache/pf/docker' "${stderr_log}" || exit 1

reset_logs
run_fake --check-docker-probe "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"
grep -Fq 'session-authority real-systemd: PASS ' "${stdout_log}" || exit 1
grep -Fq 'docker_root=/var/cache/pf/docker' "${stdout_log}" || exit 1
grep -Fq 'docker_root_free_before_bytes=9663676416' "${stdout_log}" || exit 1
grep -Fq 'docker_root_free_after_bytes=9663676416' "${stdout_log}" || exit 1
grep -Fq 'docker_root_df_before=filesystem:/dev/fake-cache,size_bytes:161061273600,used_bytes:151397597184,available_bytes:9663676416,use_percent:94%,mount:/var/cache/pf' \
    "${stdout_log}" || exit 1
grep -Fq 'docker_root_df_after=filesystem:/dev/fake-cache,size_bytes:161061273600,used_bytes:151397597184,available_bytes:9663676416,use_percent:94%,mount:/var/cache/pf' \
    "${stdout_log}" || exit 1
grep -Fq 'docker_system_df_before=Images=total:1,active:0,size:1GB,reclaimable:500MB,Containers=total:0,active:0,size:0B,reclaimable:0B,Local_Volumes=total:0,active:0,size:0B,reclaimable:0B,Build_Cache=total:2,active:0,size:2GB,reclaimable:2GB' \
    "${stdout_log}" || exit 1
grep -Fq 'run_scope_removed=true' "${stdout_log}" || exit 1
grep -Fq 'cmd=info --format {{json .}}' "${call_log}" || exit 1
grep -Fq 'cmd=version --format {{.Server.Version}}' "${call_log}" || exit 1
grep -Fq 'cmd=system df ' "${call_log}" || exit 1

reset_logs
FAKE_DISK_MODE=floor
if run_fake --check-docker-probe "${fake_root}" >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: Docker-root disk floor did not abort' >&2
    exit 1
fi
FAKE_DISK_MODE=ample
grep -Fq 'receipt_reason=DISK_FLOOR_ABORT' "${stderr_log}" || {
    cat "${stderr_log}" >&2
    exit 1
}
grep -Fq 'docker_root_min_free_bytes=3221225472' "${stderr_log}" || exit 1
grep -Fq 'run_scope_removed=true' "${stderr_log}" || exit 1

audit_id=fixture-audit
audit_label="org.pocketforge.session-authority-run=${audit_id}"
audit_container="tsp-f3fm-211-systemd-${audit_id}"
# The harness tags its image with the first 12 hex of its pinned runtime_sha
# (configure_run_identity). Derive the tag from that pin. With a stale literal the
# suite still passes, but four of the unsafe-argv cases below (missing-apparmor,
# missing-capability, duplicate-admin, wrong-entrypoint) are then refused as an
# "unapproved Docker run option" (the tag) instead of for the defect they name.
audit_runtime="$(sed -n 's/^runtime_sha=\([0-9a-f]\{40\}\)$/\1/p' "${harness}")"
[ "${#audit_runtime}" -eq 40 ] || {
    echo 'session-authority systemd-safety: FAIL: harness runtime_sha not found' >&2
    exit 1
}
audit_image="tsp-f3fm-211-systemd:${audit_runtime:0:12}-${audit_id}"
dashdash=--
privileged_flag="${dashdash}privileged"

reset_logs
FAKE_GRAPHICAL=1
if run_fake --audit-systemd-spec "${fake_root}" "${audit_id}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: graphical host reached owner exception audit' >&2
    exit 1
fi
FAKE_GRAPHICAL=0
grep -Fq 'INTERACTIVE_WORKSTATION:' "${stderr_log}" || exit 1
[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-safety: FAIL: graphical owner exception audit reached Docker' >&2
    exit 1
}

reset_logs
if run_fake --audit-systemd-spec "${fake_unapproved_root}" "${audit_id}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: non-ephemeral host accepted owner exception' >&2
    exit 1
fi
grep -Fq 'UNAPPROVED_HOST: ephemeral runner marker missing' "${stderr_log}" || exit 1
[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-safety: FAIL: non-ephemeral owner exception audit reached Docker' >&2
    exit 1
}

reset_logs
run_fake --audit-systemd-spec "${fake_root}" "${audit_id}" \
    >"${stdout_log}" 2>"${stderr_log}"
safe_spec="$(cat "${stdout_log}")"
[ ! -s "${call_log}" ] || {
    echo 'session-authority systemd-safety: FAIL: admitted live argv audit called Docker' >&2
    exit 1
}
for required in \
    'docker run' \
    '--tty' \
    "--name ${audit_container}" \
    "--label ${audit_label}" \
    '--cgroupns=private' \
    '--network=none' \
    '--tmpfs /run:rw,nosuid,nodev,mode=755' \
    '--tmpfs /run/lock:rw,nosuid,nodev,mode=755' \
    '--security-opt apparmor=unconfined' \
    '--cap-add SYS_ADMIN' \
    '/usr/local/libexec/remount-cgroup-systemd'; do
    grep -Fq -- "${required}" "${stdout_log}" || {
        echo "session-authority systemd-safety: FAIL: safe spec missing ${required}" >&2
        exit 1
    }
done
forbidden_spec_regex="${privileged_flag}|--network([ =])host|--pid([ =])host|--cgroupns([ =])host|--device|(-v|--volume)(=| )[[:space:]]*/(dev|sys/fs/cgroup)"
if grep -Eq -- "${forbidden_spec_regex}" \
    <<<"${safe_spec}"; then
    echo 'session-authority systemd-safety: FAIL: safe Docker spec contains forbidden option' >&2
    exit 1
fi

expect_rejected() {
    local label="$1"
    shift
    if run_fake --audit-argv "${fake_root}" "${audit_id}" "$@" \
        >"${stdout_log}" 2>"${stderr_log}"; then
        echo "session-authority systemd-safety: FAIL: unsafe argv passed label=${label}" >&2
        exit 1
    fi
    grep -Eq 'UNSAFE_CONTAINER_ARGV:|UNSCOPED_CONTAINER_ARGV:' "${stderr_log}" || {
        echo "session-authority systemd-safety: FAIL: unsafe argv reason missing label=${label}" >&2
        cat "${stderr_log}" >&2
        exit 1
    }
}

safe_run_base=(
    run --detach --tty
    --name "${audit_container}"
    --label "${audit_label}"
    --cgroupns=private
    --network none
    --tmpfs '/run:rw,nosuid,nodev,mode=755'
    --tmpfs '/run/lock:rw,nosuid,nodev,mode=755'
)
safe_run=(
    "${safe_run_base[@]}"
    --security-opt apparmor=unconfined
    --cap-add SYS_ADMIN
)
expect_rejected unscoped-run run --detach --tty image
expect_rejected unscoped-build build --tag "${audit_image}" /scope
expect_rejected missing-apparmor "${safe_run_base[@]}" --cap-add SYS_ADMIN \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected missing-capability "${safe_run_base[@]}" \
    --security-opt apparmor=unconfined \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected duplicate-admin "${safe_run[@]}" --cap-add SYS_ADMIN \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected other-capability "${safe_run[@]}" --cap-add NET_ADMIN \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected tty-capability "${safe_run[@]}" --cap-add SYS_TTY_CONFIG \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected other-security-option "${safe_run[@]}" --security-opt seccomp=unconfined \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected wrong-entrypoint "${safe_run[@]}" "${audit_image}" /sbin/init
expect_rejected privilege "${safe_run[@]}" "${privileged_flag}" \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected device-tree "${safe_run[@]}" -v /dev:/dev \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected console-bind "${safe_run[@]}" --volume=/dev/console:/dev/console \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected tty-device "${safe_run[@]}" --device /dev/tty2 \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-pids "${safe_run[@]}" --pid=host \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-network "${safe_run[@]}" --network host \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-cgroup-namespace "${safe_run[@]}" --cgroupns host \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-user-namespace "${safe_run[@]}" --userns=host \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-cgroup-volume "${safe_run[@]}" \
    -v /sys/fs/cgroup:/sys/fs/cgroup \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected host-cgroup-mount "${safe_run[@]}" \
    --mount type=bind,source=/sys/fs/cgroup,target=/sys/fs/cgroup \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected device-mount "${safe_run[@]}" \
    --mount type=bind,source=/dev/console,target=/console \
    "${audit_image}" /usr/local/libexec/remount-cgroup-systemd
expect_rejected unscoped-full-cache-prune buildx prune --force --all
expect_rejected flattened-cache-audit buildx du --format '{{.ID}}'

reset_logs
run_fake --audit-lifecycle-argv "${fake_root}" "${audit_id}" \
    >"${stdout_log}" 2>"${stderr_log}"
for command_pattern in \
    'docker run ' \
    'docker info ' \
    'docker version ' \
    'docker buildx create ' \
    'docker buildx inspect ' \
    'docker buildx build ' \
    'docker exec ' \
    'docker logs ' \
    'docker container inspect ' \
    'docker container ls ' \
    'docker rm ' \
    'docker image inspect ' \
    'docker image ls ' \
    'docker image rm ' \
    'docker buildx du ' \
    'docker buildx prune ' \
    'docker buildx rm '; do
    grep -Fq "${command_pattern}" "${stdout_log}" || {
        echo "session-authority systemd-safety: FAIL: lifecycle audit missed ${command_pattern}" >&2
        exit 1
    }
done

grep -Eq '^FROM docker[.]io/library/rust:1[.]85-bookworm@sha256:[0-9a-f]{64} AS runtime-builder$' \
    "${recipe}" || exit 1
grep -Fq 'cargo fetch --locked --offline' "${recipe}" || exit 1
grep -Fq 'cargo build --release --locked --offline' "${recipe}" || exit 1
grep -Fq 'ENV container=docker' "${recipe}" || exit 1
! grep -Fq 'container=podman' "${recipe}" || exit 1
[ "$(grep -Fc 'COPY --from=runtime-builder' "${recipe}")" -eq 2 ] || exit 1
for unit in getty@.service getty.target console-getty.service serial-getty@.service autovt@.service; do
    grep -Fq "/etc/systemd/system/${unit}" "${recipe}" || exit 1
done
grep -Fq 'ln -sf /dev/null' "${recipe}" || exit 1
grep -Fq 'COPY remount-cgroup-systemd /usr/local/libexec/remount-cgroup-systemd' \
    "${recipe}" || exit 1
grep -Fq 'COPY remount-cgroup-systemd /usr/local/libexec/remount-cgroup-systemd' \
    "${probe_recipe}" || exit 1
grep -Fqx 'mount -o remount,rw /sys/fs/cgroup' "${remount_helper}" || exit 1
grep -Fqx 'exec /sbin/init' "${remount_helper}" || exit 1

if grep -Eq '\bmknod\b|^[[:space:]]*[cb][+!]?[[:space:]]+/dev/(fb0|uinput|input/[^[:space:]]+)([[:space:]]|$)' \
    "${recipe}" "${root}/tests/session-authority-systemd/session-authority-test-tmpfiles.conf"; then
    echo 'session-authority systemd-safety: FAIL: framebuffer or input placeholder is a device node' >&2
    exit 1
fi
# B4 (tsp-f3fm.202.1.4): the app-session broker cases run the REAL runtime unit and
# the REAL image drop-ins around a fake broker/shell; no input device reaches Docker.
grep -Fqx 'COPY runtime/crates/pf-input-broker/systemd/pf-input-broker.service /etc/systemd/system/pf-input-broker.service' "${recipe}" || exit 1
grep -Fqx 'COPY 10-app-session.conf /etc/systemd/system/pf-input-broker.service.d/10-app-session.conf' "${recipe}" || exit 1
grep -Fqx 'COPY 10-input-broker.conf /etc/systemd/system/pf-shell-selected.service.d/10-input-broker.conf' "${recipe}" || exit 1
grep -Fqx 'COPY fake-input-broker /usr/bin/pf-input-broker' "${recipe}" || exit 1
grep -Fqx 'COPY pf-input-broker-supervisor /usr/lib/pocketforge/pf-input-broker-supervisor' "${recipe}" || exit 1
grep -Fqx 'COPY pf-prefsd.service /etc/systemd/system/pf-prefsd.service' "${recipe}" || exit 1
grep -Fqx 'COPY fake-prefsd /usr/local/libexec/fake-prefsd' "${recipe}" || exit 1
prefsd_self_test="$(python3 "${root}/tests/session-authority-systemd/fake-prefsd" --self-test)"
grep -Fqx 'fake-prefsd self-test: PASS defaults=2 unknown=refused' \
    <<<"${prefsd_self_test}" || exit 1
grep -Fq 'pf-input-broker.service | grep -q .' "${recipe}" || exit 1
for b4_check in 'R4 GATE FAILED' 'def assert_grab_timeline' 'def assert_broker_failure_never_traps' \
    'grab_lock_is_held()' 'systemctl_stop_exit_after_sigkill=' '"--reuid=gamer"' \
    'def assert_broker_exit_before_ready_never_traps' 'def assert_broker_exit_mid_session_never_traps' \
    'def control_restart_on_failure_reproduces_trap' 'watch_units(30.0)' \
    'broker_result == "exit-code"' 'broker uinput pre-start did not fail' \
    'probe["prefsd_connect"] != "ok"' 'prefsd_outside_sandbox=ok'; do
    grep -Fq -- "${b4_check}" "${driver}" || {
        echo "session-authority systemd-safety: FAIL: driver lost B4 check ${b4_check}" >&2
        exit 1
    }
done
# tsp-f3fm.222: SIGKILL (Result=signal) and abort (Result=core-dump) each end in a
# Crash receipt and phase Idle, with a same-run negative control and a bounded core.
for crash_check in 'def assert_sigkill_crash' 'def assert_abort_crash' \
    '"systemctl", "kill", "-s", "KILL", APP_UNIT' 'negative_control_expect_success=' \
    'crash_receipt_violations(observed, "success")' 'sigkill_crash_session = assert_sigkill_crash(order)' \
    'abort_crash_session = assert_abort_crash(order)' 'probe.get("coredump_filter") == "00000000"' \
    'bound_violations, bound = core_bound_violations(report, exec_main_pid)' \
    'require(not bound_violations, f"abort core is not bounded by RLIMIT_AS: {details}")' \
    'core_upper_bound_bytes=' 'vm_peak_plus_allowance_bytes='; do
    grep -Fq -- "${crash_check}" "${driver}" || {
        echo "session-authority systemd-safety: FAIL: driver lost crash-result check ${crash_check}" >&2
        exit 1
    }
done
crash_fixture="${root}/tests/session-authority-systemd/fixture"
for crash_fixture_check in 'Path("/proc/self/coredump_filter").write_text("0\n")' \
    'resource.setrlimit(resource.RLIMIT_CORE, (core_limit, core_limit))' 'os.chdir(state)' \
    'ulimit -v "$1" || exit 97; exec /bin/sh -c "$2" fixture-abort' 'done < /proc/$$/limits' \
    'done < /proc/$$/status' '} > core-bound.txt' 'kill -ABRT $$'; do
    grep -Fq -- "${crash_fixture_check}" "${crash_fixture}" || {
        echo "session-authority systemd-safety: FAIL: fixture lost abort bound ${crash_fixture_check}" >&2
        exit 1
    }
done
for shared_bound in CORE_LIMIT_BYTES AS_LIMIT_KIB; do
    driver_bound="$(sed -n "s/^${shared_bound} = //p" "${driver}")"
    [ -n "${driver_bound}" ] && [ "${driver_bound}" = "$(sed -n "s/^${shared_bound} = //p" "${crash_fixture}")" ] || {
        echo "session-authority systemd-safety: FAIL: driver and fixture ${shared_bound} differ" >&2
        exit 1
    }
done
crash_self_test="$(python3 "${driver}" --self-test)"
grep -Eq '^session-authority crash-classification self-test: PASS signal:correct=accepted,broken_stub=rejected' \
    <<<"${crash_self_test}" || exit 1
# Negative control: a checker that accepts everything must fail its own self-test.
sed 's/^    return violations$/    return []/' "${driver}" >"${tmp}/accept-all-drive.py"
! cmp -s "${driver}" "${tmp}/accept-all-drive.py" || exit 1
if python3 "${tmp}/accept-all-drive.py" --self-test >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: an accept-all crash checker passed the self-test' >&2
    exit 1
fi
grep -Fq 'self-test: broken classifier stub passed for signal' "${stderr_log}" || exit 1
grep -Fq 'core_bound:bounded=accepted,rlimit_as_absent=rejected' <<<"${crash_self_test}" || exit 1
# Negative control: a bound check that ignores RLIMIT_AS must fail its own self-test.
sed 's/^    if (soft, hard) != (str(limit_bytes), str(limit_bytes)):$/    if False:/' \
    "${driver}" >"${tmp}/no-rlimit-as-drive.py"
! cmp -s "${driver}" "${tmp}/no-rlimit-as-drive.py" || exit 1
if python3 "${tmp}/no-rlimit-as-drive.py" --self-test >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: a bound check without RLIMIT_AS passed the self-test' >&2
    exit 1
fi
grep -Fq 'self-test: a report with RLIMIT_AS absent passed the core bound' "${stderr_log}" || exit 1

verify_orientation_descriptor_fixture() {
    local descriptor="$1"
    local container_recipe="$2"
    grep -Fq '[[screens]]' "${descriptor}" \
        && grep -Fq 'role = "primary"' "${descriptor}" \
        && grep -Fq \
            'COPY capabilities.toml /usr/share/pocketforge/devices/a133/capabilities.toml' \
            "${container_recipe}"
}
descriptor_fixture="${root}/tests/session-authority-systemd/capabilities.toml"
verify_orientation_descriptor_fixture "${descriptor_fixture}" "${recipe}" || {
    echo 'session-authority systemd-safety: FAIL: live orientation descriptor fixture is incomplete' >&2
    exit 1
}
sed '/^\[\[screens\]\]/,$d' "${descriptor_fixture}" >"${tmp}/descriptor-without-screen.toml"
if verify_orientation_descriptor_fixture "${tmp}/descriptor-without-screen.toml" "${recipe}"; then
    echo 'session-authority systemd-safety: FAIL: descriptor without a screen passed' >&2
    exit 1
fi
sed '\|COPY capabilities.toml /usr/share/pocketforge/devices/a133/capabilities.toml|d' \
    "${recipe}" >"${tmp}/recipe-without-installed-descriptor"
if verify_orientation_descriptor_fixture \
    "${descriptor_fixture}" "${tmp}/recipe-without-installed-descriptor"; then
    echo 'session-authority systemd-safety: FAIL: recipe without installed descriptor passed' >&2
    exit 1
fi
for b4_input in fake-input-broker fake-prefsd pf-prefsd.service fake-shell capabilities.toml \
    10-app-session.conf 10-input-broker.conf pocketforge-gamescope-session.target \
    pocketforge-gamescope-resident.service; do
    grep -Fq "${b4_input}" "${harness}" || exit 1
done
# The harness runs a FIXTURE shell; the real unit's edges toward harness units
# must match it (bd tsp-3rd3.12). Positive run, then a negative control that
# gives the real unit an unmodelled ordering edge on the broker.
shell_fixture_output="$(python3 "${shell_fixture_verifier}")"
grep -Eq '^session-authority shell-fixture parity: PASS harness_units=[0-9]+ edges_to_harness_units=2 ' \
    <<<"${shell_fixture_output}" || exit 1
sed 's/^After=/After=pf-input-broker.service /' \
    "${root}/rootfs-overlay/etc/systemd/system/pf-shell-selected.service" >"${tmp}/drifted-shell.service"
if python3 "${shell_fixture_verifier}" --real "${tmp}/drifted-shell.service" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: unmodelled shell edge passed the fixture parity check' >&2
    exit 1
fi
grep -Fq "After= toward harness units differs: real ['pf-input-broker.service', 'pf-prefsd.service'] fixture ['pf-prefsd.service']" \
    "${stderr_log}" || exit 1
grep -Fq 'tests/verify-session-authority-shell-fixture.py' "${harness}" || exit 1
grep -Fq 'SHELL_FIXTURE_DRIFT' "${harness}" || exit 1
grep -Fq 'tests/verify-session-authority-app-fixture.py' "${harness}" || exit 1
grep -Fq 'APP_FIXTURE_DRIFT' "${harness}" || exit 1
app_dropin_output="$(python3 "${app_dropin_verifier}")"
grep -Eq '^session-authority app-dropins: PASS files=[1-9][0-9]*$' \
    <<<"${app_dropin_output}" || exit 1
unsafe_dropins="${tmp}/unsafe-dropins"
mkdir -p "${unsafe_dropins}/pf-app@hostile.service.d"
printf '%s\n' '[Service]' 'Environment=SAFE=value' 'InaccessiblePaths=/run/authority.sock' \
    >"${unsafe_dropins}/pf-app@hostile.service.d/90-hostile.conf"
if python3 "${app_dropin_verifier}" --systemd-root "${unsafe_dropins}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: non-environment app drop-in passed' >&2
    exit 1
fi
grep -Fq 'APP_DROPIN_NOT_ENV_ONLY' "${stderr_log}" || exit 1
grep -Fq 'InaccessiblePaths=' "${stderr_log}" || exit 1
grep -Fq 'tests/verify-session-authority-app-dropins.py' "${harness}" || exit 1
grep -Fq 'APP_DROPIN_NOT_ENV_ONLY' "${harness}" || exit 1
grep -Fq -- '- rootfs-overlay/etc/systemd/system/pf-shell-selected.service' "${workflow}" || exit 1
grep -Fq -- '- tests/verify-session-authority-shell-fixture.py' "${workflow}" || exit 1
grep -Fq -- '- tests/verify-session-authority-app-fixture.py' "${workflow}" || exit 1
grep -Fq -- '- tests/verify-session-authority-app-dropins.py' "${workflow}" || exit 1
# Every Requires=/BindsTo= edge on the real app template must resolve inside
# the real-systemd fixture. Positive run, then remove prefsd from a copied
# recipe to prove that the checker detects the exact regression from #220.
app_fixture_output="$(python3 "${app_fixture_verifier}")"
grep -Eq '^session-authority app-fixture closure: PASS hard_dependencies=[0-9]+ provided=[0-9]+$' \
    <<<"${app_fixture_output}" || exit 1
sed '/^COPY pf-prefsd\.service \/etc\/systemd\/system\/pf-prefsd\.service$/d' \
    "${recipe}" >"${tmp}/missing-prefsd.Containerfile"
if python3 "${app_fixture_verifier}" --containerfile "${tmp}/missing-prefsd.Containerfile" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: missing prefsd dependency passed fixture closure' >&2
    exit 1
fi
grep -Fq "hard dependencies absent from ${tmp}/missing-prefsd.Containerfile: ['pf-prefsd.service']" \
    "${stderr_log}" || exit 1
# The broker's effective Restart=no (bd tsp-f3fm.202.1.6) is a static contract that
# the image repo's CI would otherwise never run.
grep -Fq -- '- tests/verify-input-broker-wiring.py' "${workflow}" || exit 1
grep -Fqx '        run: python3 tests/verify-input-broker-wiring.py' "${workflow}" || exit 1
grep -Fq 'exit-before-ready' "${root}/tests/session-authority-systemd/fake-input-broker" || exit 1
precondition_output="$(python3 "${precondition_verifier}")"
grep -Fqx \
    'session-authority path-preconditions: PASS conditions=1 providers=10 fb0=regular units=7' \
    <<<"${precondition_output}" || exit 1
sed '\|^COPY pocketforge-gamescope-x11.conf /usr/lib/tmpfiles.d/pocketforge-gamescope-x11.conf$|d' \
    "${recipe}" >"${tmp}/missing-production-tmpfiles.Containerfile"
if python3 "${precondition_verifier}" \
    --containerfile "${tmp}/missing-production-tmpfiles.Containerfile" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: missing production tmpfiles copy passed audit' >&2
    exit 1
fi
grep -Fq \
    'recipe does not install provider config: COPY pocketforge-gamescope-x11.conf /usr/lib/tmpfiles.d/pocketforge-gamescope-x11.conf' \
    "${stderr_log}" || exit 1
unprovided_unit="${tmp}/unprovided.service"
printf '[Unit]\nConditionPathExists=/unprovided-test-path\n' >"${unprovided_unit}"
if python3 "${precondition_verifier}" --unit "${unprovided_unit}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: unprovided path condition passed audit' >&2
    exit 1
fi
grep -Fq 'unprovided ConditionPathExists=/unprovided-test-path' "${stderr_log}" || exit 1
printf '[Service]\nExecStartPre=/usr/bin/test -e /unprovided-test-path\n' >"${unprovided_unit}"
if python3 "${precondition_verifier}" --unit "${unprovided_unit}" \
    >"${stdout_log}" 2>"${stderr_log}"; then
    echo 'session-authority systemd-safety: FAIL: unprovided pre-start path passed audit' >&2
    exit 1
fi
grep -Fq 'unprovided ExecStartPre test -e=/unprovided-test-path' "${stderr_log}" || exit 1
! grep -Fq 'Path("/dev/fb0").touch()' "${driver}" || exit 1
grep -Fq 'framebuffer.is_file() and framebuffer.stat().st_size == 0' "${driver}" || exit 1
for invocation_field in clean_invocations crash_invocations; do
    grep -Fq "${invocation_field}=" "${driver}" || exit 1
done

! grep -Fq 'podman' "${harness}" || {
    echo 'session-authority systemd-safety: FAIL: host harness still references Podman' >&2
    exit 1
}
! grep -Fq 'mm-build-vm' "${harness}" || exit 1
! grep -Eq 'owned_build_lock|HOST_BUSY|Runner[.]Worker' "${harness}" || exit 1
grep -Fq 'GITHUB_ACTIONS:-' "${harness}" || exit 1
grep -Fq '/etc/pocketforge/ephemeral-runner.conf' "${harness}" || exit 1
grep -Fq 'OWNER DECISION (2026-09-28)' "${harness}" || exit 1
grep -Fq 'assert_real_ephemeral_slot' "${harness}" || exit 1
grep -Fq 'assert_fixture_docker_shim "$2"' "${harness}" || exit 1
[ "$(grep -Fc -- '--cap-add SYS_ADMIN' "${harness}")" -eq 1 ] || exit 1
[ "$(grep -Fc -- '--security-opt apparmor=unconfined' "${harness}")" -eq 1 ] || exit 1
grep -Fq "runs-on: [self-hosted, pf-builder-vm]" "${workflow}" || exit 1
grep -Fq 'workflow_dispatch:' "${workflow}" || exit 1
grep -Fq 'pull_request:' "${workflow}" || exit 1
for path_pattern in \
    'tests/test-session-authority-systemd.sh' \
    'tests/session-authority-systemd/**' \
    'rootfs-overlay/etc/systemd/system/pf-app@.service'; do
    grep -Fq -- "- ${path_pattern}" "${workflow}" || exit 1
done
! grep -Fq -- "${privileged_flag}" "${probe}" || {
    echo 'session-authority systemd-safety: FAIL: probe contains prohibited privileged mode' >&2
    exit 1
}
[ "$(grep -Fc -- '--cap-add=SYS_ADMIN' "${probe}")" -eq 1 ] || {
    echo 'session-authority systemd-safety: FAIL: probe forbidden-capability datum drifted' >&2
    exit 1
}
grep -Fq 'docker_root_free_before_bytes=' "${probe}" || exit 1
grep -Fq 'docker_root_free_after_bytes=' "${probe}" || exit 1
grep -Fq 'docker_root_df_before=' "${probe}" || exit 1
grep -Fq 'docker_root_df_after=' "${probe}" || exit 1
grep -Fq 'docker_system_df_before=' "${probe}" || exit 1
grep -Fq 'docker_system_df_after=' "${probe}" || exit 1
grep -Fq 'build_cache_df_before=' "${probe}" || exit 1
grep -Fq 'build_cache_df_after=' "${probe}" || exit 1
grep -Fq 'probe_positive_control=${result}' "${probe}" || exit 1
grep -Fq -- '--entrypoint /bin/sleep' "${probe}" || exit 1
grep -Fq "'{{.State.Status}} {{.State.ExitCode}} {{.State.Error}} {{.State.Pid}}'" \
    "${probe}" || exit 1
grep -Fq 'systemctl is-system-running --wait' "${probe_diagnostics}" || exit 1
grep -Fq 'timeout --signal=TERM 90s' "${probe_diagnostics}" || exit 1
grep -Fq 'systemctl --failed --no-legend' "${probe_diagnostics}" || exit 1
grep -Fq 'docker logs --tail 40' "${probe}" || exit 1
grep -Fq 'cgroup_mount_options=' "${probe}" || exit 1
grep -Fq 'source "${fixtures}/docker-argv-audit.sh"' "${harness}" || exit 1
grep -Fq 'source "${root}/tests/session-authority-systemd/docker-argv-audit.sh"' \
    "${probe}" || exit 1
grep -Fq 'audit_docker_argv "$@"' "${probe}" || exit 1
grep -Fq 'systemd-docker-probe argv-audit: PASS docker' "${probe}" || exit 1
! grep -Fq 'probe_docker_run "$@"' "${probe}" || {
    echo 'session-authority systemd-safety: FAIL: probe audit fixture can execute Docker' >&2
    exit 1
}
! grep -Eq 'docker[[:space:]]+(run|create)([[:space:]]|$)' "${probe}" || {
    echo 'session-authority systemd-safety: FAIL: probe bypasses shared run auditor' >&2
    exit 1
}
[ "$(grep -Ec '^probe_candidate (a|e) ' "${probe}")" -eq 2 ] || exit 1
[ "$(grep -Ec '^probe_candidate ' "${probe}")" -eq 2 ] || exit 1
if grep -Eq -- 'source=/sys/fs/cgroup|src=/sys/fs/cgroup|seccomp=unconfined|systempaths=unconfined|--userns=host|nested-systemd|/usr/bin/unshare' \
    "${probe}" "${probe_recipe}"; then
    echo 'session-authority systemd-safety: FAIL: probe retains an unapproved discovery configuration' >&2
    exit 1
fi
grep -Fq 'UNSAFE_CONTAINER_ARGV: unapproved Docker run option=' \
    "${argv_audit}" || exit 1
grep -Fq 'baseline-systemd)' "${argv_audit}" || exit 1
grep -Fq 'positive-control)' "${argv_audit}" || exit 1
grep -Fq 'owner-exception)' "${argv_audit}" || exit 1
grep -Fq 'source "${root}/tests/session-authority-systemd/probe-diagnostics.sh"' \
    "${probe}" || exit 1
[ "$(grep -Fh 'collect_failed_units_and_cgroup "${name}"' \
    "${probe}" "${probe_diagnostics}" | wc -l)" -eq 2 ] || exit 1
[ "$(grep -Fc 'candidate_diagnostics_reason' "${probe}")" -eq 2 ] || exit 1
! grep -Fq 'buildx prune --force --all' \
    "${probe}" "${harness}" "${build_cache_audit}" || exit 1
grep -Fq 'source "${fixtures}/build-cache-audit.sh"' "${harness}" || exit 1
grep -Fq 'source "${root}/tests/session-authority-systemd/build-cache-audit.sh"' \
    "${probe}" || exit 1
! grep -Fq 'reason="boot_failed_$(docker logs' "${probe}" || exit 1
grep -Fq "grep -E '^(systemd-docker-probe:|probe_)'" "${workflow}" || exit 1
grep -Fq "needs.probe.outputs.candidate_e == 'pass'" "${workflow}" || exit 1
grep -Fq "needs.probe.outputs.adopted == 'e'" "${workflow}" || exit 1
grep -Fq "needs.probe.outputs.owner_exception == 'ephemeral-only'" "${workflow}" || exit 1
grep -Fqx 'STOPSIGNAL SIGRTMIN+3' "${probe_recipe}" || exit 1
grep -Fqx 'CMD ["/sbin/init"]' "${probe_recipe}" || exit 1
grep -Fq 'candidate_e=${candidate_e_result} adopted=${adopted} owner_exception=${owner_exception}' \
    "${probe}" || exit 1

# Exercise the shared cache reconciler without a Docker daemon. The baseline is
# deliberately non-empty. The run adds a child of a protected baseline record
# plus a new parent/child chain whose lexical order makes the old one-pass
# ID-only cleanup attempt the parent first and leak it.
cache_state="${tmp}/cache-records.jsonl"
cache_before="${tmp}/cache-before.tsv"
cache_after="${tmp}/cache-after.tsv"
cache_expected_prunes="${tmp}/cache-expected-prunes"
cache_du_counter="${tmp}/cache-du-counter"
export FAKE_CACHE_RECORDS="${cache_state}"
build_cache_builder=pf-sa-safety-cache
export FAKE_CACHE_BUILDER="${build_cache_builder}"
build_cache_docker() {
    DOCKER_CALL_LOG="${call_log}" "${fake_bin}/docker" "$@"
}
build_cache_cleanup_pause() {
    :
}
# shellcheck source=tests/session-authority-systemd/build-cache-audit.sh
source "${build_cache_audit}"
printf '%s\n' \
    '{"ID":"base-parent","Parents":["base-root"]}' \
    '{"ID":"base-root","Parents":null}' >"${cache_state}"
capture_build_cache_records "${cache_before}"
printf '%s\n' \
    '{"ID":"base-parent","Parents":["base-root"]}' \
    '{"ID":"base-root","Parents":null}' \
    '{"ID":"a-new-parent","Parents":["base-parent"]}' \
    '{"ID":"z-new-child","Parents":["a-new-parent"]}' \
    '{"ID":"m-new-baseline-child","Parents":["base-parent"]}' \
    >"${cache_state}"
export FAKE_CACHE_DU_COUNTER="${cache_du_counter}"
export FAKE_CACHE_LATE_RECORD='{"ID":"late-new","Parents":["base-root"]}'
reset_logs
cleanup_run_build_cache "${cache_before}" "${tmp}/cache-cleanup"
capture_build_cache_records "${cache_after}"
cmp -s "${cache_before}" "${cache_after}" || {
    echo 'session-authority systemd-safety: FAIL: cache cleanup did not restore exact baseline IDs' >&2
    exit 1
}
[ "${build_cache_records_removed}" -eq 4 ] || exit 1
[ -z "${build_cache_leftover_ids}" ] || exit 1
[ -z "${build_cache_missing_ids}" ] || exit 1
printf '%s\n' \
    'cmd=buildx prune --builder pf-sa-safety-cache --force --filter id=z-new-child' \
    'cmd=buildx prune --builder pf-sa-safety-cache --force --filter id=a-new-parent' \
    'cmd=buildx prune --builder pf-sa-safety-cache --force --filter id=m-new-baseline-child' \
    'cmd=buildx prune --builder pf-sa-safety-cache --force --filter id=late-new' \
    >"${cache_expected_prunes}"
grep -F 'cmd=buildx prune ' "${call_log}" | cmp -s - "${cache_expected_prunes}" \
    || exit 1
! grep -Fq 'id=base-parent' "${call_log}" || exit 1
! grep -Fq -- '--all' "${call_log}" || exit 1
unset FAKE_CACHE_DU_COUNTER FAKE_CACHE_LATE_RECORD

# A deliberately unprunable run-owned record must fail exact set equality and
# carry the leftover ID in the machine-readable failure reason.
printf '%s\n' \
    '{"ID":"base-parent","Parents":["base-root"]}' \
    '{"ID":"base-root","Parents":null}' \
    '{"ID":"stuck-new","Parents":["base-parent"]}' \
    >"${cache_state}"
export FAKE_CACHE_STUCK_ID=stuck-new
if cleanup_run_build_cache "${cache_before}" "${tmp}/cache-stuck"; then
    echo 'session-authority systemd-safety: FAIL: leftover cache record passed exact audit' >&2
    exit 1
fi
[ "$(build_cache_drift_reason)" = \
    'BUILD_CACHE_USAGE_DRIFT:leftover_ids=stuck-new;missing_ids=none' ] || exit 1
unset FAKE_CACHE_STUCK_ID FAKE_CACHE_RECORDS FAKE_CACHE_BUILDER

echo 'session-authority systemd-safety: PASS graphical_refusal=ok ephemeral_guard=ok fixture_root_modes=external-docker-refused owner_exception=ephemeral-only exception_non_ephemeral=refused exception_graphical=refused-zero-docker other_forbidden=refused run_allowlist=ok probe_host_cgroup_bind=refused-zero-docker probe_fixture=audit-only probe_argv_audit=shared probe_matrix=approved-only docker_root_disk=ok disk_floor_abort=ok docker_metrics=before-after cache_baseline=exact cache_parent_graph=child-first cache_leftover_ids=reported argv_audit=ok docker_lifecycle=ok builder_stage=ok path_preconditions=1 shell_fixture_parity=ok fb0=regular workflow=pf-builder-vm probe_positive_control=static probe_diagnostics=fake-docker getty_masks=5 runtime=fake-docker'
