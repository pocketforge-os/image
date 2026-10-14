#!/bin/sh
# Expose gamescope's closure-pinned wayland-protocols outside subprojects/.
#
# Meson forbids a parent custom target from reading files inside a nested
# subproject.  Debian trixie also resolves its 1.44 package before wlroots can
# configure the pinned 1.49 fallback.  This mirrors gamescope CI: copy the
# pinned sources outside subprojects/ and put a matching pkg-config record
# first on PKG_CONFIG_PATH before Meson configures any scope.
set -eu

if [ "$#" -ne 3 ]; then
	echo "usage: $0 SOURCE_DIR EXPOSED_DIR PKGCONFIG_DIR" >&2
	exit 2
fi

source_dir=$1
exposed_dir=$2
pkgconfig_dir=$3
sentinel=staging/cursor-shape/cursor-shape-v1.xml

if [ ! -f "$source_dir/$sentinel" ]; then
	echo "wayland-protocols pin is missing $sentinel" >&2
	exit 1
fi
if [ -e "$exposed_dir" ] || [ -e "$pkgconfig_dir" ]; then
	echo "wayland-protocols exposure destinations must not already exist" >&2
	exit 1
fi

mkdir -p "$exposed_dir" "$pkgconfig_dir"
cp -a "$source_dir/." "$exposed_dir/"
printf '%s\n' \
	"prefix=$exposed_dir" \
	'pkgdatadir=${prefix}' \
	'' \
	'Name: wayland-protocols' \
	'Description: Wayland protocols (PocketForge source-closure pin)' \
	'Version: 1.49' \
	> "$pkgconfig_dir/wayland-protocols.pc"
