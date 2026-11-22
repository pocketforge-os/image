#!/usr/bin/env bash
# Bootchain TF-A reset-capability contract test.
# Proves the EXECUTABLE contract (not mere string search):
#   - ARG PF_TFA_RESET_CAPABILITY is declared in the bootchain stage so the
#     variable exists under `set -u` inside the RUN heredoc.
#   - axp717  -> SUNXI_AXP717_SYSTEM_RESET=1  (in make args AND provenance)
#   - watchdog -> SUNXI_AXP717_SYSTEM_RESET=0  (in make args AND provenance)
#   - invalid / empty values fail closed (exit non-zero, typed refusal).
# Tampering with the stage ARG, either mapping, the make argument, or the
# provenance entry makes this test red.
set -uo pipefail

root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
dockerfile="${root}/build/Dockerfile.pf"
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/bootchain-reset-cap.XXXXXX")
trap 'find "$scratch" -mindepth 1 -delete; rmdir "$scratch"' EXIT

# ---------------------------------------------------------------------------
# 1. Static contract: the bootchain stage must declare ARG PF_TFA_RESET_CAPABILITY.
#    Without this the heredoc's `set -u` trips on the first reference.
# ---------------------------------------------------------------------------
bootchain_stage_arg_block=$(awk '
  /^FROM .* AS bootchain$/ {p=1; next}
  p && /^FROM / {exit}
  p && /^ARG / {print}
' "$dockerfile")

printf '%s\n' "$bootchain_stage_arg_block" \
  | grep -qxF 'ARG PF_TFA_RESET_CAPABILITY' \
  || { printf 'FAIL: bootchain stage missing ARG PF_TFA_RESET_CAPABILITY\n' >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2. Static contract: provenance must record both tfa_reset_capability and
#    sunxi_system_reset (proves the mapping reaches provenance, not just make).
# ---------------------------------------------------------------------------
grep -q "printf.*'tfa_reset_capability=%s sunxi_system_reset=%s" "$dockerfile" \
  || { printf 'FAIL: bootchain provenance must record tfa_reset_capability AND sunxi_system_reset\n' >&2; exit 1; }

# ---------------------------------------------------------------------------
# 3. Static contract: the make invocation must pass SUNXI_AXP717_SYSTEM_RESET
#    sourced from the same variable the case statement writes.
# ---------------------------------------------------------------------------
grep -q 'SUNXI_AXP717_SYSTEM_RESET=${SUNXI_RESET_VAL}' "$dockerfile" \
  || { printf 'FAIL: bootchain make invocation must pass SUNXI_AXP717_SYSTEM_RESET=${SUNXI_RESET_VAL}\n' >&2; exit 1; }

# ---------------------------------------------------------------------------
# 4. Static contract: the diagnostic must be POSIX-safe (no ${var!r}).
# ---------------------------------------------------------------------------
if grep -Fq '${PF_TFA_RESET_CAPABILITY!r}' "$dockerfile"; then
  printf 'FAIL: bootchain diagnostic uses non-POSIX ${PF_TFA_RESET_CAPABILITY!r}\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Executable contract: run the BOOTCHAIN heredoc end-to-end with a stub
#    make that records its arguments. Verifies both valid mappings reach the
#    TF-A make call AND the provenance, and invalid values fail closed.
# ---------------------------------------------------------------------------
# Extract BOOTCHAIN heredoc body (drop RUN line and closing BOOTCHAIN sentinel).
sed -n "/^RUN <<'BOOTCHAIN'$/,/^BOOTCHAIN$/p" "$dockerfile" \
  | sed '1d;$d' >"${scratch}/bootchain.sh"

# Substitute Docker-internal paths to scratch equivalents so the script runs
# on the host without root or Docker.
sed -i \
  -e "s|/work/tfa|${scratch}/work/tfa|g" \
  -e "s|/work/uboot|${scratch}/work/uboot|g" \
  -e "s|/out|${scratch}/out|g" \
  -e "s|/opt/arm-\${PF_TOOLCHAIN_GCC_VERSION}/bin|${scratch}/toolchain/bin|g" \
  "${scratch}/bootchain.sh"

# Stub make: records every invocation's argument list (so the test can prove
# the mapping reached `make`), and synthesises the minimum artifacts the
# bootchain script expects (BL31 binary + U-Boot release/SPL binary).
mkdir -p "${scratch}/bin"
cat >"${scratch}/bin/make" <<'STUB_MAKE'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"${STUB_MAKE_LOG}"
plat="" reset=""
for arg in "$@"; do
  case "$arg" in
    PLAT=*)                        plat=${arg#PLAT=} ;;
    SUNXI_AXP717_SYSTEM_RESET=*)   reset=${arg#SUNXI_AXP717_SYSTEM_RESET=} ;;
  esac
done
printf 'PLAT=%s\n' "$plat" >>"${STUB_MAKE_LOG}.plat"
if [ -n "$reset" ]; then
  printf 'SUNXI_AXP717_SYSTEM_RESET=%s\n' "$reset" >>"${STUB_MAKE_LOG}.reset"
fi
for arg in "$@"; do
  case "$arg" in
    bl31)
      mkdir -p "${STUB_WORK}/tfa/build/${plat}/debug"
      : >"${STUB_WORK}/tfa/build/${plat}/debug/bl31.bin"
      ;;
  esac
done
# U-Boot side: synthesize defconfig outputs + SPL binary embedding the release
# string the identity gate greps for. The release must include the "-g<sha12>"
# suffix that the bootchain writes to .scmversion (identity gate checks it).
has_defconfig=0
for arg in "$@"; do
  case "$arg" in *_defconfig) has_defconfig=1; break ;; esac
done
if [ "$has_defconfig" -eq 1 ]; then
  mkdir -p include/config
  scmversion=""
  [ -f .scmversion ] && scmversion=$(cat .scmversion)
  printf '%s\n' "2025.10${scmversion}" >include/config/uboot.release
  : >.config
fi
# Detect the final SPL link invocation (contains BL31=...) and emit the binary.
case "$*" in
  *BL31=*)
    rel=$(cat include/config/uboot.release)
    # Must contain "U-Boot SPL <rel>" verbatim for the identity gate's grep -aq.
    { printf 'U-Boot SPL %s' "$rel"; dd if=/dev/zero bs=1 count=256 2>/dev/null; } \
      >u-boot-sunxi-with-spl.bin
    ;;
esac
exit 0
STUB_MAKE
chmod +x "${scratch}/bin/make"

# Cross-compile stubs: the U-Boot make would invoke these through CROSS_COMPILE.
# We only need them to exist as a binary for any path that might call them;
# the stub make above does the real work so these just exit 0.
mkdir -p "${scratch}/toolchain/bin"
for cc_tool in gcc ld objcopy ar as; do
  cat >"${scratch}/toolchain/bin/aarch64-none-linux-gnu-${cc_tool}" <<'STUB_CC'
#!/bin/sh
exit 0
STUB_CC
  chmod +x "${scratch}/toolchain/bin/aarch64-none-linux-gnu-${cc_tool}"
done

run_bootchain() {
  local label=$1 cap=${2-__unset__} defconfig=${3-tg5050_defconfig}
  local work="${scratch}/run-${label}"
  rm -rf "${work}"
  mkdir -p "${work}/work/tfa" "${work}/work/uboot" "${work}/out"
  : >"${work}/make.log"

  sed -e "s|${scratch}/work|${work}/work|g" \
      -e "s|${scratch}/out|${work}/out|g" \
      "${scratch}/bootchain.sh" >"${work}/run.sh"

  local -a env_args=(
    "PATH=${scratch}/bin:/usr/bin:/bin"
    "PF_BOOTCHAIN_MODEL=sunxi-spl-uboot"
    "PF_UBOOT_REPO=uboot-test"
    "PF_UBOOT_SHA=abcdef0123456789abcdef0123456789abcdef01"
    "PF_UBOOT_DEFCONFIG=${defconfig}"
    "PF_TFA_REPO=tfa-test"
    "PF_TFA_SHA=1234567890abcdef1234567890abcdef12345678"
    "PF_TFA_PLAT=sun50i_a523"
    "PF_TOOLCHAIN_GCC_VERSION=10.3-2021.07"
    "PF_BOOTCHAIN_SOURCE_DATE_EPOCH=1790512830"
    "STUB_MAKE_LOG=${work}/make.log"
    "STUB_WORK=${work}/work"
  )
  if [ "$cap" != "__unset__" ]; then
    env_args+=("PF_TFA_RESET_CAPABILITY=${cap}")
  fi
  env "${env_args[@]}" sh "${work}/run.sh" >"${work}/stdout" 2>"${work}/stderr"
}

# --- Case A: axp717 maps to SUNXI_AXP717_SYSTEM_RESET=1 in make + provenance.
run_bootchain axp717 axp717
grep -qxF 'SUNXI_AXP717_SYSTEM_RESET=1' "${scratch}/run-axp717/make.log.reset" \
  || { printf 'FAIL: axp717 did not produce SUNXI_AXP717_SYSTEM_RESET=1 in make call\n' >&2
       cat "${scratch}/run-axp717/stderr" >&2; exit 1; }
grep -qxF 'tfa_reset_capability=axp717 sunxi_system_reset=1' \
  "${scratch}/run-axp717/out/.pf-bootchain-provenance" \
  || { printf 'FAIL: axp717 provenance missing tfa_reset_capability=axp717 sunxi_system_reset=1\n' >&2
       cat "${scratch}/run-axp717/out/.pf-bootchain-provenance" >&2; exit 1; }

# --- Case B: watchdog maps to SUNXI_AXP717_SYSTEM_RESET=0 in make + provenance.
run_bootchain watchdog watchdog
grep -qxF 'SUNXI_AXP717_SYSTEM_RESET=0' "${scratch}/run-watchdog/make.log.reset" \
  || { printf 'FAIL: watchdog did not produce SUNXI_AXP717_SYSTEM_RESET=0 in make call\n' >&2
       cat "${scratch}/run-watchdog/stderr" >&2; exit 1; }
grep -qxF 'tfa_reset_capability=watchdog sunxi_system_reset=0' \
  "${scratch}/run-watchdog/out/.pf-bootchain-provenance" \
  || { printf 'FAIL: watchdog provenance missing tfa_reset_capability=watchdog sunxi_system_reset=0\n' >&2
       cat "${scratch}/run-watchdog/out/.pf-bootchain-provenance" >&2; exit 1; }

# --- Case C: invalid value fails closed (non-zero exit) with typed refusal.
rc=0
run_bootchain invalid "bogus" || rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'FAIL: invalid PF_TFA_RESET_CAPABILITY value was accepted\n' >&2; exit 1
fi
grep -q "bootchain FAIL: PF_TFA_RESET_CAPABILITY must be axp717 or watchdog" \
  "${scratch}/run-invalid/stderr" \
  || { printf 'FAIL: invalid case must emit typed refusal on stderr/stdout\n' >&2
       cat "${scratch}/run-invalid/stderr" >&2; exit 1; }
# The diagnostic must NOT use non-POSIX ${var!r} — prove the script itself
# doesn't contain it after extraction.
grep -qF '${PF_TFA_RESET_CAPABILITY!r}' "${scratch}/run-invalid/run.sh" \
  && { printf 'FAIL: extracted bootchain still contains non-POSIX ${PF_TFA_RESET_CAPABILITY!r}\n' >&2; exit 1; }

# --- Case D: empty value also fails closed.
rc=0
run_bootchain empty "" || rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'FAIL: empty PF_TFA_RESET_CAPABILITY value was accepted\n' >&2; exit 1
fi

printf 'PASS: bootchain TF-A reset-capability contract (ARG declared; axp717→1 and watchdog→0 reach make+provenance; invalid/empty fail closed; no non-POSIX diagnostic)\n'
