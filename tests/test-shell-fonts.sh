#!/usr/bin/env bash
# tsp-ihne1.12: the pf-shell text stack memory-maps its production fonts from
# /usr/share/fonts/pocketforge; no shipped binary embeds font bytes. This test
# runs the real installer helper against fixtures with positive and negative
# controls in one invocation, and pins the wiring contracts (rootfs builder call
# site, open-gated Dockerfile staging, a523 exclusion).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="${root}/scripts/install-shell-fonts.sh"
rootfs_builder="${root}/scripts/build-rootfs.sh"
dockerfile="${root}/build/Dockerfile.pf"
tmp="$(mktemp -d)"
trap 'find "${tmp}" -mindepth 1 -delete; rmdir "${tmp}"' EXIT

# --- fixture runtime stage carrying the exact v1 Latin-only set ---------------
runtime="${tmp}/runtime"
mkdir -p "${runtime}/share/fonts/pocketforge"
printf 'manrope bytes\n' > "${runtime}/share/fonts/pocketforge/Manrope[wght].ttf"
printf 'manrope license\n' > "${runtime}/share/fonts/pocketforge/Manrope-OFL.txt"
printf 'fraunces bytes\n' > "${runtime}/share/fonts/pocketforge/Fraunces[SOFT,WONK,opsz,wght].ttf"
printf 'fraunces license\n' > "${runtime}/share/fonts/pocketforge/Fraunces-OFL.txt"

rootfs="${tmp}/rootfs"
mkdir -p "${rootfs}"
"${installer}" "${runtime}" "${rootfs}"
for face in "Manrope[wght].ttf" "Manrope-OFL.txt" \
    "Fraunces[SOFT,WONK,opsz,wght].ttf" "Fraunces-OFL.txt"; do
    cmp "${runtime}/share/fonts/pocketforge/${face}" \
        "${rootfs}/usr/share/fonts/pocketforge/${face}"
    test "$(stat -c %a "${rootfs}/usr/share/fonts/pocketforge/${face}")" = 644
done
test "$(find "${rootfs}/usr/share/fonts/pocketforge" -mindepth 1 ! -type d | wc -l)" = 4

# --- negative controls: every deviation fails closed --------------------------
expect_fatal() {
    local label="$1" pattern="$2"
    if "${installer}" "${runtime}" "${tmp}/scratch-rootfs" >"${tmp}/neg.log" 2>&1; then
        echo "FAIL: shell-font install accepted ${label}" >&2
        exit 1
    fi
    grep -F "${pattern}" "${tmp}/neg.log" >/dev/null
    test ! -e "${tmp}/scratch-rootfs/usr/share/fonts/pocketforge" || {
        echo "FAIL: refused install still wrote fonts (${label})" >&2
        exit 1
    }
}

# A missing face is refused: pf-shell would start and panic at its first text.
mv "${runtime}/share/fonts/pocketforge/Manrope[wght].ttf" "${tmp}/held"
expect_fatal "a missing Manrope face" \
    "FATAL: staged shell fonts differ from the v1 Latin-only set"
mv "${tmp}/held" "${runtime}/share/fonts/pocketforge/Manrope[wght].ttf"

# A staged CJK collection is refused: v1 ships Latin-only (design #l10n; CJK
# installs only with those languages, later).
printf 'cjk bytes\n' > "${runtime}/share/fonts/pocketforge/NotoSansCJK-Regular.ttc"
expect_fatal "a staged CJK collection" "NotoSansCJK-Regular.ttc"
find "${runtime}/share/fonts/pocketforge/NotoSansCJK-Regular.ttc" -delete

# A missing staged font directory is refused.
mv "${runtime}/share/fonts" "${tmp}/held-fonts"
expect_fatal "a missing staged font directory" \
    "FATAL: pf-shell font directory missing from runtime stage"
mv "${tmp}/held-fonts" "${runtime}/share/fonts"

# --- wiring contracts ----------------------------------------------------------
# The rootfs builder installs fonts only inside the pf-shell display-gated block
# (so closed a133/a523, which never stage pf-shell, never see a font byte).
# The greps match literal '${...}' source text, so single quotes are intended.
# shellcheck disable=SC2016
shell_line="$(grep -Fn 'install -D -m 0755 "${SHELL_BIN}"' "${rootfs_builder}" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016
fonts_line="$(grep -Fn 'install-shell-fonts.sh" "${RUNTIME_DIR}" "${ROOTFS}"' \
    "${rootfs_builder}" | head -1 | cut -d: -f1)"
display_else_line="$(grep -Fn 'F13 pf-shell NOT-SHIPPED' "${rootfs_builder}" | head -1 | cut -d: -f1)"
test -n "${shell_line}" && test -n "${fonts_line}" && test -n "${display_else_line}"
test "${shell_line}" -lt "${fonts_line}"
test "${fonts_line}" -lt "${display_else_line}"

# The Dockerfile stages the fonts only inside the open-gated runtime block.
# shellcheck disable=SC2016
open_line="$(grep -Fn 'if [ "${PF_GPU_MODEL:-ddk}" = "open" ]; then' "${dockerfile}" | head -1 | cut -d: -f1)"
stage_line="$(grep -Fn '/out/share/fonts/pocketforge' "${dockerfile}" | head -1 | cut -d: -f1)"
end_line="$(grep -n '^cat /out/.pf-runtime-provenance' "${dockerfile}" | head -1 | cut -d: -f1)"
test -n "${open_line}" && test -n "${stage_line}" && test -n "${end_line}"
test "${open_line}" -lt "${stage_line}"
test "${stage_line}" -lt "${end_line}"

# The exact v1 Latin faces are what the Dockerfile stages; a CJK collection is
# never staged (v1 Latin-only, design #l10n). Explicit if/then so a violated
# negative fails closed rather than being swallowed by `!` under errexit.
if ! grep -Fq '"Manrope[wght].ttf"' "${dockerfile}"; then
    echo "FAIL: Dockerfile does not stage the Manrope face" >&2
    exit 1
fi
if grep -Fq 'NotoSansCJK' "${dockerfile}"; then
    echo "FAIL: Dockerfile stages a CJK collection (v1 is Latin-only)" >&2
    exit 1
fi

# The a523 (closed) builder never learns about the fonts, keeping its baseline
# byte-identical.
if grep -Fq 'fonts/pocketforge' "${root}/scripts/build-rootfs-a523.sh"; then
    echo "FAIL: a523 builder references the shell fonts" >&2
    exit 1
fi

echo 'shell-fonts contract: PASS (exact v1 Latin-only set installed 0644; missing face, staged CJK and missing directory each fail closed; staging open-gated and paired with pf-shell)'
