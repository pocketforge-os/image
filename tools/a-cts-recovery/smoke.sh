#!/usr/bin/env bash
# Exact-rootfs smoke for the on-image A-CTS runner.
set -euo pipefail
export LC_ALL=C

IMG=${1:?raw image}
OUT=${2:?receipt dir}
RAW_SHA=a50ccb5623c4ed637af85d4db9887387c5c142ad42d46a8303513606c97b3df5
BUILD_ID='device=a133-open-7x-gpu-cts build=1e6b1892f666'
BUNDLE_SHA=9ce9b9c252c1b288ffb4a58dd8e976fd35110b4e2b1d9cc1a3a0cd3be13e5125
PROBE_SHA=993aabc47acb52c4d8af61113507091097c6cb1b84dc4d06b312c96f508dbab8
DISCRIM_PROBE_SHA=97e87bce16b827099811d2c428606caf1dd009bf176e235fc42686d54dd0d413
VK_PROBE_SHA=2a56e1c8f2e9b9933c495494bfa6dad42785494d5abd91bfaec247f0e3e14102
EGL_PROBE_SHA=8c5a5d3f009af537e0f4a3358de9ed19dcaf5f6b4b1fecec5cac2d463880e35b
S=$OUT/smoke
K=$(cd "$(dirname "$0")" && pwd)
TAG=pf-smoke-a-cts:${RAW_SHA:0:12}-$$
mkdir -p "$S/rootfs" "$S/out"
: >"$S/smoke.log"

log() { printf '%s\n' "$*" | tee -a "$S/smoke.log"; }
clean_dir() {
    [[ -d $1 ]] || return 0
    chmod -R u+w "$1" 2>/dev/null || :
    find "$1" -mindepth 1 -delete
    rmdir "$1"
}
teardown() {
    if docker image inspect "$TAG" >/dev/null 2>&1; then docker image rm "$TAG" >/dev/null; fi
    clean_dir "$S/rootfs"
    [[ ! -e $S/partition5.ext4 ]] || find "$S/partition5.ext4" -delete
}
fail() { teardown; log "SMOKE FAIL step=$1 ${2:-}"; exit 1; }
trap teardown EXIT

[[ -z ${PF_BEAD+x} && -z ${LG_USERNAME+x} ]] || fail inherited_device_identity
[[ $(sha256sum "$IMG" | cut -d' ' -f1) == "$RAW_SHA" ]] || fail image_sha
[[ $(sha256sum "$K/ImageSource.json" | cut -d' ' -f1) == \
    ee3523b09fcd1f20493dbebcd444110d9d7e92445ad08b1c0ff1cea0eb8579d7 ]] \
    || fail descriptor_sha
jq -e --slurpfile source "$K/ImageSource.json" '.ImageSource == $source[0]' \
    "$K/felboot-request.json" >/dev/null || fail felboot_descriptor_mismatch
"$K/test-login-gate.sh" >"$S/out/login-gate.txt" 2>"$S/out/login-gate.stderr" \
    || fail login_gate "$(tail -c 800 "$S/out/login-gate.stderr")"
grep -qx 'A_CTS_LOGIN_GATE_TEST PASS success_skips_capture=yes transport_capture=yes semantic_capture=yes capture_failure_typed=yes sha256=yes' \
    "$S/out/login-gate.txt" || fail login_gate_marker
# shellcheck disable=SC2016
grep -Fq '"$K/login-gate" "$R" "$ID" "${SSH[@]}"' "$K/direct-boot.sh" \
    || fail login_gate_not_wired
grep -Fqx 'ls -1 /sys/class/drm' "$OUT/cmds/drm-class.txt" || fail drm_inventory_not_rendered
grep -Eq '^A5A_ELAPSED cases=44766 duration_s=5257$' "$K/KIT-PROVENANCE.txt" \
    || fail timing_receipt
grep -Eq '^A_CTS_BUDGET formula=max\(1800,900\+ceil\(2\*5257\*cases/44766\)\)$' \
    "$K/KIT-PROVENANCE.txt" || fail timing_formula

read -r p5_start p5_size < <(sfdisk -J "$IMG" | jq -r '.partitiontable.partitions[4] | "\(.start) \(.size)"')
[[ $p5_start == 249856 && $p5_size == 3598336 ]] \
    || fail partition_layout "start=$p5_start size=$p5_size"
dd if="$IMG" of="$S/partition5.ext4" bs=512 skip="$p5_start" count="$p5_size" status=none \
    || fail partition_extract
[[ $(blkid -o value -s LABEL "$S/partition5.ext4") == POCKETFORGE_DATA ]] || fail partition_label
debugfs -R "rdump / $S/rootfs" "$S/partition5.ext4" >/dev/null 2>"$S/debugfs.stderr" \
    || fail rootfs_extract
[[ $(debugfs -R 'cat /etc/pocketforge-build-id' "$S/partition5.ext4" 2>/dev/null) == "$BUILD_ID" ]] \
    || fail build_id

grep -Fxq 'gamer:x:1000:1000::/home/gamer:/bin/bash' "$S/rootfs/etc/passwd" \
    || fail gamer_passwd
grep -Eq '^video:x:[0-9]+:.*\bgamer\b' "$S/rootfs/etc/group" || fail gamer_video_group
grep -Eq '^render:x:[0-9]+:.*\bgamer\b' "$S/rootfs/etc/group" || fail gamer_render_group
grep -Fxq 'KERNEL=="card0",      SUBSYSTEM=="drm", MODE="0660", GROUP="video"' \
    "$S/rootfs/etc/udev/rules.d/60-pocketforge-dri.rules" || fail card0_udev
grep -Fxq 'KERNEL=="renderD128", SUBSYSTEM=="drm", MODE="0660", GROUP="render"' \
    "$S/rootfs/etc/udev/rules.d/60-pocketforge-dri.rules" || fail render_udev
grep -Fq 'groups: [audio, input, video, render]' "$S/rootfs/etc/cloud/cloud.cfg" \
    || fail cloud_init_groups
[[ -x $S/rootfs/usr/bin/eglinfo ]] || fail eglinfo_missing
grep -Fq '"library_path": "/usr/local/lib/libEGL_mesa.so.0"' \
    "$S/rootfs/usr/share/glvnd/egl_vendor.d/50_mesa.json" || fail egl_vendor
grep -Fq 'kernel_driver="powervr"' \
    "$S/rootfs/usr/local/share/drirc.d/10-pocketforge-zink.conf" || fail drirc_kernel
grep -Fq 'option name="dri_driver" value="zink"' \
    "$S/rootfs/usr/local/share/drirc.d/10-pocketforge-zink.conf" || fail drirc_zink
[[ $(readlink "$S/rootfs/usr/local/lib/dri/zink_dri.so") == libdril_dri.so ]] \
    || fail zink_driver_link
grep -Fq '"library_path": "/usr/local/lib/libvulkan_powervr_mesa.so"' \
    "$S/rootfs/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json" || fail vulkan_icd
for file in \
    "$S/rootfs/usr/local/lib/libvulkan_powervr_mesa.so" \
    "$S/rootfs/usr/local/lib/dri/libdril_dri.so" \
    "$S/rootfs/usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json" \
    "$S/rootfs/lib/firmware/powervr/rogue_22.102.54.38_v1.fw"; do
    [[ -r $file ]] || fail rootfs_user_readable "$file"
done
strings -a "$S/rootfs/usr/local/lib/libvulkan_powervr_mesa.so" \
    | grep -F 'PVR_I_WANT_A_BROKEN_VULKAN_DRIVER' >"$S/out/pvr-opt-in-marker.txt" \
    || fail pvr_opt_in_marker
log "gpu_access=PASS user=gamer groups=video,render udev=card0:root:video:0660,renderD128:root:render:0660 egl=mesa dri=zink vulkan=powervr firmware=readable"

CTS=$S/rootfs/opt/pocketforge/cts
PROV=$S/rootfs/usr/share/pocketforge/cts-provenance
[[ -x $CTS/bin/deqp-gles2 && -x $CTS/bin/deqp-gles3 && -x $CTS/bin/deqp-gles31 && -x $CTS/bin/glcts ]] \
    || fail cts_binaries
[[ -x $CTS/run-chunks.sh && -r $CTS/config/lists.tsv && -r $CTS/BUNDLE-SHA256SUMS ]] \
    || fail cts_layout
grep -Fxq "artifact_sha256=$BUNDLE_SHA" "$PROV" || fail cts_provenance_sha
grep -Fxq 'source_commit=067e8832315e79817ede1c4863804e440f5d1c80' "$PROV" || fail cts_provenance_commit
grep -Fxq 'list_count=13' "$PROV" || fail cts_provenance_lists
grep -Fxq 'mustpass_case_entries=124248' "$PROV" || fail cts_provenance_cases
[[ $(awk -F '\t' '!/^#/ { lists++; cases += $5 } END { print lists ":" cases }' "$CTS/config/lists.tsv") == 13:124248 ]] \
    || fail list_metadata_totals
(cd "$CTS" && sha256sum -c --strict BUNDLE-SHA256SUMS >/dev/null) || fail cts_manifest
log "bundle_identity=PASS sha256=$BUNDLE_SHA lists=13 cases=124248"
"$K/cts-runtime-libs" "$S/rootfs" >"$S/out/cts-libs-image.txt" \
    || fail cts_lib_image "$(tail -c 1200 "$S/out/cts-libs-image.txt")"
grep -q '^A_CTS_LIB_RESOLVE name=libEGL.so source=system target=/usr/lib/aarch64-linux-gnu/libEGL.so$' \
    "$S/out/cts-libs-image.txt" || fail cts_lib_egl_contract
grep -q '^A_CTS_LIB_RESOLVE name=libGL.so source=system target=/usr/lib/aarch64-linux-gnu/libGL.so$' \
    "$S/out/cts-libs-image.txt" || fail cts_lib_gl_contract
grep -q '^A_CTS_LIB_RESOLVE name=libGLESv2.so source=system target=/usr/lib/aarch64-linux-gnu/libGLESv2.so$' \
    "$S/out/cts-libs-image.txt" || fail cts_lib_gles_contract
[[ $(grep -Ec '^A_CTS_LIB_BINARY binary=(deqp-gles2|deqp-gles3|deqp-gles31|glcts) unversioned=3 names=libEGL.so,libGL.so,libGLESv2.so$' \
    "$S/out/cts-libs-image.txt") -eq 4 ]] || fail cts_lib_real_binary_name_set
log "cts_runtime_libs=PASS scan=actual_binaries provider=image libraries=libEGL.so,libGL.so,libGLESv2.so kit_links=absent"
[[ -x $K/pf-surfaceless-gles-probe ]] || fail egl_probe_missing
[[ $(sha256sum "$K/pf-surfaceless-gles-probe" | cut -d' ' -f1) == "$EGL_PROBE_SHA" ]] \
    || fail egl_probe_sha
readelf -h "$K/pf-surfaceless-gles-probe" >"$S/out/egl-probe-elf-header.txt" \
    || fail egl_probe_readelf
grep -Eq 'Machine:[[:space:]]+AArch64' "$S/out/egl-probe-elf-header.txt" \
    || fail egl_probe_arch
[[ $(find "$OUT/cmds" -maxdepth 1 -type f -name 'eglprobe-chunk-*.txt' | wc -l) -eq 3 ]] \
    || fail egl_probe_chunk_count
grep -q "sha256=$EGL_PROBE_SHA bytes=86736" "$OUT/cmds/eglprobe-finalize.txt" \
    || fail egl_probe_finalize_contract
cat "$OUT"/chunks/eglprobe.* >"$S/eglprobe.reconstructed"
[[ $(sha256sum "$S/eglprobe.reconstructed" | cut -d' ' -f1) == "$EGL_PROBE_SHA" ]] \
    || fail egl_probe_chunk_reconstruction
find "$S/eglprobe.reconstructed" -maxdepth 0 -type f -delete
[[ -x $K/pf-pvr-texcomp-probe ]] || fail probe_missing
[[ $(sha256sum "$K/pf-pvr-texcomp-probe" | cut -d' ' -f1) == "$PROBE_SHA" ]] \
    || fail probe_sha
[[ $(find "$OUT/cmds" -maxdepth 1 -type f -name 'probe-chunk-*.txt' | wc -l) -eq 7 ]] \
    || fail probe_chunk_count
grep -q "sha256=$PROBE_SHA bytes=217048" "$OUT/cmds/probe-finalize.txt" \
    || fail probe_finalize_contract
cat "$OUT"/chunks/probe.* >"$S/probe.reconstructed"
[[ $(sha256sum "$S/probe.reconstructed" | cut -d' ' -f1) == "$PROBE_SHA" ]] \
    || fail probe_chunk_reconstruction
find "$S/probe.reconstructed" -maxdepth 0 -type f -delete
[[ -x $K/pf-pvr-texcomp-discrim-probe ]] || fail discrim_probe_missing
[[ $(sha256sum "$K/pf-pvr-texcomp-discrim-probe" | cut -d' ' -f1) == "$DISCRIM_PROBE_SHA" ]] \
    || fail discrim_probe_sha
[[ $(find "$OUT/cmds" -maxdepth 1 -type f -name 'discrim-chunk-*.txt' | wc -l) -eq 7 ]] \
    || fail discrim_probe_chunk_count
grep -q "sha256=$DISCRIM_PROBE_SHA bytes=237656" "$OUT/cmds/discrim-finalize.txt" \
    || fail discrim_probe_finalize_contract
cat "$OUT"/chunks/discrim.* >"$S/discrim.reconstructed"
[[ $(sha256sum "$S/discrim.reconstructed" | cut -d' ' -f1) == "$DISCRIM_PROBE_SHA" ]] \
    || fail discrim_probe_chunk_reconstruction
find "$S/discrim.reconstructed" -maxdepth 0 -type f -delete
[[ -x $K/pf-pvr-vk-tex-discriminator ]] || fail vk_probe_missing
[[ $(sha256sum "$K/pf-pvr-vk-tex-discriminator" | cut -d' ' -f1) == "$VK_PROBE_SHA" ]] \
    || fail vk_probe_sha
[[ $(find "$OUT/cmds" -maxdepth 1 -type f -name 'vkprobe-chunk-*.txt' | wc -l) -eq 9 ]] \
    || fail vk_probe_chunk_count
grep -q "sha256=$VK_PROBE_SHA bytes=308160" "$OUT/cmds/vkprobe-finalize.txt" \
    || fail vk_probe_finalize_contract
cat "$OUT"/chunks/vkprobe.* >"$S/vkprobe.reconstructed"
[[ $(sha256sum "$S/vkprobe.reconstructed" | cut -d' ' -f1) == "$VK_PROBE_SHA" ]] \
    || fail vk_probe_chunk_reconstruction
find "$S/vkprobe.reconstructed" -maxdepth 0 -type f -delete

sudo_modes=$(debugfs -R 'stat /usr/bin/sudo' "$S/partition5.ext4" 2>/dev/null \
    | sed -n 's/.*Mode: *\([0-7]*\).*/\1/p')
sudo_mode=${sudo_modes%%$'\n'*}
case "$sudo_mode" in 4[0-7][0-7][0-7]|04[0-7][0-7][0-7]) chmod "$sudo_mode" "$S/rootfs/usr/bin/sudo" ;; *) fail sudo_mode ;; esac
if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    sudo -n /usr/lib/systemd/systemd-binfmt /usr/lib/binfmt.d/qemu-aarch64.conf || fail binfmt_register
fi
flags=$(sed -n 's/^flags: //p' /proc/sys/fs/binfmt_misc/qemu-aarch64)
for flag in O P F; do [[ $flags == *"$flag"* ]] || fail binfmt_flags "$flags"; done

tar --owner=0 --group=0 -C "$S/rootfs" -c . 2>/dev/null \
    | docker import --platform linux/arm64 --change 'LABEL pf.bead=tsp-mc9m.41.924.24.19' - "$TAG" >/dev/null \
    || fail docker_import
[[ $(docker image inspect --format '{{.Architecture}} {{index .Config.Labels "pf.bead"}}' "$TAG") == 'arm64 tsp-mc9m.41.924.24.19' ]] \
    || fail docker_identity

mkdir -p "$S/fixtures" "$S/collect"
chmod 0777 "$S/collect"
cat >"$S/fixtures/eglinfo" <<'EOF'
#!/bin/sh
printf 'GBM platform:\neglinfo: eglInitialize failed\n\n'
printf 'Wayland platform:\neglinfo: eglInitialize failed\n\n'
printf 'Surfaceless platform:\nEGL API version: 1.5\nEGL vendor string: Mesa Project\n'
exit 2
EOF
cat >"$S/fixtures/probe" <<'EOF'
#!/bin/sh
printf 'PF_SURFACELESS_GLES egl_initialize=pass egl_version=1.5\n'
printf 'PF_SURFACELESS_GLES renderer=zink Vulkan 1.2 (PowerVR Rogue GE8300)\n'
printf 'PF_SURFACELESS_GLES gl_version=OpenGL ES 3.2 smoke\n'
printf 'PF_SURFACELESS_GLES verdict=pass renderer=zink-powervr context=gles3\n'
printf 'PF_GLES_SANITY verdict=pass clear=pass texture=pass renderer=zink-powervr\n'
EOF
cat >"$S/fixtures/texcomp-not-sanity" <<'EOF'
#!/bin/sh
printf 'PF_TEXCOMP_RESULT verdict=pass controls_passed=5 controls_required=5\n'
EOF
cat >"$S/fixtures/glcts" <<'EOF'
#!/bin/sh
qpa=
for argument in "$@"; do
    case "$argument" in --deqp-log-filename=*) qpa=${argument#*=} ;; esac
done
[ -n "$qpa" ] || exit 90
cat >"$qpa" <<'QPA'
#beginTestCaseResult KHR-GLES32.info.version
<Result StatusCode="Pass">OpenGL ES 3.2 smoke</Result>
#endTestCaseResult
#beginTestCaseResult KHR-GLES32.info.extensions
<Result StatusCode="Pass">GL_EXT_smoke</Result>
#endTestCaseResult
QPA
printf 'dEQP precondition smoke pass\n'
EOF
cat >"$S/fixtures/dutexec-smoke" <<'EOF'
#!/bin/bash
set -eu
run_dutexec() {
    step=$1 command=$2
    printf 'A_CTS_DUTEXEC_IDENTITY step=%s user=%s uid=%s\n' \
        "$step" "$(/usr/bin/id -un)" "$(/usr/bin/id -u)"
    /bin/sh "$command"
}
test "$(/usr/bin/id -u)" = 1001
test "$(/usr/bin/id -un)" = debug
test "$(sudo -n /usr/bin/id -u)" = 0
gamer_identity=$(sudo -n -u gamer /usr/bin/id)
case "$gamer_identity" in uid=1000\(gamer\)*) ;; *) exit 40 ;; esac

identity=$(run_dutexec identity /receipt/cmds/identity.txt)
printf '%s\n' "$identity"
case "$identity" in
    *"A_CTS_DUTEXEC_IDENTITY step=identity user=debug uid=1001"*"uid=1001(debug) gid=1001(debug)"*) ;;
    *) exit 41 ;;
esac

run_dutexec stage-reset-r37 /receipt/smoke/r37-stage-reset.txt
set +e
run_dutexec egl-preflight-r37 /receipt/cmds/egl-preflight.txt \
    >/tmp/r37-preflight.out 2>&1
r37_rc=$?
set -e
test "$r37_rc" -ne 0
grep -Fq 'Permission denied' /tmp/r37-preflight.out
printf 'A_CTS_R37_CONTROL verdict=fail_as_expected rc=%s reason=debug_cannot_write_gamer_stage\n' \
    "$r37_rc"

run_dutexec stage-reset /receipt/cmds/stage-reset.txt
test "$(/usr/bin/stat -c %U /run/pf-a-cts)" = debug
test "$(/usr/bin/stat -c %U /run/pf-probes)" = debug
for command in /receipt/cmds/eglprobe-chunk-*.txt; do
    name=${command##*/}; name=${name%.txt}
    run_dutexec "$name" "$command"
done
run_dutexec eglprobe-finalize /receipt/cmds/eglprobe-finalize.txt
probe_sha=$(sha256sum /fixtures/probe | cut -d' ' -f1)
sudo -n /usr/bin/install -d -m 0755 -o gamer -g gamer /run/pf-a-cts/sanity-smoke
sudo -n -u gamer env -i \
    HOME=/home/gamer USER=gamer LOGNAME=gamer PATH=/usr/local/bin:/usr/bin:/bin \
    XDG_RUNTIME_DIR=/run/user/1000 EGL_PLATFORM=surfaceless \
    PF_ACTS_ROOT=/run/pf-a-cts/sanity-smoke \
    PF_ACTS_SANITY_PROBE=/fixtures/probe PF_ACTS_SANITY_PROBE_SHA="$probe_sha" \
    /run/pf-a-cts/a-cts-dut sanity-selftest
grep -q ' user=gamer uid=1000 .* verdict=pass ' \
    /run/pf-a-cts/sanity-smoke/recovery-sanity/baseline.result

texcomp_sha=$(sha256sum /fixtures/texcomp-not-sanity | cut -d' ' -f1)
sudo -n /usr/bin/install -d -m 0755 -o gamer -g gamer /run/pf-a-cts/sanity-texcomp-control
set +e
sudo -n -u gamer env -i \
    HOME=/home/gamer USER=gamer LOGNAME=gamer PATH=/usr/local/bin:/usr/bin:/bin \
    XDG_RUNTIME_DIR=/run/user/1000 EGL_PLATFORM=surfaceless \
    PF_ACTS_ROOT=/run/pf-a-cts/sanity-texcomp-control \
    PF_ACTS_SANITY_PROBE=/fixtures/texcomp-not-sanity \
    PF_ACTS_SANITY_PROBE_SHA="$texcomp_sha" \
    /run/pf-a-cts/a-cts-dut sanity-selftest >/tmp/texcomp-sanity.out 2>&1
texcomp_rc=$?
set -e
test "$texcomp_rc" -ne 0
grep -q ' user=gamer uid=1000 .* verdict=fail ' \
    /run/pf-a-cts/sanity-texcomp-control/recovery-sanity/baseline.result
printf 'A_CTS_SANITY_SMOKE verdict=pass user=gamer baseline=pass texcomp_rejected=yes\n'
preflight=$(run_dutexec egl-preflight /receipt/cmds/egl-preflight.txt)
printf '%s\n' "$preflight"
case "$preflight" in
    *"A_CTS_EGL_PREFLIGHT baseline=pass"*"candidate=pass"*"evidence=ready"*) ;;
    *) exit 42 ;;
esac
run_dutexec egl-preflight-receipt /receipt/cmds/egl-preflight-receipt.txt \
    >/tmp/egl-preflight-receipt.txt
mkdir -p /tmp/egl-preflight-unpacked
tar -xzf /run/pf-a-cts/egl-preflight/results.tar.gz \
    -C /tmp/egl-preflight-unpacked
/kit/verify-egl-preflight.sh /tmp/egl-preflight-unpacked
grep -Eq '^uid=1001\(debug\) gid=1001\(debug\)' \
    /tmp/egl-preflight-unpacked/control.identity
for arm in baseline candidate; do
    grep -Eq '^uid=1000\(gamer\) gid=1000\(gamer\)' \
        "/tmp/egl-preflight-unpacked/$arm.identity"
    test "$(/usr/bin/stat -c %U "/run/pf-a-cts/egl-preflight/$arm-work")" = gamer
done

run_dutexec smoke-collect-egl-preflight-chunk-0 \
    /receipt/cmds/smoke-collect-egl-preflight-chunk-0.txt \
    >/collect/egl-preflight-chunk.stdout
cp /run/pf-a-cts/egl-preflight/results.tar.gz /collect/egl-preflight.expected

mkdir -p /run/pf-a-cts/probes/default
printf 'probe chunk through debug DutExec and content parser\n' \
    >/run/pf-a-cts/probes/default/results.tar.gz
cp /run/pf-a-cts/probes/default/results.tar.gz /collect/probe.expected
run_dutexec smoke-collect-probe-chunk-0 \
    /receipt/cmds/smoke-collect-probe-chunk-0.txt \
    >/collect/probe-chunk.stdout

printf 'fixture\tcase\n' >/run/pf-a-cts/expected.tsv
PF_ACTS_WORKER_FIXTURE=linger \
    run_dutexec worker-start /receipt/cmds/worker-start.txt
test "$(/usr/bin/stat -c %U /run/pf-a-cts)" = debug
test "$(/usr/bin/stat -c %U /run/pf-a-cts/worker-run)" = gamer
grep -Fxq 'ACTUAL_USER=gamer' /run/pf-a-cts/worker-run/worker-environment.txt
grep -Fxq 'ACTUAL_UID=1000' /run/pf-a-cts/worker-run/worker-environment.txt
printf 'case-list results chunk through debug DutExec and content parser\n' \
    >/collect/case-list.expected
sudo -n -u gamer /bin/cp /collect/case-list.expected \
    /run/pf-a-cts/worker-run/results.tar.gz
run_dutexec smoke-collect-archive-chunk-0 \
    /receipt/cmds/smoke-collect-archive-chunk-0.txt \
    >/collect/case-list-chunk.stdout
run_dutexec cleanup /receipt/cmds/cleanup.txt
printf 'A_CTS_DUTEXEC_SMOKE state=pass control=debug arms=gamer worker=gamer sanity=gamer texcomp_rejected=yes r37_negative=pass\n'
EOF
chmod 0755 "$S/fixtures/eglinfo" "$S/fixtures/probe" "$S/fixtures/texcomp-not-sanity" "$S/fixtures/glcts" \
    "$S/fixtures/dutexec-smoke"
# Rendered commands normally arrive over SSH on stdin.  The smoke mounts the
# receipt read-only instead, so make that test transport traversable by the
# real DutExec uid rather than accidentally testing the laptop owner's umask.
chmod a+rx "$OUT" "$OUT/cmds" "$OUT/chunks" "$S" "$S/fixtures"
chmod -R a+rX "$OUT/cmds" "$OUT/chunks"
chmod a+rx "$K"
chmod a+rX "$K"/*
fixture_probe_sha=$(sha256sum "$S/fixtures/probe" | cut -d' ' -f1)
# shellcheck disable=SC2016
sed 's/chown -R debug:\$(id -g debug)/chown -R gamer:\$(id -g gamer)/' \
    "$OUT/cmds/stage-reset.txt" >"$S/r37-stage-reset.txt"
chmod a+r "$S/r37-stage-reset.txt"
# shellcheck disable=SC2016
grep -Fq 'chown -R gamer:$(id -g gamer) /run/pf-a-cts /run/pf-probes' \
    "$S/r37-stage-reset.txt" || fail r37_control_not_rendered

docker run --rm --platform linux/arm64 --network none --hostname localhost \
    --user 0:0 \
    -e HOME=/home/debug -e PF_ACTS_EGLINFO=/fixtures/eglinfo \
    -e PF_ACTS_EGL_PROBE=/fixtures/probe -e PF_ACTS_EGL_PROBE_SHA="$fixture_probe_sha" \
    -e PF_ACTS_GLCTS=/fixtures/glcts -e PF_ACTS_PREFLIGHT_NODE_FIXTURE=1 \
    --tmpfs /tmp:mode=1777,exec --tmpfs /run:mode=0755,exec \
    --tmpfs /dev/shm:mode=1777,exec \
    -v "$K:/kit:ro" -v "$OUT:/receipt:ro" -v "$S/fixtures:/fixtures:ro" \
    -v "$S/collect:/collect" \
    -v /usr/bin/sudo:/usr/bin/sudo:ro \
    -v /usr/libexec/sudo:/usr/libexec/sudo:ro \
    -v /lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:ro \
    -v /usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:ro \
    -v /lib64/ld-linux-x86-64.so.2:/lib64/ld-linux-x86-64.so.2:ro \
    "$TAG" /bin/sh -c '/bin/echo A_CTS_SUDO_POLICY config=exact-rootfs executor=native-for-binfmt-credentials && exec /usr/bin/setpriv --reuid=debug --regid=debug --init-groups /fixtures/dutexec-smoke' \
    >"$S/out/dutexec-identity-smoke.txt" 2>"$S/out/dutexec-identity-smoke.stderr" \
    || fail dutexec_identity_smoke "$(tail -c 1600 "$S/out/dutexec-identity-smoke.stderr")"
grep -qx 'A_CTS_DUTEXEC_SMOKE state=pass control=debug arms=gamer worker=gamer sanity=gamer texcomp_rejected=yes r37_negative=pass' \
    "$S/out/dutexec-identity-smoke.txt" || fail dutexec_identity_smoke_marker
grep -qx 'A_CTS_SANITY_SMOKE verdict=pass user=gamer baseline=pass texcomp_rejected=yes' \
    "$S/out/dutexec-identity-smoke.txt" || fail sanity_smoke_marker
grep -qx 'A_CTS_SUDO_POLICY config=exact-rootfs executor=native-for-binfmt-credentials' \
    "$S/out/dutexec-identity-smoke.txt" || fail dutexec_sudo_policy_marker
grep -q '^A_CTS_R37_CONTROL verdict=fail_as_expected ' "$S/out/dutexec-identity-smoke.txt" \
    || fail r37_negative_marker

set +e
set -o pipefail
sed -n '2p' "$S/collect/egl-preflight-chunk.stdout" \
    | base64 -d >"$S/collect/r38-positional.bin" \
        2>"$S/collect/r38-positional.stderr"
r38_positional_rc=$?
set -e
[[ $r38_positional_rc -ne 0 ]] || fail r38_positional_parser_accepted_metadata
printf 'A_CTS_R38_POSITIONAL_CONTROL verdict=fail_as_expected rc=%s\n' \
    "$r38_positional_rc" >"$S/collect/r38-positional.result"

for kind in egl-preflight probe case-list; do
    "$K/collect-response-chunk" "$kind" "$S/collect/$kind-chunk.stdout" \
        "$S/collect/$kind.decoded" >"$S/collect/$kind.host-result" \
        || fail "collect_path_$kind"
    cmp -s "$S/collect/$kind.expected" "$S/collect/$kind.decoded" \
        || fail "collect_path_identity_$kind"
done
log 'collect_path=PASS responses=egl-preflight,probe,case-list identity_first=yes content_parser=yes sha_verified=yes r38_positional=fail'

docker run --rm --platform linux/arm64 --network none \
    --user 1000:1000 --group-add 44 --group-add 107 -e HOME=/home/gamer \
    --tmpfs /tmp:mode=1777,exec --tmpfs /run:mode=0755,exec \
    -v "$K:/kit:ro" "$TAG" /bin/sh -c '
        test "$(id -u)" = 1000
        test "$(id -un)" = gamer
        groups=" $(id -Gn) "
        case "$groups" in *" video "*) ;; *) exit 31 ;; esac
        case "$groups" in *" render "*) ;; *) exit 32 ;; esac
        test -r /usr/share/vulkan/icd.d/powervr_mesa_icd.aarch64.json
        test -r /lib/firmware/powervr/rogue_22.102.54.38_v1.fw
        set +e
        EGL_PLATFORM=surfaceless /kit/pf-surfaceless-gles-probe \
            >/tmp/sanity-probe.stdout 2>/tmp/sanity-probe.stderr
        sanity_rc=$?
        set -e
        test "$sanity_rc" -ne 126
        test "$sanity_rc" -ne 127
        grep -Eq "^PF_(SURFACELESS_GLES|GLES_SANITY)" \
            /tmp/sanity-probe.stdout /tmp/sanity-probe.stderr
        printf "A_CTS_SANITY_BINARY rootfs=build6 user=gamer uid=1000 rc=%s loader=pass\n" "$sanity_rc"
        /kit/test-egl-worker-env.sh
    ' >"$S/out/device-user-smoke.txt" 2>"$S/out/device-user-smoke.stderr" \
    || fail device_user_smoke "$(tail -c 800 "$S/out/device-user-smoke.stderr")"
grep -q '^A_CTS_EGL_ENV_TEST PASS ' "$S/out/device-user-smoke.txt" \
    || fail device_user_smoke_marker
grep -Eq '^A_CTS_SANITY_BINARY rootfs=build6 user=gamer uid=1000 rc=[0-9]+ loader=pass$' \
    "$S/out/device-user-smoke.txt" || fail sanity_binary_rootfs_marker

docker run --rm --platform linux/arm64 --network none \
    --user "$(id -u):$(id -g)" -e HOME=/tmp -e PF_ACTS_ROOT=/tmp/a-cts-selftest \
    --tmpfs /tmp:mode=1777,exec --tmpfs /run:mode=0755,exec \
    -v "$K:/kit:ro" "$TAG" /kit/a-cts-dut selftest >"$S/out/selftest.txt" 2>"$S/out/selftest.stderr" \
    || fail qemu_selftest "$(tail -c 800 "$S/out/selftest.stderr")"
grep -q '^A_CTS_SELFTEST state=pass ' "$S/out/selftest.txt" || fail selftest_marker

set +e
docker run --rm --platform linux/arm64 --network none \
    --user "$(id -u):$(id -g)" -e HOME=/tmp --tmpfs /tmp:mode=1777,exec \
    -v "$K:/kit:ro" "$TAG" /kit/pf-pvr-texcomp-probe --invalid \
    >"$S/out/probe-loader.txt" 2>"$S/out/probe-loader.stderr"
probe_loader_rc=$?
set -e
[[ $probe_loader_rc -eq 2 ]] || fail probe_loader_rc "$probe_loader_rc"
grep -q '^usage: .* \[--etc-matrix\]$' "$S/out/probe-loader.stderr" \
    || fail probe_loader_usage

set +e
docker run --rm --platform linux/arm64 --network none \
    --user "$(id -u):$(id -g)" -e HOME=/tmp --tmpfs /tmp:mode=1777,exec \
    -v "$K:/kit:ro" "$TAG" /kit/pf-pvr-texcomp-discrim-probe --invalid \
    >"$S/out/discrim-loader.txt" 2>"$S/out/discrim-loader.stderr"
discrim_loader_rc=$?
set -e
[[ $discrim_loader_rc -eq 2 ]] || fail discrim_loader_rc "$discrim_loader_rc"
grep -q '^usage: .* \[--etc-matrix|--layout-record|--discriminate-layout\]$' \
    "$S/out/discrim-loader.stderr" || fail discrim_loader_usage

docker run --rm --platform linux/arm64 --network none \
    --user "$(id -u):$(id -g)" -e HOME=/tmp --tmpfs /tmp:mode=1777,exec \
    -v "$K:/kit:ro" "$TAG" /kit/pf-pvr-vk-tex-discriminator --self-test \
    >"$S/out/vk-probe-selftest.txt" 2>"$S/out/vk-probe-selftest.stderr" \
    || fail vk_probe_selftest "$(tail -c 800 "$S/out/vk-probe-selftest.stderr")"
grep -qx 'PVR_VK_PROBE mode=self-test verdict=pass positive=pass negative=pass' \
    "$S/out/vk-probe-selftest.txt" || fail vk_probe_selftest_marker

docker run --rm --platform linux/arm64 --network none \
    --user "$(id -u):$(id -g)" -e HOME=/tmp -e PF_ACTS_ROOT=/tmp/a-cts-probe-selftest \
    -e PF_ACTS_DISCRIM_PROBE=/kit/pf-pvr-texcomp-discrim-probe \
    --tmpfs /tmp:mode=1777,exec --tmpfs /run:mode=0755,exec \
    -v "$K:/kit:ro" "$TAG" /kit/a-cts-dut probe-selftest \
    >"$S/out/probe-selftest.txt" 2>"$S/out/probe-selftest.stderr" \
    || fail probe_selftest "$(tail -c 800 "$S/out/probe-selftest.stderr")"
grep -q '^A_CTS_PROBE_SELFTEST state=pass ' "$S/out/probe-selftest.txt" \
    || fail probe_selftest_marker

docker run --rm --platform linux/arm64 --network none \
    --user 1001:1001 --group-add 44 --group-add 104 --group-add 107 -e HOME=/home/debug \
    --tmpfs /tmp:mode=1777,exec --tmpfs /run:mode=0755,exec \
    -v "$K:/kit:ro" "$TAG" /kit/test-discriminator.sh \
    >"$S/out/discriminator-selftest.txt" 2>"$S/out/discriminator-selftest.stderr" \
    || fail discriminator_selftest "$(tail -c 800 "$S/out/discriminator-selftest.stderr")"
grep -q '^A_CTS_DISCRIM_TEST PASS ' "$S/out/discriminator-selftest.txt" \
    || fail discriminator_selftest_marker

docker run --rm --platform linux/arm64 --network none \
    --user 1001:1001 --group-add 44 --group-add 104 --group-add 107 \
    -e HOME=/home/debug -e PF_ACTS_ROOT=/tmp/a-cts-prepare \
    --tmpfs /tmp:mode=1777,exec --tmpfs /run:mode=0755,exec \
    -v "$K:/kit:ro" "$TAG" /bin/sh -c '
        mkdir -p /tmp/a-cts-prepare
        printf "list\tgles31-multisample\ncaselist\ta5b.txt\n" >/tmp/a-cts-prepare/request.tsv
        printf "%s\n" dEQP-GLES3.functional.transform_feedback.position.points_separate dEQP-GLES3.functional.negative_api.vertex_array.vertex_attrib_pointer >/tmp/a-cts-prepare/input.caselist
        /kit/a-cts-dut prepare
        grep -qx "state=prepared cases=241" /tmp/a-cts-prepare/state
        grep -qx "gles31-multisample[[:space:]]dEQP-GLES31.functional.multisample.*" /tmp/a-cts-prepare/expected.tsv
        grep -qx "a5b.txt[[:space:]]dEQP-GLES3.functional.transform_feedback.position.points_separate" /tmp/a-cts-prepare/expected.tsv
        grep -q "^a5b.txt[[:space:]]deqp-gles3[[:space:]]" /tmp/a-cts-prepare/meta.tsv
    ' >"$S/out/prepare.txt" 2>"$S/out/prepare.stderr" \
    || fail exact_bundle_prepare "$(tail -c 800 "$S/out/prepare.stderr")"
grep -q '^A_CTS_PREPARE state=complete cases=241$' "$S/out/prepare.txt" || fail prepare_marker

if compgen -G "$OUT/chunks/caselist.*" >/dev/null; then
    cat "$OUT"/chunks/caselist.* >"$S/custom.caselist"
    chmod a+r "$S/custom.caselist"
    custom_sha=$(sha256sum "$S/custom.caselist" | cut -d' ' -f1)
    custom_cases=$(wc -l <"$S/custom.caselist")
    custom_budget=$((900 + (2 * 5257 * custom_cases + 44765) / 44766))
    [[ $custom_budget -ge 1800 ]] || custom_budget=1800
    docker run --rm --platform linux/arm64 --network none \
        --user 1001:1001 --group-add 44 --group-add 104 --group-add 107 -e HOME=/home/debug \
        -e PF_ACTS_ROOT=/tmp/a-cts-custom -e EXPECT_CASES="$custom_cases" \
        --tmpfs /tmp:mode=1777,exec --tmpfs /run:mode=0755,exec \
        -v "$K:/kit:ro" -v "$S/custom.caselist:/request.caselist:ro" \
        "$TAG" /bin/sh -c '
            mkdir -p "$PF_ACTS_ROOT"
            cp /request.caselist "$PF_ACTS_ROOT/input.caselist"
            printf "caselist\ta5b-r26.txt\n" >"$PF_ACTS_ROOT/request.tsv"
            /kit/a-cts-dut prepare
            grep -qx "state=prepared cases=$EXPECT_CASES" "$PF_ACTS_ROOT/state"
            awk -F "\t" -v expected="$EXPECT_CASES" \
                "NR==1 && \$1==\"a5b-r26.txt\" && \$5==expected { found=1 } END { exit !found }" \
                "$PF_ACTS_ROOT/meta.tsv"
        ' >"$S/out/custom-prepare.txt" 2>"$S/out/custom-prepare.stderr" \
        || fail exact_custom_prepare "$(tail -c 800 "$S/out/custom-prepare.stderr")"
    grep -q "^A_CTS_PREPARE state=complete cases=$custom_cases$" "$S/out/custom-prepare.txt" \
        || fail custom_prepare_marker
    log "custom_caselist=PASS sha256=$custom_sha cases=$custom_cases budget_s=$custom_budget"
    find "$S/custom.caselist" -maxdepth 0 -type f -delete
fi

docker run --rm --platform linux/arm64 --network none \
    --user 1001:1001 --group-add 44 --group-add 104 --group-add 107 -e HOME=/home/debug \
    --tmpfs /tmp:mode=1777,exec --tmpfs /run:mode=0755,exec \
    -v "$K:/kit:ro" -v /usr/bin/sudo:/usr/bin/sudo:ro \
    -v /usr/libexec/sudo:/usr/libexec/sudo:ro \
    -v /lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:ro \
    -v /usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:ro \
    -v /lib64/ld-linux-x86-64.so.2:/lib64/ld-linux-x86-64.so.2:ro \
    "$TAG" /bin/sh -c '
        root=/tmp/a-cts-detach
        mkdir -p "$root"
        cp /kit/a-cts-dut "$root/a-cts-dut"
        chmod 0755 "$root/a-cts-dut"
        printf "fixture\tcase\n" >"$root/expected.tsv"
        PF_ACTS_ROOT="$root" PF_ACTS_WORKER_FIXTURE=linger "$root/a-cts-dut" worker-start
        sleep 5
        pid=$(cat "$root/worker-run/worker.pid")
        sudo -n kill -0 "$pid"
        test "$(awk "{ print \$3 }" "/proc/$pid/stat")" != Z
        grep -q "^A_CTS_WORKER_LOG state=started pid=$pid$" "$root/worker-run/worker.log"
        grep -Fxq "ACTUAL_USER=gamer" "$root/worker-run/worker-environment.txt"
        grep -Fxq "ACTUAL_UID=1000" "$root/worker-run/worker-environment.txt"
        PF_ACTS_ROOT="$root" "$root/a-cts-dut" cleanup
    ' >"$S/out/detach.txt" 2>"$S/out/detach.stderr" \
    || fail worker_detach "$(tail -c 1200 "$S/out/detach.stderr")"
grep -q '^A_CTS_WORKER state=started pid=' "$S/out/detach.txt" || fail worker_detach_marker
grep -q '^A_CTS_CLEANUP state=complete$' "$S/out/detach.txt" || fail worker_cleanup_marker

docker run --rm --platform linux/arm64 --network none \
    --user 1001:1001 --group-add 44 --group-add 104 --group-add 107 -e HOME=/home/debug \
    --tmpfs /tmp:mode=1777,exec --tmpfs /run:mode=0755,exec \
    -v "$K:/kit:ro" -v /usr/bin/sudo:/usr/bin/sudo:ro \
    -v /usr/libexec/sudo:/usr/libexec/sudo:ro \
    -v /lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:ro \
    -v /usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:ro \
    -v /lib64/ld-linux-x86-64.so.2:/lib64/ld-linux-x86-64.so.2:ro \
    -v "$S/collect:/collect" \
    "$TAG" /bin/sh -c '
        root=/tmp/a-cts-worker-failure
        mkdir -p "$root"
        cp /kit/a-cts-dut "$root/a-cts-dut"
        chmod 0755 "$root/a-cts-dut"
        printf "fixture\tcase\n" >"$root/expected.tsv"
        printf "[    1.000000] powervr smoke: no reset\n" >"$root/dmesg.fixture"
        set +e
        PF_ACTS_ROOT="$root" PF_ACTS_WORKER_FIXTURE=fail "$root/a-cts-dut" worker-start >"$root/start.out" 2>&1
        rc=$?
        set -e
        test "$rc" -eq 1
        grep -q "^A_CTS_ERROR mode=worker-start reason=worker_not_alive$" "$root/start.out"
        grep -q "^A_CTS_WORKER_EXIT exit_code=23$" "$root/start.out"
        grep -q "^A_CTS_WORKER_LOG_TAIL_BEGIN$" "$root/start.out"
        grep -q "^A_CTS_WORKER_FIXTURE state=failed exit_code=23$" "$root/start.out"
        grep -q "^A_CTS_DMESG_TAIL_BEGIN$" "$root/start.out"
        grep -q "^A_CTS_DMESG_TAIL_END$" "$root/start.out"
        PF_ACTS_ROOT="$root" PF_ACTS_DMESG_FIXTURE="$root/dmesg.fixture" \
            "$root/a-cts-dut" worker-finalize >"$root/finalize.out"
        cp "$root/finalize.out" /collect/failure-finalize.out
        grep -q "^A_CTS_WORKER_FINALIZE state=ready outcome=partial " "$root/finalize.out"
        PF_ACTS_ROOT="$root" "$root/a-cts-dut" archive-receipt >"$root/receipt.out"
        cp "$root/receipt.out" /collect/failure-receipt.out
        sha=$(/kit/response-select failure-receipt-sha "^sha256=[0-9a-f]+$" "$root/receipt.out")
        bytes=$(/kit/response-select failure-receipt-bytes "^bytes=[0-9]+$" "$root/receipt.out")
        sha=${sha#sha256=}; bytes=${bytes#bytes=}
        test "${#sha}" -eq 64
        chunks=$(((bytes + 35999) / 36000))
        index=0
        while test "$index" -lt "$chunks"; do
            PF_ACTS_ROOT="$root" "$root/a-cts-dut" archive-chunk "$index" \
                >"/collect/failure-chunk-$index.stdout"
            index=$((index + 1))
        done
        cat "$root/start.out"
        printf "A_CTS_FAILURE_DEVICE_ARCHIVE state=ready chunks=%s\n" "$chunks"
        PF_ACTS_ROOT="$root" "$root/a-cts-dut" cleanup
    ' >"$S/out/worker-failure.txt" 2>"$S/out/worker-failure.stderr" \
    || fail worker_failure_diagnostics "$(tail -c 1200 "$S/out/worker-failure.stderr")"
grep -q '^A_CTS_WORKER_EXIT exit_code=23$' "$S/out/worker-failure.txt" \
    || fail worker_failure_exit_marker
failure_sha=$("$K/response-select" failure-receipt-sha \
    '^sha256=[0-9a-f]{64}$' "$S/collect/failure-receipt.out") \
    || fail worker_failure_receipt_sha
failure_bytes=$("$K/response-select" failure-receipt-bytes \
    '^bytes=[0-9]+$' "$S/collect/failure-receipt.out") \
    || fail worker_failure_receipt_bytes
failure_sha=${failure_sha#sha256=}; failure_bytes=${failure_bytes#bytes=}
failure_chunks=$(((failure_bytes + 35999) / 36000))
: >"$S/collect/failure-results.tar.gz"
for ((failure_index=0; failure_index<failure_chunks; failure_index++)); do
    "$K/collect-response-chunk" "failure-chunk-$failure_index" \
        "$S/collect/failure-chunk-$failure_index.stdout" \
        "$S/collect/failure-chunk-$failure_index.bin" \
        >"$S/collect/failure-chunk-$failure_index.host-result" \
        || fail worker_failure_chunk_parse
    cat "$S/collect/failure-chunk-$failure_index.bin" \
        >>"$S/collect/failure-results.tar.gz"
done
[[ $(wc -c <"$S/collect/failure-results.tar.gz") == "$failure_bytes" ]] \
    || fail worker_failure_archive_bytes
[[ $(sha256sum "$S/collect/failure-results.tar.gz" | cut -d' ' -f1) == "$failure_sha" ]] \
    || fail worker_failure_archive_sha
mkdir -p "$S/collect/failure-unpacked"
tar -xzf "$S/collect/failure-results.tar.gz" -C "$S/collect/failure-unpacked" \
    || fail worker_failure_archive_unpack
"$K/verify-results.sh" "$S/collect/failure-unpacked" \
    >"$S/collect/failure-host-verifier.out" \
    2>"$S/collect/failure-host-verifier.stderr" \
    || fail worker_failure_host_verify
grep -q '^A_CTS_VERIFY PASS outcome=partial ' "$S/collect/failure-host-verifier.out" \
    || fail worker_failure_host_marker
grep -q $'\tNotRun\t' "$S/collect/failure-unpacked/ledger.tsv" \
    || fail worker_failure_not_run
printf 'A_CTS_FAILURE_COLLECT state=pass outcome=partial sha256=%s bytes=%s\n' \
    "$failure_sha" "$failure_bytes" | tee -a "$S/out/worker-failure.txt"
grep -q '^A_CTS_FAILURE_COLLECT state=pass outcome=partial sha256=[0-9a-f]\{64\} bytes=[0-9][0-9]*$' \
    "$S/out/worker-failure.txt" || fail worker_failure_collect_marker

mkdir -p "$S/terminal-collect"
chmod 0777 "$S/terminal-collect"
docker run --rm --platform linux/arm64 --network none \
    --user 1001:1001 --group-add 44 --group-add 104 --group-add 107 -e HOME=/home/debug \
    --tmpfs /tmp:mode=1777,exec --tmpfs /run:mode=0755,exec \
    -v "$K:/kit:ro" -v /usr/bin/sudo:/usr/bin/sudo:ro \
    -v /usr/libexec/sudo:/usr/libexec/sudo:ro \
    -v /lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu:ro \
    -v /usr/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:ro \
    -v /lib64/ld-linux-x86-64.so.2:/lib64/ld-linux-x86-64.so.2:ro \
    -v "$S/terminal-collect:/collect" \
    "$TAG" /bin/sh -c '
        set -eu
        control=/tmp/a-cts-r41
        mkdir -p "$control"
        cp /kit/a-cts-dut "$control/a-cts-dut"
        chmod 0755 "$control/a-cts-dut"
        : >"$control/ledger.tsv"
        : >"$control/qpa-manifest.tsv"
        : >"$control/crash-evidence.tsv"
        : >"$control/harness-errors.tsv"
        n=1
        while test "$n" -le 2938; do
            printf "a5b-recovery-cases-r26.txt\tcase.%04d\n" "$n"
            n=$((n + 1))
        done >"$control/expected.tsv"
        printf "[    1.000000] powervr exact-rootfs r41 fixture: healthy\n" \
            >"$control/dmesg.fixture"
        /usr/bin/id >"$control/control.id"
        PF_ACTS_ROOT="$control" PF_ACTS_WORKER_FIXTURE=r41 \
            PF_ACTS_R41_FINALIZE_DELAY=8 PF_ACTS_DMESG_FIXTURE="$control/dmesg.fixture" \
            "$control/a-cts-dut" worker-start >"$control/start.out"
        pid=$(cat "$control/worker-run/worker.pid")
        awk "/^Uid:/ { exit !(\$2==1000 && \$3==1000) }" "/proc/$pid/status"
        PF_ACTS_ROOT="$control" "$control/a-cts-dut" worker-poll >"$control/poll.out"
        grep -qx "A_CTS_SANITY_BASELINE verdict=pass instrument=gles-uncompressed user=gamer uid=1000" \
            "$control/poll.out"
        grep -qx "A_CTS_PROGRESS state=running worker=alive worker_state=finalizing reason=harness_stop list=a5b-recovery-cases-r26.txt unit=0000 attempt=39 rc=0 commit_rc=76" \
            "$control/poll.out"
        PF_ACTS_ROOT="$control" PF_ACTS_FINALIZE_WAIT_SECONDS=20 \
            PF_ACTS_DMESG_FIXTURE="$control/dmesg.fixture" \
            "$control/a-cts-dut" worker-finalize >"$control/finalize.out"
        grep -Eq "^A_CTS_WORKER_FINALIZE state=ready outcome=partial .* waited=yes terminated=no$" \
            "$control/finalize.out"
        PF_ACTS_ROOT="$control" "$control/a-cts-dut" archive-receipt >"$control/receipt.out"
        cp "$control/control.id" "$control/poll.out" "$control/finalize.out" \
            "$control/receipt.out" /collect/
        sha=$(/kit/response-select r41-sha "^sha256=[0-9a-f]+$" "$control/receipt.out")
        bytes=$(/kit/response-select r41-bytes "^bytes=[0-9]+$" "$control/receipt.out")
        sha=${sha#sha256=}; bytes=${bytes#bytes=}
        chunks=$(((bytes + 35999) / 36000))
        index=0
        while test "$index" -lt "$chunks"; do
            PF_ACTS_ROOT="$control" "$control/a-cts-dut" archive-chunk "$index" \
                >"/collect/chunk-$index.stdout"
            index=$((index + 1))
        done
        PF_ACTS_ROOT="$control" "$control/a-cts-dut" cleanup
    ' >"$S/out/r41-exact.txt" 2>"$S/out/r41-exact.stderr" \
    || fail r41_exact_rootfs "$(tail -c 1200 "$S/out/r41-exact.stderr")"
grep -q '^uid=1001(debug) gid=1001(debug) ' "$S/terminal-collect/control.id" \
    || fail r41_control_identity
r41_sha=$("$K/response-select" r41-sha '^sha256=[0-9a-f]{64}$' \
    "$S/terminal-collect/receipt.out") || fail r41_receipt_sha
r41_bytes=$("$K/response-select" r41-bytes '^bytes=[0-9]+$' \
    "$S/terminal-collect/receipt.out") || fail r41_receipt_bytes
r41_sha=${r41_sha#sha256=}; r41_bytes=${r41_bytes#bytes=}
r41_chunks=$(((r41_bytes + 35999) / 36000))
: >"$S/terminal-collect/results.tar.gz"
for ((r41_index=0; r41_index<r41_chunks; r41_index++)); do
    "$K/collect-response-chunk" "r41-chunk-$r41_index" \
        "$S/terminal-collect/chunk-$r41_index.stdout" \
        "$S/terminal-collect/chunk-$r41_index.bin" \
        >"$S/terminal-collect/chunk-$r41_index.host-result" \
        || fail r41_chunk_parse
    cat "$S/terminal-collect/chunk-$r41_index.bin" >>"$S/terminal-collect/results.tar.gz"
done
[[ $(wc -c <"$S/terminal-collect/results.tar.gz") == "$r41_bytes" ]] \
    || fail r41_archive_bytes
[[ $(sha256sum "$S/terminal-collect/results.tar.gz" | cut -d' ' -f1) == "$r41_sha" ]] \
    || fail r41_archive_sha
mkdir -p "$S/terminal-collect/unpacked"
tar -xzf "$S/terminal-collect/results.tar.gz" -C "$S/terminal-collect/unpacked" \
    || fail r41_archive_unpack
"$K/verify-results.sh" "$S/terminal-collect/unpacked" \
    >"$S/terminal-collect/host-verifier.out" \
    2>"$S/terminal-collect/host-verifier.stderr" || fail r41_host_verify
grep -q '^A_CTS_VERIFY PASS outcome=partial expected=2938 ' \
    "$S/terminal-collect/host-verifier.out" || fail r41_host_marker
grep -qx 'A_CTS_SANITY_BASELINE verdict=pass instrument=gles-uncompressed user=gamer uid=1000' \
    "$S/terminal-collect/unpacked/recovery-sanity/baseline.summary" \
    || fail r41_sanity_archived
printf 'A_CTS_R41_EXACT state=pass control=debug worker=gamer live_state=running finalize=bounded archive=host-verified sha256=%s bytes=%s\n' \
    "$r41_sha" "$r41_bytes" | tee -a "$S/out/r41-exact.txt"

env -u PF_BEAD -u LG_USERNAME "$K/test-a-cts.sh" >"$S/out/hermetic.txt" 2>"$S/out/hermetic.stderr" \
    || fail hermetic "$(tail -c 800 "$S/out/hermetic.stderr")"
grep -q '^A_CTS_TEST PASS ' "$S/out/hermetic.txt" || fail hermetic_marker
log 'controls=PASS device_user_exact_rootfs=yes egl_ab_preflight=yes egl_probe_chunk_stage=yes collect_before_judge=yes eglinfo_rc2_non_gating=yes cts_runtime_lib_scan=yes image_dev_links=yes kit_links_absent=yes redfish_timeout_bound=yes detached_probe=yes probe_loader=yes probe_chunk_stage=yes probe_failure_continued=yes probe_matrix_complete=yes probe_timeout_invalid=yes discrim_loader=yes discrim_chunk_stage=yes discrim_static_template=yes discrim_nonzero_continued=yes discrim_missing_continued=yes discrim_timeout_continued=yes exact_bundle_prepare=yes exact_custom_prepare=yes worker_detach_5s=yes worker_failure_diagnostics=yes worker_failure_archive_verified=yes r41_debug_gamer=yes r41_finalize_bounded=yes r41_archive_verified=yes crash_recovery_injected=yes unbegun_not_crash=yes crash_evidence_unbounded=yes crash_suffix=yes five_state_ledger=yes qpa_host=yes aggregate_fail_closed=yes forbidden_env=yes'

teardown
trap - EXIT
log "SMOKE PASS a-cts image=${RAW_SHA:0:12} bundle=${BUNDLE_SHA:0:12} exact_rootfs=yes cases=124248 lists=13"
