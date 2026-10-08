#!/bin/sh
# Fail closed unless GLES 3.2 candidate state is absent from release roots and
# exactly application-scoped in the CTS dev profile.
set -eu

die() {
    printf 'gles32-candidate-profile=FAIL %s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 3 ] || die 'reason=usage expected=rootfs,variant,device'
rootfs=$1
variant=$2
device=$3
policy_name=99-pocketforge-gles32-candidate.conf
policy_path="$rootfs/usr/share/drirc.d/$policy_name"
mesa_route="$rootfs/usr/local/share/drirc.d/$policy_name"

if [ ! -d "$rootfs" ] || [ -L "$rootfs" ]; then
    die 'reason=rootfs_invalid'
fi
case "$variant" in
    dev|release) ;;
    *) die 'reason=variant_invalid' ;;
esac
[ -n "$device" ] || die 'reason=device_missing'

global_override=$(
    find "$rootfs" -xdev -type f -exec \
        grep -IlE '(^|[^[:alnum:]_])(PVR_DEBUG[[:space:]]*=.*pf_texcomp|ZINK_DEBUG[[:space:]]*=.*tbo_rgb32|MESA_GLES_VERSION_OVERRIDE[[:space:]]*=|MESA_DRICONF_EXECUTABLE_OVERRIDE[[:space:]]*=|DRIRC_CONFIGDIR[[:space:]]*=)' \
        {} + 2>/dev/null | sed -n '1p' || :
)
[ -z "$global_override" ] \
    || die "global GLES candidate override is forbidden in the rootfs: ${global_override#"$rootfs"}"

unexpected_assignment=$(
    find "$rootfs" -xdev -type f ! -path "$policy_path" -exec \
        grep -IlF 'pvr_enable_gles32_candidate' {} + 2>/dev/null | sed -n '1p' || :
)
[ -z "$unexpected_assignment" ] \
    || die "candidate assignment is forbidden outside the canonical policy: ${unexpected_assignment#"$rootfs"}"

if [ "$variant:$device" != dev:a133-open-7x-gpu-cts ]; then
    if [ -e "$policy_path" ] || [ -L "$policy_path" ] || \
       [ -e "$mesa_route" ] || [ -L "$mesa_route" ]; then
        die "candidate policy is forbidden outside the CTS dev profile: /usr/share/drirc.d/$policy_name"
    fi
    printf '%s\n' \
        "gles32-candidate-profile=PASS mode=off variant=$variant device=$device candidate_assignments=0 global_overrides=0"
    exit 0
fi

if [ ! -f "$policy_path" ] || [ -L "$policy_path" ]; then
    die "CTS candidate policy is missing or not regular: /usr/share/drirc.d/$policy_name"
fi
[ -L "$mesa_route" ] \
    || die "CTS candidate Mesa search route is missing or not a symlink: /usr/local/share/drirc.d/$policy_name"
[ "$(readlink "$mesa_route")" = "../../../share/drirc.d/$policy_name" ] \
    || die "CTS candidate Mesa search route target is invalid: $(readlink "$mesa_route")"

regular_count=$(find "$rootfs" -xdev -type f -name "$policy_name" -print | wc -l)
[ "$regular_count" -eq 1 ] \
    || die "expected exactly one regular CTS candidate policy, found $regular_count"
route_count=$(find "$rootfs" -xdev -type l -name "$policy_name" -print | wc -l)
[ "$route_count" -eq 1 ] \
    || die "expected exactly one Mesa search route, found $route_count"

if ! python3 - "$policy_path" <<'PY'
import sys
import xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    root = ET.parse(path).getroot()
except (ET.ParseError, OSError) as error:
    print(f"gles32-candidate-profile=FAIL candidate policy XML is invalid: {error}", file=sys.stderr)
    raise SystemExit(1)

expected_executables = ["deqp-gles3", "deqp-gles31", "glcts"]
if root.tag != "driconf" or root.attrib or len(root) != 1:
    print("gles32-candidate-profile=FAIL candidate policy root/device shape is not canonical", file=sys.stderr)
    raise SystemExit(1)
device = root[0]
if device.tag != "device" or device.attrib:
    print("gles32-candidate-profile=FAIL candidate policy device must be driver-neutral", file=sys.stderr)
    raise SystemExit(1)
actual_executables = []
for application in device:
    if application.tag != "application" or application.attrib.get("name") != "PocketForge GLES 3.2 qualification" or set(application.attrib) != {"name", "executable"}:
        print("gles32-candidate-profile=FAIL candidate policy application is not canonical", file=sys.stderr)
        raise SystemExit(1)
    actual_executables.append(application.attrib["executable"])
    options = list(application)
    if len(options) != 1 or options[0].tag != "option" or options[0].attrib != {
        "name": "pvr_enable_gles32_candidate",
        "value": "true",
    }:
        print("gles32-candidate-profile=FAIL candidate policy option is not canonical", file=sys.stderr)
        raise SystemExit(1)
if actual_executables != expected_executables:
    print("gles32-candidate-profile=FAIL candidate policy applications do not match the exact CTS allowlist", file=sys.stderr)
    raise SystemExit(1)
PY
then
    exit 1
fi

for executable in deqp-gles3 deqp-gles31 glcts; do
    binary="$rootfs/opt/pocketforge/cts/bin/$executable"
    if [ ! -f "$binary" ] || [ -L "$binary" ] || [ ! -x "$binary" ]; then
        die "allowlisted CTS executable is missing, symlinked, or not executable: /opt/pocketforge/cts/bin/$executable"
    fi
done

printf '%s\n' \
    "gles32-candidate-profile=PASS mode=cts variant=$variant device=$device policy=/usr/share/drirc.d/$policy_name executables=deqp-gles3,deqp-gles31,glcts mesa_route=/usr/local/share/drirc.d/$policy_name global_overrides=0"
