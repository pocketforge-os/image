#!/usr/bin/env bash
# Install the on-disk production fonts for the pf-shell text stack (tsp-ihne1.12).
#
# pf-shell links pf-render, which memory-maps its production fonts from
# /usr/share/fonts/pocketforge at runtime — no shipped binary embeds font bytes.
# v1 stages exactly the runtime's canonical display set: the two Latin faces the
# goldens pin plus the Noto Sans CJK display fallback — guaranteed for CJK user
# data (app titles, SSIDs, Bluetooth names) in every UI language — with their
# OFL licenses. The runtime resolver (CANONICAL_FONT_ORDER) requires all three
# faces and panics otherwise, so a CJK-less directory is refused here at build
# time; anything else staged is refused too, and a missing face fails closed
# together with pf-shell. Input-method language packs install their own fonts
# later (design/input-layer #l10n L2).
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: install-shell-fonts.sh <runtime-stage> <rootfs>" >&2
    exit 2
fi

runtime_stage="$1"
rootfs="$2"
staged="${runtime_stage}/share/fonts/pocketforge"
expected="Fraunces-OFL.txt
Fraunces[SOFT,WONK,opsz,wght].ttf
Manrope-OFL.txt
Manrope[wght].ttf
NotoSansCJK-OFL.txt
NotoSansCJK-Regular.ttc"

[ -d "${staged}" ] || {
    echo "FATAL: pf-shell font directory missing from runtime stage: ${staged}" >&2
    exit 1
}
found="$(cd "${staged}" && find . -mindepth 1 ! -type d -printf '%P\n' | LC_ALL=C sort)"
[ "${found}" = "${expected}" ] || {
    echo "FATAL: staged shell fonts differ from the canonical display set" >&2
    echo "expected:" >&2
    printf '%s\n' "${expected}" >&2
    echo "staged:" >&2
    printf '%s\n' "${found}" >&2
    exit 1
}

while IFS= read -r face; do
    install -D -m 0644 "${staged}/${face}" "${rootfs}/usr/share/fonts/pocketforge/${face}"
done <<< "${found}"

echo "[customize] pf-shell fonts installed to /usr/share/fonts/pocketforge (canonical display set: Latin + CJK fallback)"
