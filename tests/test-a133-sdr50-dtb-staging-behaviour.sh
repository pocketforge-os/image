#!/usr/bin/env bash
# tsp-mc9m.60.29.33.16 behavioural coverage beside test-a133-sdr50-dtb-staging.sh:
# drive scripts/stage-a133-sdr50-dtb.sh and tools/verify-owned-spl-fat.py against
# a real FAT fixture and fake DTBs, then pin the build wiring that feeds them.
#   - the exact built SDR50 DTB bytes land at ::/dtb-sdr50.bin; ::/dtb.bin is unchanged
#   - the U-Boot layout checker runs on the SDR50 DTB (--fdt) and its refusal blocks staging
#   - a missing, empty or non-FDT SDR50 DTB fails closed; ::/dtb.bin can never be the target
#   - the final p4 verifier requires dtb-sdr50.bin when asked
#   - Dockerfile kernel stage builds + installs it; assemble passes it; builder CMA-guards it
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stage="${repo}/scripts/stage-a133-sdr50-dtb.sh"
verify="${repo}/tools/verify-owned-spl-fat.py"
builder="${repo}/scripts/build-sd-image.sh"
dockerfile="${repo}/build/Dockerfile.pf"
for tool in mformat mcopy mdir python3 cmp; do
    command -v "${tool}" >/dev/null || { echo "BLOCKED: missing ${tool}"; exit 75; }
done

scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT
fails=0
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# Fake FDT blobs: big-endian magic d00dfeed + distinct bodies.
mkfdt() { python3 -c 'import sys; open(sys.argv[1],"wb").write(bytes.fromhex("d00dfeed")+sys.argv[2].encode()*64)' "$1" "$2"; }
mkfdt "${scratch}/default.dtb" "shipping-odyssey"
mkfdt "${scratch}/sdr50.dtb"   "odyssey-sdr50-uhs"
printf 'Image fixture' > "${scratch}/Image"
printf 'initrd fixture' > "${scratch}/initrd.gz"
printf 'CONFIG_FIXTURE=y\n' > "${scratch}/uboot.config"
printf 'not an fdt at all' > "${scratch}/notfdt.dtb"
: > "${scratch}/empty.dtb"

# Fake layout checker: records argv; refuses when LAYOUT_REFUSE=1.
cat > "${scratch}/layout-check.py" <<'PY'
import os, sys
with open(os.environ["LAYOUT_LOG"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(1 if os.environ.get("LAYOUT_REFUSE") == "1" else 0)
PY
export LAYOUT_LOG="${scratch}/layout.log"

newfat() {
    rm -f "$1"
    truncate -s 8M "$1"
    mformat -i "$1" :: >/dev/null
    mcopy -i "$1" "${scratch}/Image" ::/Image
    mcopy -i "$1" "${scratch}/default.dtb" ::/dtb.bin
    mcopy -i "$1" "${scratch}/initrd.gz" ::/initrd.gz
    mmd -i "$1" ::/boot
    printf 'BM' > "${scratch}/logo.bmp"
    mcopy -i "$1" "${scratch}/logo.bmp" ::/boot/pocketforge-logo.bmp
}
run_stage() { # <fat> <dtb> [dest]
    bash "${stage}" --fat "$1" --dtb "$2" --dest "${3:-::/dtb-sdr50.bin}" \
        --default-dtb "${scratch}/default.dtb" --layout-check "${scratch}/layout-check.py" \
        --uboot-config "${scratch}/uboot.config" --image "${scratch}/Image" \
        --initrd "${scratch}/initrd.gz"
}
on_fat() { mdir -b -i "$1" "$2" >/dev/null 2>&1; }
fat_sha() { mcopy -n -o -i "$1" "$2" "${scratch}/rb" && sha256sum "${scratch}/rb" | cut -d' ' -f1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

# 1. happy path: exact bytes staged, default unchanged, layout checker saw the SDR50 DTB.
fat="${scratch}/p4.vfat"; newfat "${fat}"; : > "${LAYOUT_LOG}"
if out="$(run_stage "${fat}" "${scratch}/sdr50.dtb" 2>&1)"; then
    [ "$(fat_sha "${fat}" ::/dtb-sdr50.bin)" = "$(sha "${scratch}/sdr50.dtb")" ] \
        || fail "staged ::/dtb-sdr50.bin bytes differ from the built SDR50 DTB"
    [ "$(fat_sha "${fat}" ::/dtb.bin)" = "$(sha "${scratch}/default.dtb")" ] \
        || fail "::/dtb.bin changed while staging the SDR50 DTB"
    grep -Fxq -- "--config ${scratch}/uboot.config --image ${scratch}/Image --fdt ${scratch}/sdr50.dtb --initrd ${scratch}/initrd.gz" "${LAYOUT_LOG}" \
        || fail "layout checker was not run on the SDR50 DTB (log: $(cat "${LAYOUT_LOG}"))"
    python3 -B "${verify}" "${fat}" --require dtb-sdr50.bin >/dev/null \
        || fail "verify-owned-spl-fat.py --require dtb-sdr50.bin rejected a staged FAT"
else
    fail "happy-path staging failed: ${out}"
fi

# expect_refusal <name> <reason> <fat> <dtb> [dest] — must fail with reason, leave p4 as it was.
expect_refusal() {
    local name="$1" reason="$2" f="$3"; shift 3
    local before; before="$(fat_sha "${f}" ::/dtb.bin)"
    if out="$(run_stage "${f}" "$@" 2>&1)"; then
        fail "${name}: staging succeeded, expected reason=${reason}"
    else
        grep -q "reason=${reason}" <<<"${out}" || fail "${name}: expected reason=${reason}, got: ${out}"
    fi
    [ "$(fat_sha "${f}" ::/dtb.bin)" = "${before}" ] || fail "${name}: ::/dtb.bin was modified"
}
newfat "${fat}"
expect_refusal missing sdr50_dtb_missing "${fat}" "${scratch}/absent.dtb"
expect_refusal empty sdr50_dtb_missing "${fat}" "${scratch}/empty.dtb"
expect_refusal notfdt sdr50_dtb_not_fdt "${fat}" "${scratch}/notfdt.dtb"
expect_refusal same-as-default sdr50_dtb_equals_default "${fat}" "${scratch}/default.dtb"
expect_refusal replace-default would_replace_default_dtb "${fat}" "${scratch}/sdr50.dtb" ::/dtb.bin
expect_refusal bad-dest bad_dest "${fat}" "${scratch}/sdr50.dtb" ::/Image
on_fat "${fat}" ::/dtb-sdr50.bin && fail "a refused staging left ::/dtb-sdr50.bin on p4"
LAYOUT_REFUSE=1 expect_refusal layout-refused sdr50_layout_check_failed "${fat}" "${scratch}/sdr50.dtb"
on_fat "${fat}" ::/dtb-sdr50.bin && fail "layout refusal still staged ::/dtb-sdr50.bin"
python3 -B "${verify}" "${fat}" --require dtb-sdr50.bin >/dev/null 2>&1 \
    && fail "verify-owned-spl-fat.py --require dtb-sdr50.bin accepted a FAT without it"
python3 -B "${verify}" "${fat}" >/dev/null || fail "default p4 verification regressed"
run_stage "${fat}" "${scratch}/sdr50.dtb" >/dev/null 2>&1 || fail "staging after refusals failed"
expect_refusal already-staged dest_exists "${fat}" "${scratch}/sdr50.dtb"

# 2. wiring: the build feeds the helper, gates it and keeps the default path.
want() { grep -Fq -- "$2" "$1" || fail "$(basename "$1") lacks: $2"; }
want "${builder}" 'mcopy -i "${GENIMAGE_INPUT}/boot-resource.vfat" "${DTB_FILE}"       "::/dtb.bin"'
want "${builder}" '--dest "::/dtb-sdr50.bin"'
want "${builder}" '--layout-check "${UBOOT_LAYOUT_CHECK}"'
want "${builder}" 'CMA_GUARD_ARGS[1]="${SDR50_DTB_FILE:?SDR50 opt-in DTB was not prepared}"'
want "${builder}" '(kernel build lacks it)'
want "${builder}" 'FAT_VERIFY_ARGS+=(--require dtb-sdr50.bin)'
want "${dockerfile}" 'make -j"$(nproc)" Image modules "${dtb_target}" ${sdr50_target:+"${sdr50_target}"}'
want "${dockerfile}" 'install -D -m0644 "${sdr50_dts%.dts}.dtb"  /out/boot/sun50i-a133-pocketforge-odyssey-sdr50.dtb'
want "${dockerfile}" 'KERNEL_SDR50_DTB="${SDR50_DTB}"'
# The CMA guard must cover the SDR50 DTB before the FAT image exists, and the
# helper must run after the default payload is staged and before the p4 verify.
idx() { grep -Fn -- "$2" "$1" | head -n1 | cut -d: -f1; }
cma="$(idx "${builder}" 'CMA_GUARD_ARGS[1]=')"
vfat="$(idx "${builder}" 'make-reproducible-vfat.sh')"
dflt="$(idx "${builder}" '"::/dtb.bin"')"
helper="$(idx "${builder}" 'stage-a133-sdr50-dtb.sh')"
fatv="$(idx "${builder}" 'FAT_VERIFY_ARGS+=(--require dtb-sdr50.bin)')"
[ -n "${cma}" ] && [ -n "${vfat}" ] && [ "${cma}" -lt "${vfat}" ] || fail "SDR50 CMA guard is not before FAT creation"
[ -n "${helper}" ] && [ "${dflt}" -lt "${helper}" ] && [ "${helper}" -lt "${fatv}" ] \
    || fail "SDR50 staging is not between the default dtb.bin copy and the p4 verify"

[ "${fails}" -eq 0 ] || { echo "FAIL: ${fails} SDR50 staging check(s) failed"; exit 1; }
echo "PASS: SDR50 opt-in DTB staged byte-exact as ::/dtb-sdr50.bin, layout-checked, fail-closed, default dtb.bin unchanged"
