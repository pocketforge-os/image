#!/usr/bin/env bash
set -euo pipefail

producer="${1:?usage: install-cursor-theme.sh PRODUCER ROOTFS}"
rootfs="${2:?usage: install-cursor-theme.sh PRODUCER ROOTFS}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python3 -B "${script_dir}/verify-cursor-theme.py" "${producer}"
for theme in pocketforge-light pocketforge-dark; do
    destination="${rootfs}/usr/share/icons/${theme}"
    [ ! -e "${destination}" ] && [ ! -L "${destination}" ] \
        || { echo "cursor-theme install: collision at ${destination}" >&2; exit 1; }
    mkdir -p "${destination%/*}"
    cp -a --no-preserve=ownership "${producer}/usr/share/icons/${theme}" "${destination}"
done

license_dst="${rootfs}/usr/share/licenses/pocketforge-cursor-theme"
[ ! -e "${license_dst}" ] && [ ! -L "${license_dst}" ] \
    || { echo "cursor-theme install: collision at ${license_dst}" >&2; exit 1; }
mkdir -p "${license_dst%/*}"
cp -a --no-preserve=ownership "${producer}/usr/share/licenses/pocketforge-cursor-theme" "${license_dst}"
mkdir -p "${rootfs}/usr/share/pocketforge"
cp -a --no-preserve=ownership "${producer}/usr/share/pocketforge/cursor-theme.provenance" \
    "${rootfs}/usr/share/pocketforge/cursor-theme.provenance"

mkdir -p "${rootfs}/etc"
touch "${rootfs}/etc/environment"
for setting in XCURSOR_THEME=pocketforge-light XCURSOR_SIZE=48; do
    if ! grep -Fqx "${setting}" "${rootfs}/etc/environment"; then
        printf '%s\n' "${setting}" >> "${rootfs}/etc/environment"
    fi
done
python3 -B "${script_dir}/verify-cursor-theme.py" "${rootfs}" --require-env --require-root-ownership
