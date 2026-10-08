#!/usr/bin/env bash
# =============================================================================
# test-alsa-config.sh: the ALSA card configuration follows the kernel (bd tsp-f3fm.220)
# =============================================================================
# The codec card id depends on the kernel, not the GPU model. The vendor 4.9
# kernel names it "audiocodec"; the open 6.x/7.x kernels' mainline sun4i-codec
# names it "Codec" and exposes no capture device. Image main wrote the stock
# vendor asound.conf for every profile, so on the open 7.x kernel the ALSA
# default device could not resolve ("Cannot get card index for audiocodec")
# and Poolsuite never opened audio (tsp-f3fm.215 boot P4).
#
# Hermetic: tmpdir rootfs fixtures, the real scripts/build-rootfs.sh hook
# generation (tests/lib/capture-customize-hook.sh), python3, fake amixer and
# udevadm on PATH. No docker, network or device.
#
# Checks:
#   1. wiring: the real generated customize hook receives PF_KERNEL_REPO and
#      delegates /etc/asound.conf to scripts/install-alsa-config.sh; it does
#      not write the file itself. The Dockerfile.pf rootfs stage passes it.
#   2. every open-kernel profile: the rendered asound.conf names only card id
#      "Codec", never an index; the mixer defaults name only controls in the
#      driver fixture for that kernel pin, with in-range values; the defaults
#      unit is installed and enabled under sound.target.
#   3. every vendor-kernel profile: asound.conf is byte-identical to stock.
#   4. an empty or unknown kernel repo fails the install.
#   5. audio-defaults.sh applies every line with amixer on card Codec and
#      fails when a control or the card is missing.
#   6. unit graph: no install target (WantedBy=/RequiredBy=) of
#      pocketforge-audio-defaults.service appears in its After= (static
#      rule); and systemd-analyze verify over the rendered rootfs (with stubs
#      for the Debian alsa units) loads the unit, pulls it in from
#      sound.target, and finds no ordering cycle. The verify detector is
#      proven in the same run on a fixture pair with a real ordering cycle.
#      systemd-analyze is required under GitHub Actions, optional locally.
# Controls in the same run: the checkers must reject the stock file on an
# open kernel (the bytes image main shipped there) and a defaults file
# naming a vendor control; and this test, run over image main before the fix
# (PRE_FIX_COMMIT, read with git archive, so it needs full history), must fail
# for the bug's reason.
# =============================================================================
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/lib/capture-customize-hook.sh
. "${REPO_DIR}/tests/lib/capture-customize-hook.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# sha256 of the stock vendor asound.conf, as image 40db72ec/3c2ac54
# scripts/build-rootfs.sh wrote it (hardware-firmware-probes.md §12).
STOCK_SHA256=bc19e036d6348e49d4dfc13ab907a0bceef6b424399eb10b7ebfea8c81fca321
OPEN_CARD=Codec
# Image main before this fix (tsp-f3fm.220): the negative control's tree.
PRE_FIX_COMMIT=3c2ac542464055cef5dcbfab238eab25bc8d17e8
# PR image#158 first head, whose unit listed its own install target
# (sound.target) in After=: the negative control for the static unit rule.
AFTER_INSTALL_TARGET_COMMIT=27a1c491cdd79abb082c19fcf7fc9d658e1aefe1
UNIT_PATH=rootfs-overlay/etc/systemd/system/pocketforge-audio-defaults.service

# Profiles as the platform repo defines them today (devices/*/profile.toml
# kernel.repo). The installer keys on the kernel repo, so a new profile on a
# known kernel needs no change here, and a new kernel repo fails the build.
PROFILES=(
    "a133:kernel-sunxi-4.9"
    "a133-owned:kernel-sunxi-4.9"
    "a133-open:kernel-sunxi-6.x"
    "a133-open-7x:kernel-sunxi-7.x"
    "a133-open-7x-gpu:kernel-sunxi-7.x"
    "a133-open-7x-gpu-cts:kernel-sunxi-7.x"
    "a133-open-7x-gpu-noradio:kernel-sunxi-7.x"
    "a133-open-7x-gpu-spl-trace:kernel-sunxi-7.x"
)

# check_open_asound FILE: print nothing and succeed when every card reference
# is the id "Codec" and the default chain reaches hw:Codec,0; otherwise print
# the reasons and fail.
check_open_asound() {
    python3 - "$1" "${OPEN_CARD}" <<'PY'
import re, sys
path, want = sys.argv[1], sys.argv[2]
text = open(path).read()
body = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
refs = []
refs += re.findall(r'\bcard\s+"?([^\s"}]+)"?', body)
refs += re.findall(r'\b(?:plug)?hw:([^,"\s}]+)', body)
refs += re.findall(r'\bCARD=([^,"\s}]+)', body)
problems = []
if not refs:
    problems.append("no card reference at all")
for ref in sorted(set(refs)):
    if ref.isdigit():
        problems.append(f"card index {ref} (must be referenced by id)")
    elif ref != want:
        problems.append(f"card id '{ref}' is not exposed by the open kernel (only '{want}')")
for needle, what in ((r'ctl\.!default\s*\{', "ctl.!default"),
                     (r'pcm\.!default\s*\{', "pcm.!default"),
                     (r'pcm\s+"hw:' + re.escape(want) + r',0"', f"dmix slave hw:{want},0")):
    if not re.search(needle, body):
        problems.append(f"missing {what}")
if problems:
    print("; ".join(problems))
    sys.exit(1)
PY
}

# check_mixer_defaults DEFAULTS FIXTURE: every NAME=VALUE names a control in
# the driver fixture and VALUE is valid for its kind.
check_mixer_defaults() {
    python3 - "$1" "$2" <<'PY'
import sys
defaults, fixture = sys.argv[1], sys.argv[2]
controls = {}
for line in open(fixture):
    if not line.strip() or line.startswith("#"):
        continue
    name, kind, spec, _src = line.rstrip("\n").split("\t")
    controls[name] = (kind, spec)
problems, seen = [], 0
for n, line in enumerate(open(defaults), 1):
    line = line.rstrip("\n")
    if not line.strip() or line.startswith("#"):
        continue
    if "=" not in line:
        problems.append(f"line {n}: not NAME=VALUE: {line!r}")
        continue
    seen += 1
    name, value = line.split("=", 1)
    if name not in controls:
        problems.append(f"line {n}: control '{name}' does not exist in the driver")
        continue
    kind, spec = controls[name]
    for v in value.split(","):
        if kind == "bool" and v not in ("on", "off"):
            problems.append(f"line {n}: '{name}' is a switch, value {v!r} is not on/off")
        elif kind == "int":
            lo, hi = (int(x) for x in spec.split())
            if not (v.isdigit() and lo <= int(v) <= hi):
                problems.append(f"line {n}: '{name}' value {v!r} outside {lo}..{hi}")
        elif kind == "enum" and v not in spec.split("|"):
            problems.append(f"line {n}: '{name}' value {v!r} is not one of {spec}")
if seen == 0:
    problems.append("no NAME=VALUE lines")
if problems:
    print("; ".join(problems))
    sys.exit(1)
PY
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# ---- controls: the checkers must reject what image main shipped ------------
stock="${REPO_DIR}/device-config/alsa/asound.conf.sunxi-vendor"
[ -f "${stock}" ] || fail "stock vendor asound.conf source missing: ${stock}"
[ "$(sha256_of "${stock}")" = "${STOCK_SHA256}" ] \
    || fail "device-config/alsa/asound.conf.sunxi-vendor is not the stock file (sha256 $(sha256_of "${stock}"), want ${STOCK_SHA256})"
if reason="$(check_open_asound "${stock}")"; then
    fail "control: checker accepted the stock vendor asound.conf for an open kernel"
fi
case "${reason}" in
    *"'audiocodec'"*"'sndac10710036'"*) ;;
    *) fail "control: checker rejected the stock file for the wrong reason: ${reason}" ;;
esac
echo "NEGATIVE CONTROL: image main's asound.conf on an open kernel is rejected: ${reason}"

printf 'LINEOUT volume=20\nHpSpeaker Switch=on\n' > "${TMP}/vendor-mixer"
if reason="$(check_mixer_defaults "${TMP}/vendor-mixer" "${REPO_DIR}/tests/fixtures/alsa/sun4i-codec-controls.kernel-sunxi-7.x.tsv")"; then
    fail "control: mixer checker accepted vendor control names"
fi
echo "NEGATIVE CONTROL: vendor mixer control names are rejected: ${reason}"

# ---- 1. wiring through the real build-rootfs.sh hook generation ------------
hook="${TMP}/customize-hook.sh"
capture_customize_hook "${REPO_DIR}" "${TMP}/hook-fixture" "${hook}" \
    || fail "could not capture the generated customize hook"
if grep -nE '(>|tee)[^|;&]*etc/asound\.conf' "${hook}"; then
    fail "the customize hook writes /etc/asound.conf itself (image main: the stock card-audiocodec file for every profile) instead of choosing it by kernel"
fi
grep -Eq '(^|[[:space:]])PF_KERNEL_REPO=kernel-sunxi-7\.x([[:space:]]|$)' "${hook}.cmd" \
    || fail "the customize hook command does not pass PF_KERNEL_REPO: $(cat "${hook}.cmd")"
grep -Fq '/work/src/scripts/install-alsa-config.sh "${PF_KERNEL_REPO}" "${ROOTFS}" /work/src' "${hook}" \
    || fail "the customize hook does not install /etc/asound.conf via install-alsa-config.sh keyed on PF_KERNEL_REPO"
pass "customize hook: PF_KERNEL_REPO reaches it and install-alsa-config.sh owns /etc/asound.conf"

rootfs_stage="$(awk '/^FROM .* AS rootfs$/{f=1} f&&/^FROM /&&!/ AS rootfs$/{f=0} f' "${REPO_DIR}/build/Dockerfile.pf")"
grep -qx 'ARG PF_KERNEL_REPO' <<<"${rootfs_stage}" \
    || fail "Dockerfile.pf rootfs stage does not declare ARG PF_KERNEL_REPO"
grep -Fq 'PF_KERNEL_REPO="${PF_KERNEL_REPO}"' <<<"${rootfs_stage}" \
    || fail "Dockerfile.pf rootfs stage does not pass PF_KERNEL_REPO to build-rootfs.sh"
pass "Dockerfile.pf rootfs stage passes PF_KERNEL_REPO"

grep -qx 'alsa-utils' "${REPO_DIR}/rootfs-packages.txt" \
    || fail "rootfs-packages.txt lacks alsa-utils (audio-defaults.sh needs amixer)"

# ---- 2/3. render per profile ----------------------------------------------
for entry in "${PROFILES[@]}"; do
    profile="${entry%%:*}"
    kernel="${entry#*:}"
    root="${TMP}/rootfs-${profile}"
    mkdir -p "${root}"
    "${REPO_DIR}/scripts/install-alsa-config.sh" "${kernel}" "${root}" "${REPO_DIR}" > "${TMP}/install-${profile}.log" \
        || fail "${profile}: install-alsa-config.sh ${kernel} failed: $(cat "${TMP}/install-${profile}.log")"
    conf="${root}/etc/asound.conf"
    [ -f "${conf}" ] || fail "${profile}: no /etc/asound.conf rendered"
    [ "$(stat -c %a "${conf}")" = 644 ] || fail "${profile}: /etc/asound.conf mode $(stat -c %a "${conf}"), want 644"
    case "${kernel}" in
        kernel-sunxi-4.9)
            [ "$(sha256_of "${conf}")" = "${STOCK_SHA256}" ] \
                || fail "${profile}: vendor asound.conf is not byte-identical to stock"
            for absent in usr/share/pocketforge/alsa usr/lib/pocketforge/audio-defaults.sh \
                          etc/systemd/system/pocketforge-audio-defaults.service \
                          etc/systemd/system/sound.target.wants; do
                [ ! -e "${root}/${absent}" ] || fail "${profile}: vendor rootfs gained ${absent}"
            done
            pass "${profile} (${kernel}): stock asound.conf byte-identical (sha256 ${STOCK_SHA256}), no mixer defaults"
            ;;
        *)
            reason="$(check_open_asound "${conf}")" \
                || fail "${profile} (${kernel}): rendered asound.conf: ${reason}"
            fixture="${REPO_DIR}/tests/fixtures/alsa/sun4i-codec-controls.${kernel}.tsv"
            [ -f "${fixture}" ] || fail "${profile}: no driver control fixture for ${kernel}"
            defaults="${root}/usr/share/pocketforge/alsa/mixer-defaults.sun4i-codec"
            [ -f "${defaults}" ] || fail "${profile}: mixer defaults not installed"
            reason="$(check_mixer_defaults "${defaults}" "${fixture}")" \
                || fail "${profile} (${kernel}): mixer defaults: ${reason}"
            script="${root}/usr/lib/pocketforge/audio-defaults.sh"
            unit="${root}/etc/systemd/system/pocketforge-audio-defaults.service"
            link="${root}/etc/systemd/system/sound.target.wants/pocketforge-audio-defaults.service"
            [ -x "${script}" ] || fail "${profile}: audio-defaults.sh not installed executable"
            [ -f "${unit}" ] || fail "${profile}: pocketforge-audio-defaults.service not installed"
            [ "$(readlink "${link}")" = /etc/systemd/system/pocketforge-audio-defaults.service ] \
                || fail "${profile}: pocketforge-audio-defaults.service not enabled under sound.target.wants"
            grep -qx 'ExecStart=/usr/lib/pocketforge/audio-defaults.sh' "${unit}" \
                || fail "${profile}: unit ExecStart does not run the installed script"
            grep -Fqx 'CARD="${PF_AUDIO_CARD:-Codec}"' "${script}" \
                || fail "${profile}: audio-defaults.sh does not target card ${OPEN_CARD}"
            grep -Fq '/usr/share/pocketforge/alsa/mixer-defaults.sun4i-codec' "${script}" \
                || fail "${profile}: audio-defaults.sh does not read the installed defaults file"
            pass "${profile} (${kernel}): asound.conf names only card ${OPEN_CARD}; mixer defaults match the driver fixture; unit enabled"
            ;;
    esac
done

# ---- 6. unit graph ---------------------------------------------------------
# check_unit_install_order UNIT: no WantedBy=/RequiredBy=/UpheldBy= target may
# appear in After=. A target orders itself after what it Wants
# (systemd.target(5)), so such a unit orders itself after a target that is
# ordered after it; systemd only suppresses that loop by special case.
check_unit_install_order() {
    python3 - "$1" <<'PY2'
import sys
after, install = set(), set()
section = None
for raw in open(sys.argv[1]):
    line = raw.strip()
    if not line or line[0] in "#;":
        continue
    if line.startswith("[") and line.endswith("]"):
        section = line[1:-1]
        continue
    if "=" not in line:
        continue
    key, value = (x.strip() for x in line.split("=", 1))
    if section == "Unit" and key == "After":
        after.update(value.split()) if value else after.clear()
    elif section == "Install" and key in ("WantedBy", "RequiredBy", "UpheldBy"):
        install.update(value.split())
if not install:
    print("no WantedBy=/RequiredBy=/UpheldBy= install target")
    sys.exit(1)
bad = sorted(install & after)
if bad:
    print("install target(s) " + ", ".join(bad) + " also in After=: the target is ordered after this unit, so the unit must not order itself after the target")
    sys.exit(1)
PY2
}

unit_src="${REPO_DIR}/${UNIT_PATH}"
reason="$(check_unit_install_order "${unit_src}")" \
    || fail "pocketforge-audio-defaults.service: ${reason}"
grep -qx 'WantedBy=sound.target' "${unit_src}" \
    || fail "pocketforge-audio-defaults.service is not WantedBy=sound.target (install-alsa-config.sh links it into sound.target.wants)"
if [ -z "${PF_ALSA_NEGATIVE_RUN:-}" ]; then
    git -C "${REPO_DIR}" show "${AFTER_INSTALL_TARGET_COMMIT}:${UNIT_PATH}" > "${TMP}/unit-27a1c49" \
        || fail "control: cannot read ${AFTER_INSTALL_TARGET_COMMIT}:${UNIT_PATH} (needs full git history)"
    if reason="$(check_unit_install_order "${TMP}/unit-27a1c49")"; then
        fail "control: static unit rule accepted the ${AFTER_INSTALL_TARGET_COMMIT:0:12} unit (After=sound.target + WantedBy=sound.target)"
    fi
    echo "NEGATIVE CONTROL: unit at ${AFTER_INSTALL_TARGET_COMMIT:0:12} is rejected: ${reason}"
fi
pass "pocketforge-audio-defaults.service: no install target in After="

# stage_verify_root DIR: minimal unit universe for systemd-analyze --root.
stage_verify_root() {
    local root="$1" units="$1/usr/lib/systemd/system" t
    mkdir -p "${units}/sound.target.wants" "${root}/bin"
    cp /bin/true "${root}/bin/true"
    for t in sysinit.target basic.target shutdown.target; do
        printf '[Unit]\nDescription=stub %s\n' "${t}" > "${units}/${t}"
    done
    # systemd's own sound.target (units/sound.target): no dependencies of
    # its own; udev starts it on card hotplug.
    printf '[Unit]\nDescription=Sound Card\nDocumentation=man:systemd.special(7)\nStopWhenUnneeded=yes\n' \
        > "${units}/sound.target"
}

if command -v systemd-analyze >/dev/null 2>&1; then
    # Detector control: a real ordering cycle must be reported.
    cyc="${TMP}/verify-cycle"
    stage_verify_root "${cyc}"
    printf '[Unit]\nWants=cyc-b.service\nAfter=cyc-b.service\n[Service]\nType=oneshot\nExecStart=/bin/true\n' \
        > "${cyc}/usr/lib/systemd/system/cyc-a.service"
    printf '[Unit]\nAfter=cyc-a.service\n[Service]\nType=oneshot\nExecStart=/bin/true\n' \
        > "${cyc}/usr/lib/systemd/system/cyc-b.service"
    systemd-analyze verify --man=no --root="${cyc}" cyc-a.service > "${TMP}/verify-cycle.out" 2>&1 || true
    grep -q 'Found ordering cycle' "${TMP}/verify-cycle.out" \
        || fail "control: systemd-analyze verify did not report a real ordering cycle ($(systemd-analyze --version | head -n 1)): $(cat "${TMP}/verify-cycle.out")"

    vr="${TMP}/verify-open"
    mkdir -p "${vr}"
    "${REPO_DIR}/scripts/install-alsa-config.sh" kernel-sunxi-7.x "${vr}" "${REPO_DIR}" > /dev/null
    stage_verify_root "${vr}"
    # Debian alsa-utils' units, as bookworm ships them: alsa-restore after
    # alsa-state, both wanted by sound.target.
    printf '[Unit]\nDescription=Save/Restore Sound Card State\nAfter=alsa-state.service\n[Service]\nType=oneshot\nRemainAfterExit=true\nExecStart=/bin/true\n' \
        > "${vr}/usr/lib/systemd/system/alsa-restore.service"
    printf '[Unit]\nDescription=Manage Sound Card State\n[Service]\nType=oneshot\nExecStart=/bin/true\n' \
        > "${vr}/usr/lib/systemd/system/alsa-state.service"
    ln -s ../alsa-restore.service "${vr}/usr/lib/systemd/system/sound.target.wants/alsa-restore.service"
    ln -s ../alsa-state.service "${vr}/usr/lib/systemd/system/sound.target.wants/alsa-state.service"
    # At the default log level verify prints only problems: any output fails.
    status=0
    systemd-analyze verify --man=no --root="${vr}" \
        sound.target pocketforge-audio-defaults.service > "${TMP}/verify-open.out" 2>&1 || status=$?
    if [ "${status}" -ne 0 ] || [ -s "${TMP}/verify-open.out" ]; then
        fail "systemd-analyze verify (status ${status}) reported: $(cat "${TMP}/verify-open.out")"
    fi
    # Debug log only to observe that sound.target's start pulls the unit in.
    SYSTEMD_LOG_LEVEL=debug systemd-analyze verify --man=no --root="${vr}" \
        sound.target > "${TMP}/verify-open-debug.out" 2>&1 || true
    grep -q 'pocketforge-audio-defaults.service: Installed new job pocketforge-audio-defaults.service/start' "${TMP}/verify-open-debug.out" \
        || fail "sound.target does not pull in pocketforge-audio-defaults.service in systemd-analyze verify"
    pass "systemd-analyze verify ($(systemd-analyze --version | head -n 1 | awk '{print $2}')): unit loads, sound.target pulls it in, no ordering cycle (detector control: real cycle reported)"
elif [ "${GITHUB_ACTIONS:-}" = true ]; then
    fail "systemd-analyze is not installed on this CI runner; the unit-graph verify check is required in CI"
else
    echo "SKIP: systemd-analyze not installed; static unit rule still enforced"
fi

# ---- 4. empty or unknown kernel repo fails closed --------------------------
for bad in "" kernel-sunxi-5.15 kernel-tsp; do
    root="${TMP}/rootfs-bad-${bad:-empty}"
    mkdir -p "${root}"
    if "${REPO_DIR}/scripts/install-alsa-config.sh" "${bad}" "${root}" "${REPO_DIR}" > "${TMP}/bad.log" 2>&1; then
        fail "install-alsa-config.sh accepted kernel repo '${bad}'"
    fi
    [ ! -e "${root}/etc/asound.conf" ] || fail "install-alsa-config.sh '${bad}' still wrote /etc/asound.conf"
    grep -q FATAL "${TMP}/bad.log" || fail "install-alsa-config.sh '${bad}' failed without a FATAL reason"
done
pass "empty/unknown kernel repo refused before writing /etc/asound.conf"

# ---- 5. audio-defaults.sh behaviour with fake amixer/udevadm ---------------
bin="${TMP}/bin"
mkdir -p "${bin}" "${TMP}/proc/${OPEN_CARD}"
cat > "${bin}/amixer" <<'EOF'
#!/bin/sh
printf '%s|' "$@" >> "${FAKE_AMIXER_LOG}"
printf '\n' >> "${FAKE_AMIXER_LOG}"
case "$*" in *"${FAKE_AMIXER_FAIL:-@none@}"*) exit 1 ;; esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "${bin}/udevadm"
chmod 0755 "${bin}/amixer" "${bin}/udevadm"
script="${REPO_DIR}/rootfs-overlay/usr/lib/pocketforge/audio-defaults.sh"
defaults="${REPO_DIR}/device-config/alsa/mixer-defaults.sun4i-codec"

run_defaults() {
    PATH="${bin}:${PATH}" FAKE_AMIXER_LOG="${TMP}/amixer.log" \
    PF_AUDIO_DEFAULTS="${defaults}" PF_AUDIO_PROC_ASOUND="$1" PF_AUDIO_WAIT_TRIES=1 \
        sh "${script}" > "${TMP}/defaults.out" 2>&1
}

: > "${TMP}/amixer.log"
run_defaults "${TMP}/proc" || fail "audio-defaults.sh failed with every control present: $(cat "${TMP}/defaults.out")"
expected="$(grep -v -e '^#' -e '^$' "${defaults}" | while IFS= read -r l; do
    printf -- '-q|-c|%s|cset|name=%s|%s|\n' "${OPEN_CARD}" "${l%%=*}" "${l#*=}"; done)"
[ "$(cat "${TMP}/amixer.log")" = "${expected}" ] \
    || fail "audio-defaults.sh amixer calls differ from the defaults file:
--- got
$(cat "${TMP}/amixer.log")
--- want
${expected}"
pass "audio-defaults.sh applies every default with amixer -c ${OPEN_CARD}, in file order"

: > "${TMP}/amixer.log"
if FAKE_AMIXER_FAIL="name=Line Out Playback Switch" run_defaults "${TMP}/proc"; then
    fail "audio-defaults.sh succeeded although one control failed"
fi
[ "$(wc -l < "${TMP}/amixer.log")" -eq "$(printf '%s\n' "${expected}" | wc -l)" ] \
    || fail "audio-defaults.sh stopped at the failing control instead of applying the rest"
if run_defaults "${TMP}/no-proc"; then
    fail "audio-defaults.sh succeeded without card ${OPEN_CARD}"
fi
grep -q "card '${OPEN_CARD}' not present" "${TMP}/defaults.out" \
    || fail "audio-defaults.sh missing-card failure lacks its reason: $(cat "${TMP}/defaults.out")"
pass "audio-defaults.sh fails on a missing control (after applying the rest) and on a missing card"

# ---- negative control: the same test over image main before the fix ------
# Only the test's own inputs are overlaid on the pre-fix tree: this script,
# the capture helper, the driver fixtures and the stock file (byte-identical
# to what the pre-fix build-rootfs.sh embedded). The fix itself is absent.
if [ -z "${PF_ALSA_NEGATIVE_RUN:-}" ]; then
    neg="${TMP}/pre-fix"
    mkdir -p "${neg}"
    git -C "${REPO_DIR}" archive "${PRE_FIX_COMMIT}" | tar -x -C "${neg}" \
        || fail "negative control: cannot read ${PRE_FIX_COMMIT} (needs full git history)"
    for input in tests/test-alsa-config.sh tests/lib/capture-customize-hook.sh \
                 tests/fixtures/alsa device-config/alsa/asound.conf.sunxi-vendor; do
        mkdir -p "${neg}/$(dirname "${input}")"
        rm -rf "${neg:?}/${input}"
        cp -R "${REPO_DIR}/${input}" "${neg}/${input}"
    done
    if PF_ALSA_NEGATIVE_RUN=1 REPO_DIR="${neg}" bash "${neg}/tests/test-alsa-config.sh" \
            > "${TMP}/negative.log" 2>&1; then
        fail "negative control: the test passed on pre-fix image main ${PRE_FIX_COMMIT}"
    fi
    grep -q '^FAIL: the customize hook writes /etc/asound.conf itself' "${TMP}/negative.log" \
        || fail "negative control: pre-fix image main failed for another reason: $(grep '^FAIL' "${TMP}/negative.log" || tail -n 5 "${TMP}/negative.log")"
    echo "NEGATIVE CONTROL: pre-fix image main ${PRE_FIX_COMMIT:0:12} fails: $(grep '^FAIL' "${TMP}/negative.log")"
fi

echo "ALL PASS: test-alsa-config.sh"
