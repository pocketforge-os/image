#!/usr/bin/env bash
# Install the on-disk production fonts for the pf-shell text stack (tsp-ihne1.12).
#
# pf-shell links pf-render, which memory-maps its production fonts from
# /usr/share/fonts/pocketforge at runtime — no shipped binary embeds font bytes.
# v1 stages exactly the two Latin faces the runtime goldens pin, plus their OFL
# licenses (design/input-layer README #l10n: CJK fonts install only with those
# languages, later). Anything else staged — including a CJK collection — is
# refused, and a missing face fails closed together with pf-shell.
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
Manrope[wght].ttf"

[ -d "${staged}" ] || {
    echo "FATAL: pf-shell font directory missing from runtime stage: ${staged}" >&2
    exit 1
}
found="$(cd "${staged}" && find . -mindepth 1 ! -type d -printf '%P\n' | LC_ALL=C sort)"
[ "${found}" = "${expected}" ] || {
    echo "FATAL: staged shell fonts differ from the v1 Latin-only set" >&2
    echo "expected:" >&2
    printf '%s\n' "${expected}" >&2
    echo "staged:" >&2
    printf '%s\n' "${found}" >&2
    exit 1
}

while IFS= read -r face; do
    install -D -m 0644 "${staged}/${face}" "${rootfs}/usr/share/fonts/pocketforge/${face}"
done <<< "${found}"

echo "[customize] pf-shell fonts installed to /usr/share/fonts/pocketforge (v1 Latin-only set)"
