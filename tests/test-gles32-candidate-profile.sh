#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${root}/scripts/install-gles32-candidate-profile.sh"
verifier="${root}/scripts/verify-gles32-candidate-profile.sh"
policy="${root}/packages/pocketforge-gles32-candidate/99-pocketforge-gles32-candidate.conf"
builder="${root}/scripts/build-rootfs.sh"
workflow="${root}/.github/workflows/hermetic-tests.yml"
makefile="${root}/Makefile"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pf-gles32-candidate.XXXXXX")"
trap 'find "${scratch}" -mindepth 1 -delete; rmdir "${scratch}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

[ -x "${installer}" ] || fail "candidate profile installer is missing: ${installer}"
[ -x "${verifier}" ] || fail "candidate profile verifier is missing: ${verifier}"
if [ ! -f "${policy}" ] || [ -L "${policy}" ]; then
    fail "candidate profile policy is missing or not regular: ${policy}"
fi

make_cts_rootfs() {
    local destination=$1 executable
    mkdir -p "${destination}/opt/pocketforge/cts/bin"
    for executable in deqp-gles3 deqp-gles31 glcts; do
        printf '#!/bin/sh\nexit 0\n' \
            >"${destination}/opt/pocketforge/cts/bin/${executable}"
        chmod 0755 "${destination}/opt/pocketforge/cts/bin/${executable}"
    done
}

expect_rejection() {
    local label=$1 expected=$2
    shift 2
    if "$@" >"${scratch}/${label}.out" 2>"${scratch}/${label}.err"; then
        fail "${label} fixture was accepted"
    fi
    grep -F "${expected}" "${scratch}/${label}.err" >/dev/null || {
        cat "${scratch}/${label}.err" >&2
        fail "${label} did not report: ${expected}"
    }
}

release_rootfs="${scratch}/release-rootfs"
mkdir -p "${release_rootfs}"
release_install_output=$("${installer}" \
    "${policy}" "${release_rootfs}" release a133-open-7x-gpu)
printf '%s\n' "${release_install_output}" | grep -Fx \
    'gles32-candidate-install=PASS mode=off variant=release device=a133-open-7x-gpu' \
    >/dev/null
release_verify_output=$("${verifier}" \
    "${release_rootfs}" release a133-open-7x-gpu)
printf '%s\n' "${release_verify_output}" | grep -Fx \
    'gles32-candidate-profile=PASS mode=off variant=release device=a133-open-7x-gpu candidate_assignments=0 global_overrides=0' \
    >/dev/null

cts_rootfs="${scratch}/cts-rootfs"
make_cts_rootfs "${cts_rootfs}"
cts_install_output=$("${installer}" \
    "${policy}" "${cts_rootfs}" dev a133-open-7x-gpu-cts)
printf '%s\n' "${cts_install_output}" | grep -Fx \
    'gles32-candidate-install=PASS mode=cts variant=dev device=a133-open-7x-gpu-cts policy=/usr/share/drirc.d/99-pocketforge-gles32-candidate.conf mesa_route=/usr/local/share/drirc.d/99-pocketforge-gles32-candidate.conf' \
    >/dev/null
cts_verify_output=$("${verifier}" \
    "${cts_rootfs}" dev a133-open-7x-gpu-cts)
printf '%s\n' "${cts_verify_output}"
printf '%s\n' "${cts_verify_output}" | grep -Fx \
    'gles32-candidate-profile=PASS mode=cts variant=dev device=a133-open-7x-gpu-cts policy=/usr/share/drirc.d/99-pocketforge-gles32-candidate.conf executables=deqp-gles3,deqp-gles31,glcts mesa_route=/usr/local/share/drirc.d/99-pocketforge-gles32-candidate.conf global_overrides=0' \
    >/dev/null

release_leak="${scratch}/red-release-leak"
cp -a "${cts_rootfs}" "${release_leak}"
expect_rejection red-release-leak \
    'candidate policy is forbidden outside the CTS dev profile:' \
    "${verifier}" "${release_leak}" release a133-open-7x-gpu

cts_missing="${scratch}/red-cts-missing-policy"
make_cts_rootfs "${cts_missing}"
expect_rejection red-cts-missing-policy \
    'CTS candidate policy is missing or not regular:' \
    "${verifier}" "${cts_missing}" dev a133-open-7x-gpu-cts

cts_wildcard="${scratch}/red-cts-wildcard"
cp -a "${cts_rootfs}" "${cts_wildcard}"
sed -i 's/executable="deqp-gles3"/executable="deqp-.*"/' \
    "${cts_wildcard}/usr/share/drirc.d/99-pocketforge-gles32-candidate.conf"
expect_rejection red-cts-wildcard \
    'candidate policy applications do not match the exact CTS allowlist' \
    "${verifier}" "${cts_wildcard}" dev a133-open-7x-gpu-cts

while IFS='|' read -r label assignment; do
    cts_environment="${scratch}/red-${label}"
    cp -a "${cts_rootfs}" "${cts_environment}"
    mkdir -p "${cts_environment}/etc/environment.d"
    printf '%s\n' "${assignment}" \
        >"${cts_environment}/etc/environment.d/99-pocketforge-gles32.conf"
    expect_rejection "red-${label}" \
        'global GLES candidate override is forbidden in the rootfs:' \
        "${verifier}" "${cts_environment}" dev a133-open-7x-gpu-cts
done <<'EOF'
pvr-debug|PVR_DEBUG=pf_texcomp
zink-debug|ZINK_DEBUG=tbo_rgb32
gles-override|MESA_GLES_VERSION_OVERRIDE=3.2
driconf-executable|MESA_DRICONF_EXECUTABLE_OVERRIDE=glcts
driconf-directory|DRIRC_CONFIGDIR=/etc/pocketforge-candidate
EOF

cts_extra_assignment="${scratch}/red-cts-extra-assignment"
cp -a "${cts_rootfs}" "${cts_extra_assignment}"
mkdir -p "${cts_extra_assignment}/etc/drirc.d"
printf '%s\n' '<option name="pvr_enable_gles32_candidate" value="true" />' \
    >"${cts_extra_assignment}/etc/drirc.d/extra.conf"
expect_rejection red-cts-extra-assignment \
    'candidate assignment is forbidden outside the canonical policy:' \
    "${verifier}" "${cts_extra_assignment}" dev a133-open-7x-gpu-cts

cts_wrong_route="${scratch}/red-cts-wrong-route"
cp -a "${cts_rootfs}" "${cts_wrong_route}"
rm "${cts_wrong_route}/usr/local/share/drirc.d/99-pocketforge-gles32-candidate.conf"
ln -s /wrong/candidate.conf \
    "${cts_wrong_route}/usr/local/share/drirc.d/99-pocketforge-gles32-candidate.conf"
expect_rejection red-cts-wrong-route \
    'CTS candidate Mesa search route target is invalid:' \
    "${verifier}" "${cts_wrong_route}" dev a133-open-7x-gpu-cts

cts_missing_executable="${scratch}/red-cts-missing-executable"
cp -a "${cts_rootfs}" "${cts_missing_executable}"
rm "${cts_missing_executable}/opt/pocketforge/cts/bin/glcts"
expect_rejection red-cts-missing-executable \
    'allowlisted CTS executable is missing, symlinked, or not executable:' \
    "${verifier}" "${cts_missing_executable}" dev a133-open-7x-gpu-cts

# The final assembled rootfs, not only a source fixture, must pass the gate.
test "$(grep -Fc 'scripts/install-gles32-candidate-profile.sh' "${builder}")" -eq 1
test "$(grep -Fc 'scripts/verify-gles32-candidate-profile.sh' "${builder}")" -eq 1
test "$(grep -Fxc '            tests/test-gles32-candidate-profile.sh' "${workflow}")" -eq 1
grep -Fx 'test-gles32-candidate-profile:' "${makefile}" >/dev/null

# Product recipes may not smuggle candidate state through process environments.
if grep -RIlE \
    '(^|[^[:alnum:]_])(PVR_DEBUG[[:space:]]*=.*pf_texcomp|ZINK_DEBUG[[:space:]]*=.*tbo_rgb32|MESA_GLES_VERSION_OVERRIDE[[:space:]]*=|MESA_DRICONF_EXECUTABLE_OVERRIDE[[:space:]]*=|DRIRC_CONFIGDIR[[:space:]]*=)' \
    "${root}/build/Dockerfile.pf" "${root}/scripts/build-rootfs.sh" \
    "${root}/packages" | grep -vF "${policy}" | grep -q .; then
    fail 'image recipe contains a global GLES candidate environment override'
fi

echo 'gles32-candidate-profile-test=PASS green=release-off+cts-exact red=release-leak,cts-missing,cts-wildcard,pvr-debug,zink-debug,gles-override,driconf-executable,driconf-directory,extra-assignment,wrong-route,missing-executable'
