#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/app-root-mksquashfs-epoch.XXXXXX")"
cleanup() {
    find "${scratch}" -mindepth 1 -delete
    rmdir "${scratch}"
}
trap cleanup EXIT INT TERM

extract_invocation() {
    python3 - "$1" <<'PY'
from pathlib import Path
import re
import sys

lines = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
for index, line in enumerate(lines):
    if re.match(r"^\s*(?:env -u SOURCE_DATE_EPOCH\s+)?mksquashfs\s+", line):
        command = [line]
        while command[-1].rstrip().endswith("\\"):
            index += 1
            command.append(lines[index])
        print("\n".join(command))
        break
else:
    raise SystemExit(f"no mksquashfs invocation in {sys.argv[1]}")
PY
}

source_root="${scratch}/stage/rootfs"
mkdir -p "${source_root}/etc" "${source_root}/usr/lib"
printf 'VERSION_CODENAME=trixie\n' >"${source_root}/etc/os-release"
printf 'fixture payload\n' >"${source_root}/usr/lib/libfixture.so"
find "${source_root}" -print0 | LC_ALL=C sort -z | xargs -0 touch -h --date='@0'

baseline="${scratch}/baseline.raw"
env -u SOURCE_DATE_EPOCH mksquashfs "${source_root}" "${baseline}" \
    -noappend -all-root -no-xattrs -all-time 0 -mkfs-time 0 \
    -comp zstd -Xcompression-level 15 -processors 1 -no-progress >/dev/null

check_script() {
    local name=$1 script=$2 output=$3 invocation
    invocation="$(extract_invocation "${script}")"

    # Bind the variable names used by both production scripts, then execute
    # their source-owned command text with the same ambient epoch as pf build.
    local stage="${scratch}/stage"
    local app_root="${source_root}"
    local root_image="${output}"
    export SOURCE_DATE_EPOCH=1728000000
    if ! eval "${invocation}" >"${scratch}/${name}.out" 2>"${scratch}/${name}.err"; then
        cat "${scratch}/${name}.err" >&2
        printf 'FAIL: %s rejects the pf build SOURCE_DATE_EPOCH\n' "${name}" >&2
        return 1
    fi
    unset SOURCE_DATE_EPOCH

    cmp "${baseline}" "${output}"
    printf 'PASS: %s ignores ambient SOURCE_DATE_EPOCH and preserves root.raw bytes\n' "${name}"
}

check_script build-debian-app-root \
    "${root}/scripts/build-debian-app-root.sh" "${scratch}/stage/root.raw"
check_script build-steamlink-app-root-prototype \
    "${root}/scripts/build-steamlink-app-root-prototype.sh" "${scratch}/prototype.raw"
echo 'app-root-mksquashfs-epoch=PASS scripts=2 byte_identity=preserved'
