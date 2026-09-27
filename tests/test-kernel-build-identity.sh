#!/usr/bin/env bash
# Execute the exact Dockerfile kernel heredoc with a tiny hermetic Kbuild stand-in.
# The stand-in models Linux 7.2's init/Makefile UTS_VERSION rule while keeping
# KERNELRELEASE, module placement, and vermagic observable and independent.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${root}/build/Dockerfile.pf"
scratch="$(mktemp -d)"
trap 'find "${scratch}" -mindepth 1 -delete; rmdir "${scratch}"' EXIT
mkdir -p "${scratch}/bin"

cat >"${scratch}/bin/make" <<'EOF'
#!/bin/sh
set -eu
case " $* " in
  *" fixture_defconfig "*)
    mkdir -p include/config arch/arm64/boot/dts/allwinner
    printf '%s\n' '# CONFIG_LOCALVERSION_AUTO is not set' >.config
    printf '%s\n' "$FAKE_KREL" >include/config/kernel.release
    : >arch/arm64/boot/dts/allwinner/fixture.dts
    ;;
  *" Image modules "*)
    mkdir -p arch/arm64/boot include/generated drivers/gpu/drm/imagination
    : >arch/arm64/boot/Image
    : >arch/arm64/boot/dts/allwinner/fixture.dtb
    : >drivers/gpu/drm/imagination/powervr.ko
    : >Module.symvers
    : >System.map
    uts="#${KBUILD_BUILD_VERSION:-1} SMP PREEMPT_DYNAMIC ${KBUILD_BUILD_TIMESTAMP}"
    uts="$(printf '%s' "$uts" | cut -b -64)"
    printf '#define UTS_VERSION "%s"\n' "$uts" >include/generated/utsversion.h
    ;;
  *" modules_install "*)
    modroot=
    for arg in "$@"; do
      case "$arg" in INSTALL_MOD_PATH=*) modroot=${arg#INSTALL_MOD_PATH=} ;; esac
    done
    test -n "$modroot"
    dest="$modroot/lib/modules/$FAKE_KREL"
    mkdir -p "$dest/kernel/drivers/gpu/drm/imagination"
    cp drivers/gpu/drm/imagination/powervr.ko "$dest/kernel/drivers/gpu/drm/imagination/"
    ln -s /work/kernel "$dest/build"
    ln -s /work/kernel "$dest/source"
    ;;
esac
EOF
cat >"${scratch}/bin/aarch64-none-linux-gnu-objcopy" <<'EOF'
#!/bin/sh
printf 'vermagic=%s SMP preempt\0' "$FAKE_KREL"
EOF
chmod +x "${scratch}/bin/make" "${scratch}/bin/aarch64-none-linux-gnu-objcopy"

sed -n "/^RUN <<'KERNEL'$/,/^KERNEL$/p" "$dockerfile" | sed '1d;$d' \
  >"${scratch}/kernel-heredoc.sh"

locked_sha=6d86d65efaa275eb18c810c531c19ec6249d85b5
other_sha=0123456789abcdef0123456789abcdef01234567
krel=7.2.0-pocketforge

run_kernel_stage() {
  local label=$1 sha=${2-__unset__} staged_sha=${3-__unset__}
  local work="${scratch}/${label}"
  mkdir -p "${work}/kernel" "${work}/out"
  if [[ $staged_sha != __unset__ ]]; then
    printf '%s\n' "$staged_sha" >"${work}/kernel/.pf-source-revision"
  fi
  sed "s#/work/kernel#${work}/kernel#g; s#/out#${work}/out#g" \
    "${scratch}/kernel-heredoc.sh" >"${work}/run.sh"
  local -a env_args=(
    "PATH=${scratch}/bin:${PATH}" "FAKE_KREL=${krel}"
    PF_KERNEL_REPO=kernel-sunxi-7.x PF_KERNEL_DEFCONFIG=fixture_defconfig
    PF_KERNEL_DTB=fixture.dtb PF_TOOLCHAIN_GCC_VERSION=14.2.0
    PF_KERNEL_SOURCE_DATE_EPOCH=1790512830 SOURCE_DATE_EPOCH=1790512830
  )
  if [[ $sha != __unset__ ]]; then
    env_args+=("PF_KERNEL_SHA=${sha}")
  fi
  env "${env_args[@]}" bash "${work}/run.sh" >"${work}/stdout" 2>"${work}/stderr"
}

run_kernel_stage locked "$locked_sha" "$locked_sha"
locked_uts="$(sed -n 's/^#define UTS_VERSION "\(.*\)"$/\1/p' \
  "${scratch}/locked/kernel/include/generated/utsversion.h")"
[[ $locked_uts == "#${locked_sha:0:12} "* ]]
[[ ${#locked_uts} -le 64 ]]
test "$(cat "${scratch}/locked/out/build/kernel.release")" = "$krel"
test -d "${scratch}/locked/out/lib/modules/${krel}"
test "$(find "${scratch}/locked/out/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')" = "$krel"
grep -Fx "vermagic=${krel} SMP preempt" "${scratch}/locked/out/build/.pf-kernel-provenance" >/dev/null
grep -Fx "build.version=${locked_sha:0:12}" "${scratch}/locked/out/build/.pf-kernel-provenance" >/dev/null

run_kernel_stage other "$other_sha" "$other_sha"
other_uts="$(sed -n 's/^#define UTS_VERSION "\(.*\)"$/\1/p' \
  "${scratch}/other/kernel/include/generated/utsversion.h")"
[[ $other_uts == "#${other_sha:0:12} "* ]]
test "$other_uts" != "$locked_uts"
test "$(cat "${scratch}/other/out/build/kernel.release")" = "$krel"
test -d "${scratch}/other/out/lib/modules/${krel}"

expect_rejected() {
  local label=$1 sha=${2-__unset__} staged_sha=${3-__unset__}
  if run_kernel_stage "$label" "$sha" "$staged_sha"; then
    printf 'FAIL: kernel identity case %s was accepted\n' "$label" >&2
    exit 1
  fi
}
expect_rejected missing
expect_rejected short deadbeef deadbeef
expect_rejected uppercase 6D86D65EFAA275EB18C810C531C19EC6249D85B5 6D86D65EFAA275EB18C810C531C19EC6249D85B5
expect_rejected nonhex 6d86d65efaa275eb18c810c531c19ec6249d85bz 6d86d65efaa275eb18c810c531c19ec6249d85bz
expect_rejected unresolved "$locked_sha" "$other_sha"

printf 'PASS: lock-resolved SHA drives UTS_VERSION while release, module path, and vermagic stay fixed\n'
