#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-system-volume.XXXXXX")
trap 'find "$tmp" -mindepth 1 -delete; rmdir "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

check_recipe() {
    local dockerfile=$1 rootfs=$2
    local token
    for token in \
        '-p pf-volumed --bin pf-volumed' \
        'install -D -m 0755 "${VOLUMED_BIN}" /out/bin/pf-volumed' \
        'systemd/pf-volumed.service /out/systemd/pf-volumed.service'; do
        grep -F -- "$token" "$dockerfile" >/dev/null || return 1
    done
    for token in \
        'install -D -m 0755 "${VOLUMED_BIN}" "${ROOTFS}/usr/bin/pf-volumed"' \
        '"${RUNTIME_DIR}/systemd/pf-volumed.service"' \
        'multi-user.target.wants/pf-volumed.service' \
        '73-pocketforge-headphone-jack.rules'; do
        grep -F -- "$token" "$rootfs" >/dev/null || return 1
    done
}

check_recipe "$repo/build/Dockerfile.pf" "$repo/scripts/build-rootfs.sh" \
    || fail "runtime recipe does not build, stage, install, and enable pf-volumed"

cp "$repo/build/Dockerfile.pf" "$tmp/Dockerfile.pf"
sed -i '/pf-volumed/d' "$tmp/Dockerfile.pf"
if check_recipe "$tmp/Dockerfile.pf" "$repo/scripts/build-rootfs.sh"; then
    fail "negative control: recipe checker accepted a Dockerfile without pf-volumed"
fi

rule="$repo/rootfs-overlay/etc/udev/rules.d/73-pocketforge-headphone-jack.rules"
check_rule() {
    grep -F -- 'ATTRS{name}=="H616 Audio Codec Headphone Jack"' "$1" >/dev/null \
        && grep -F -- 'GROUP="audio"' "$1" >/dev/null && grep -F -- 'MODE="0660"' "$1" >/dev/null
}
check_rule "$rule" || fail "jack udev rule does not give the codec jack node to the audio group"
sed 's/GROUP="audio"/GROUP="input"/' "$rule" > "$tmp/jack.rules"
if check_rule "$tmp/jack.rules"; then
    fail "negative control: rule checker accepted a jack rule outside the audio group"
fi

defaults="$repo/device-config/alsa/mixer-defaults.sun4i-codec-7.x"
fixture="$repo/tests/fixtures/alsa/sun4i-codec-controls.kernel-sunxi-7.x.tsv"
[ -f "$defaults" ] || fail "kernel 7.x mixer defaults are missing"

grep -Fqx 'DAC Playback Volume=38' "$defaults" \
    || fail "7.x defaults do not start the shared DAC at the 60 percent speaker preference"
grep -Fqx 'Headphone Playback Volume=0' "$defaults" \
    || fail "7.x defaults do not pin the driver-reference headphone gain"
if grep -Eq '^(Line Out|DAC Playback Switch|DAC Reversed)' "$defaults"; then
    fail "7.x defaults still name obsolete H616-route controls"
fi
for control in 'DAC Playback Volume' 'Line Out Playback Volume' \
               'Line Out Differential Playback Switch' 'Headphone Playback Volume' \
               'Headphone Switch' 'Speaker Switch' 'Headphone Jack'; do
    grep -F -- "$control" "$fixture" >/dev/null \
        || fail "7.x control fixture omits $control"
done
grep -F -- 'mixer-defaults.sun4i-codec-7.x' "$repo/scripts/install-alsa-config.sh" >/dev/null \
    || fail "ALSA installer does not select the kernel 7.x defaults"

echo "PASS: pf-volumed image wiring and A133 7.x mixer defaults"
