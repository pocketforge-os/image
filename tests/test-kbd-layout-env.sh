#!/bin/bash
# =============================================================================
# test-kbd-layout-env.sh: keyboardLayout preference -> XKB_DEFAULT_* env
# =============================================================================
# Hermetic (no docker, no network, no device): runs the production generator
# rootfs-overlay/usr/lib/pocketforge/kbd-layout-env against fixture store/seed
# documents through its test seams and asserts the rendered EnvironmentFile,
# the stored>seed>default precedence, visible-failure/usable-fallback behaviour
# on corrupt provisioning data, and the unit / build-rootfs.sh wiring contract.
#
# bd: tsp-ihne1.6
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENERATOR="${SRC_DIR}/rootfs-overlay/usr/lib/pocketforge/kbd-layout-env"
UNIT="${SRC_DIR}/rootfs-overlay/etc/systemd/system/pf-kbd-layout-env.service"
GAMESCOPE_UNIT="${SRC_DIR}/rootfs-overlay/etc/systemd/system/pocketforge-gamescope.service"
FCITX_DROPIN="${SRC_DIR}/rootfs-overlay/etc/systemd/system/pf-fcitx5.service.d/10-pf-ime-sandbox.conf"

SCRATCH="$(mktemp -d "${RUNNER_TEMP:-/tmp}/kbd-layout-env.XXXXXX")"
cleanup() {
    find "${SCRATCH}" -mindepth 1 -delete
    rmdir "${SCRATCH}"
}
trap cleanup EXIT

# Minimal xkb rules fixture: the closed set the generator must enforce
# membership against (the device uses /usr/share/X11/xkb/rules/evdev.xml).
RULES_XML="${SCRATCH}/evdev.xml"
cat > "${RULES_XML}" <<'XML'
<?xml version="1.0"?>
<xkbConfigRegistry version="1.1">
  <layoutList>
    <layout>
      <configItem><name>us</name></configItem>
      <variantList>
        <variant><configItem><name>intl</name></configItem></variant>
        <variant><configItem><name>dvorak</name></configItem></variant>
      </variantList>
    </layout>
    <layout>
      <configItem><name>de</name></configItem>
      <variantList>
        <variant><configItem><name>nodeadkeys</name></configItem></variant>
      </variantList>
    </layout>
    <layout>
      <configItem><name>gb</name></configItem>
      <variantList>
        <variant><configItem><name>extd</name></configItem></variant>
      </variantList>
    </layout>
    <layout><configItem><name>fr</name></configItem></layout>
  </layoutList>
</xkbConfigRegistry>
XML

run_generator() {
    # run_generator <store-file> <seed-file> <env-file>
    PF_KBD_PREFS_FILE="$1" PF_KBD_SEED_FILE="$2" PF_KBD_ENV_FILE="$3" \
        PF_KBD_RULES_XML="${RULES_XML}" \
        python3 -B "${GENERATOR}"
}

env_value() {
    # env_value <env-file> <KEY> — sources the rendered EnvironmentFile and
    # echoes the value (positive control: the file really is shell-sourceable).
    local file="$1" key="$2"
    (
        set -a
        # shellcheck disable=SC1090
        . "${file}"
        set +a
        eval "printf '%s\n' \"\${${key}}\""
    )
}

fail() {
    echo "FAIL: test-kbd-layout-env reason=$1 hint=$2"
    exit 1
}

consumer_has_layout_env() {
    local consumer=$1
    ! grep -Eq '^Requires=(.*[[:space:]])?pf-kbd-layout-env\.service([[:space:]].*)?$' \
        "${consumer}" \
        && grep -Eq '^Wants=(.*[[:space:]])?pf-kbd-layout-env\.service([[:space:]].*)?$' \
            "${consumer}" \
        && grep -Eq '^After=(.*[[:space:]])?pf-kbd-layout-env\.service([[:space:]].*)?$' \
            "${consumer}" \
        && grep -Fxq 'EnvironmentFile=-/run/pocketforge/kbd-layout.env' "${consumer}"
}

assert_fallback() {
    local file=$1 expected_error=$2
    [ -f "${file}" ] || fail fallback_missing "${file} was not published"
    [ "$(env_value "${file}" XKB_DEFAULT_LAYOUT)" = "us" ] \
        || fail fallback_layout "${file} must use layout us"
    [ "$(env_value "${file}" XKB_DEFAULT_VARIANT)" = "" ] \
        || fail fallback_variant "${file} must use the empty US variant"
    [ "$(env_value "${file}" PF_KEYBOARD_LAYOUT)" = "us" ] \
        || fail fallback_token "${file} must expose token us"
    [ "$(env_value "${file}" PF_KEYBOARD_LAYOUT_SOURCE)" = "fallback" ] \
        || fail fallback_source "${file} must mark source=fallback"
    [ "$(env_value "${file}" PF_KEYBOARD_LAYOUT_ERROR)" = "${expected_error}" ] \
        || fail fallback_error "${file} must expose ${expected_error}"
    [ "$(stat -c %a "${file}")" = "644" ] \
        || fail fallback_mode "${file} must be published mode 0644"
}

# --- 1. no store, no seed: the schema default renders -------------------------
d="${SCRATCH}/default"
mkdir -p "${d}"
run_generator "${d}/prefs.json" "${d}/prefs.seed.json" "${d}/kbd.env"
[ "$(env_value "${d}/kbd.env" PF_KEYBOARD_LAYOUT)" = "us" ] \
    || fail default_token "expected us without store or seed"
[ "$(env_value "${d}/kbd.env" PF_KEYBOARD_LAYOUT_SOURCE)" = "default" ] \
    || fail default_source "expected source=default"
[ "$(env_value "${d}/kbd.env" XKB_DEFAULT_LAYOUT)" = "us" ] \
    || fail default_layout "expected XKB_DEFAULT_LAYOUT=us"
[ "$(env_value "${d}/kbd.env" XKB_DEFAULT_VARIANT)" = "" ] \
    || fail default_variant "expected empty XKB_DEFAULT_VARIANT"
[ "$(env_value "${d}/kbd.env" XKB_DEFAULT_RULES)" = "evdev" ] \
    || fail default_rules "expected XKB_DEFAULT_RULES=evdev"
[ "$(stat -c %a "${d}/kbd.env")" = "644" ] \
    || fail default_mode "env file must be 0644"

# --- 2. cloud-init seed renders a layout(variant) token -----------------------
d="${SCRATCH}/seed"
mkdir -p "${d}"
printf '{"keyboardLayout":"de(nodeadkeys)"}\n' > "${d}/prefs.seed.json"
run_generator "${d}/prefs.json" "${d}/prefs.seed.json" "${d}/kbd.env"
[ "$(env_value "${d}/kbd.env" XKB_DEFAULT_LAYOUT)" = "de" ] \
    || fail seed_layout "seeded de(nodeadkeys) must render layout de"
[ "$(env_value "${d}/kbd.env" XKB_DEFAULT_VARIANT)" = "nodeadkeys" ] \
    || fail seed_variant "seeded de(nodeadkeys) must render variant nodeadkeys"
[ "$(env_value "${d}/kbd.env" PF_KEYBOARD_LAYOUT_SOURCE)" = "seed" ] \
    || fail seed_source "expected source=seed"

# --- 3. explicit store wins over the seed -------------------------------------
d="${SCRATCH}/stored"
mkdir -p "${d}"
printf '{"keyboardLayout":"de(nodeadkeys)"}\n' > "${d}/prefs.seed.json"
printf '{"schemaVersion":2,"keyboardLayout":"gb(extd)","hapticsEnabled":false}\n' \
    > "${d}/prefs.json"
run_generator "${d}/prefs.json" "${d}/prefs.seed.json" "${d}/kbd.env"
[ "$(env_value "${d}/kbd.env" PF_KEYBOARD_LAYOUT)" = "gb(extd)" ] \
    || fail stored_wins "explicit store value must beat the seed"
[ "$(env_value "${d}/kbd.env" PF_KEYBOARD_LAYOUT_SOURCE)" = "stored" ] \
    || fail stored_source "expected source=stored"

# --- 4. a store WITHOUT the key falls through to the seed ---------------------
d="${SCRATCH}/fallthrough"
mkdir -p "${d}"
printf '{"keyboardLayout":"fr"}\n' > "${d}/prefs.seed.json"
printf '{"schemaVersion":2,"hapticsEnabled":false}\n' > "${d}/prefs.json"
run_generator "${d}/prefs.json" "${d}/prefs.seed.json" "${d}/kbd.env"
[ "$(env_value "${d}/kbd.env" PF_KEYBOARD_LAYOUT)" = "fr" ] \
    || fail fallthrough "a store without keyboardLayout must not mask the seed"
[ "$(env_value "${d}/kbd.env" PF_KEYBOARD_LAYOUT_SOURCE)" = "seed" ] \
    || fail fallthrough_source "expected source=seed"

# --- 5. negative controls: bad data fails visibly with a usable fallback ------
d="${SCRATCH}/fallback-red"
mkdir -p "${d}"
printf '{"keyboardLayout":"de(nodeadkey)"}\n' > "${d}/prefs.seed.json"
if run_generator "${d}/prefs.json" "${d}/prefs.seed.json" "${d}/kbd.env" \
    2>"${d}/stderr"; then
    fail fallback_rc "invalid seed variant must still exit nonzero"
fi
assert_fallback "${d}/kbd.env" variant_not_shipped

d="${SCRATCH}/failclosed"
mkdir -p "${d}"
printf 'PREVIOUS=1\n' > "${d}/kbd.env"
# A shipped layout(variant) pair must pass (positive control for the
# membership checks below).
printf '{"keyboardLayout":"us(intl)"}\n' > "${d}/prefs.seed.json"
run_generator "${d}/prefs.json" "${d}/prefs.seed.json" "${d}/kbd2.env"
[ "$(env_value "${d}/kbd2.env" XKB_DEFAULT_VARIANT)" = "intl" ] \
    || fail positive_variant "shipped us(intl) must render variant intl"
for case in \
    "klingon:layout-not-shipped:layout_not_shipped" \
    "us(bogus):variant-not-shipped:variant_not_shipped" \
    "de(:broken-grammar:token_grammar" \
    "42:non-string:preference_not_string"; do
    seed="${case%%:*}"
    rest="${case#*:}"
    label="${rest%%:*}"
    error_class="${case##*:}"
    printf '{"keyboardLayout":%s}\n' \
        "$([ "${seed}" = "42" ] && echo 42 || echo "\"${seed}\"")" \
        > "${d}/prefs.seed.json"
    if run_generator "${d}/prefs.json" "${d}/prefs.seed.json" "${d}/kbd.env" \
        2>"${d}/stderr"; then
        fail "negative_${label}" "generator must exit nonzero (seed=${seed})"
    fi
    grep -q 'FAIL' "${d}/stderr" \
        || fail "negative_${label}" "generator must print a FAIL reason"
    assert_fallback "${d}/kbd.env" "${error_class}"
done
# Corrupt/empty JSON documents fail closed too.
printf '{"keyboardLayout":"de"' > "${d}/prefs.seed.json"
if run_generator "${d}/prefs.json" "${d}/prefs.seed.json" "${d}/kbd.env" \
    2>/dev/null; then
    fail negative_corrupt_json "truncated seed JSON must exit nonzero"
fi
assert_fallback "${d}/kbd.env" preference_json
: > "${d}/prefs.seed.json"
if run_generator "${d}/prefs.json" "${d}/prefs.seed.json" "${d}/kbd.env" \
    2>/dev/null; then
    fail negative_empty_seed "an empty seed file must exit nonzero"
fi
assert_fallback "${d}/kbd.env" preference_empty
# A missing xkb rules file fails closed instead of guessing membership.
printf '{"keyboardLayout":"de"}\n' > "${d}/prefs.seed.json"
if PF_KBD_PREFS_FILE="${d}/prefs.json" PF_KBD_SEED_FILE="${d}/prefs.seed.json" \
    PF_KBD_ENV_FILE="${d}/kbd.env" \
    PF_KBD_RULES_XML="${d}/absent.xml" \
    python3 -B "${GENERATOR}" 2>/dev/null; then
    fail negative_missing_rules "a missing xkb rules file must exit nonzero"
fi
assert_fallback "${d}/kbd.env" rules_read_failed

# --- 6. unit + build wiring contract ------------------------------------------
grep -q '^Type=oneshot$' "${UNIT}" || fail unit_type "unit must be oneshot"
grep -q '^ExecStart=/usr/lib/pocketforge/kbd-layout-env$' "${UNIT}" \
    || fail unit_execstart "ExecStart must match the installed generator path"
grep -q '^Before=pf-shell-selected.service$' "${UNIT}" \
    || fail unit_before "session units must be able to order after the generator"
for consumer in "${GAMESCOPE_UNIT}" "${FCITX_DROPIN}"; do
    consumer_has_layout_env "${consumer}" \
        || fail consumer_wiring \
            "${consumer} must want/order after the generator and optionally load its EnvironmentFile"
done
# Negative controls prove the contract rejects Requires= (which would make a
# bad preference fatal to the consumer), missing ordering, or a missing import.
cp "${GAMESCOPE_UNIT}" "${SCRATCH}/consumer-requires.service"
printf 'Requires=pf-kbd-layout-env.service\n' \
    >> "${SCRATCH}/consumer-requires.service"
if consumer_has_layout_env "${SCRATCH}/consumer-requires.service"; then
    fail negative_consumer_requires "consumer with generator Requires= passed"
fi
cp "${GAMESCOPE_UNIT}" "${SCRATCH}/consumer-missing-after.service"
sed -i '/^After=/s/ pf-kbd-layout-env\.service//' \
    "${SCRATCH}/consumer-missing-after.service"
if consumer_has_layout_env "${SCRATCH}/consumer-missing-after.service"; then
    fail negative_consumer_after "consumer without generator ordering passed"
fi
cp "${GAMESCOPE_UNIT}" "${SCRATCH}/consumer-missing-env.service"
sed -i '\|^EnvironmentFile=-/run/pocketforge/kbd-layout.env$|d' \
    "${SCRATCH}/consumer-missing-env.service"
if consumer_has_layout_env "${SCRATCH}/consumer-missing-env.service"; then
    fail negative_consumer_env "consumer without EnvironmentFile passed"
fi
# No install-target cycle: multi-user.target must not appear in After=.
if grep '^After=' "${UNIT}" | grep -q 'multi-user.target'; then
    fail unit_cycle "install target must not appear in After="
fi
grep -q 'rootfs-overlay/usr/lib/pocketforge/kbd-layout-env' \
    "${SRC_DIR}/scripts/build-rootfs.sh" \
    || fail wiring_script "build-rootfs.sh must install the generator"
grep -q 'multi-user.target.wants/pf-kbd-layout-env.service' \
    "${SRC_DIR}/scripts/build-rootfs.sh" \
    || fail wiring_enable "build-rootfs.sh must enable the unit"

echo "PASS: test-kbd-layout-env (precedence, visible-failure fallback, unit wiring)"
