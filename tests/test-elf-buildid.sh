#!/usr/bin/env bash
# Hermetic test for the ELF build-id gate, the image build-id manifest and the
# debuginfo split (cr-symbols; bd tsp-ihne1.33).
#
# No docker, no network, no live device state. Fixture ELFs are compiled with
# the runner's own cc; ELF note/DWARF inspection uses readelf/objcopy.
# Positive and negative controls run in the same invocation.
#
# Usage: tests/test-elf-buildid.sh
# Exit status: 0 PASS, 1 FAIL, 75 BLOCKED.
set -euo pipefail

for tool in cc objcopy readelf python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "BLOCKED: $tool not found on PATH" >&2
        exit 75
    fi
done

root="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
elfbuildid="$root/scripts/pf-elf-buildid.py"
finalize="$root/scripts/finalize-elf-debuginfo.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/pf-elf-buildid.XXXXXX")"
cleanup() { [ ! -e "$work" ] || { find "$work" -mindepth 1 -delete; rmdir "$work"; }; }
trap cleanup EXIT

fixtures="$work/root"
mkdir -p "$fixtures/usr/bin" "$fixtures/usr/lib/pvr-rogue" "$fixtures/lib/modules/6.6.0/test"
out="$work/out"
store="$out/pf-debuginfo"
mkdir -p "$out"

# --- fixtures ---
cat >"$work/good.c" <<'EOF'
int main(int argc, char **argv) { return argc > 0 ? 7 : 0; }
EOF
cat >"$work/plain.c" <<'EOF'
void plain(void) { volatile int x = 1; (void)x; }
EOF

# positive: default link flags carry a GNU build-id (modern gcc/ld on the runner).
cc -o "$fixtures/usr/bin/pf-app-good" "$work/good.c"
# negative control #1: the linker explicitly refused a build-id.
cc -Wl,--build-id=none -o "$work/nobuildid" "$work/good.c"
# negative control #2: a binary whose build-id note was removed AFTER linking.
cc -o "$work/stripped-id" "$work/good.c"
objcopy --remove-section=.note.gnu.build-id "$work/stripped-id"
# a kernel-module-shaped ELF (ET_REL like a .ko) with a build-id: modules are
# linked relocatable, so the id comes from the ld -r step, not cc.
cc -c -o "$work/plain.o" "$work/plain.c"
ld -r --build-id=sha1 -o "$fixtures/lib/modules/6.6.0/test/pf-test.ko" "$work/plain.o"
# a DWARF-carrying ELF for the split step.
cc -g -o "$fixtures/usr/bin/pf-app-debug" "$work/good.c"
# a closed-vendor-shaped ELF with NO build-id (models vendored blobs).
cc -shared -fPIC -Wl,--build-id=none -o "$fixtures/usr/lib/pvr-rogue/libpvr.so.1" "$work/plain.c"
# a closed-vendor-shaped ELF that DOES have a build-id (never split, never named).
cc -shared -fPIC -o "$fixtures/usr/lib/pvr-rogue/libegl.so" "$work/plain.c"
# a non-ELF decoy next to real binaries.
printf 'not an elf, obviously\n' > "$fixtures/usr/bin/readme.txt"

# --- 1. check: positive (build-id present everywhere outside closed paths) ---
python3 "$elfbuildid" check "$fixtures" --closed-paths \
    "$fixtures/usr/lib/pvr-rogue" >"$work/check-ok.log"
grep -F 'checked=' "$work/check-ok.log" >/dev/null
echo "PASS check: build-id ELFs outside closed paths accepted"

# --- 2. check: negative control 1 — the linker refused a build-id ---
mkdir -p "$work/badroot1/usr/bin"
cp "$work/nobuildid" "$work/badroot1/usr/bin/pf-bad"
if python3 "$elfbuildid" check "$work/badroot1" >"$work/check-bad1.log" 2>&1; then
    echo "FAIL: link-without-build-id ELF was accepted" >&2
    exit 1
fi
grep -F 'no GNU build-id' "$work/check-bad1.log" >/dev/null
grep -F '/usr/bin/pf-bad' "$work/check-bad1.log" >/dev/null
echo "PASS check: link-without-build-id ELF rejected with the file path"

# --- 3. check: negative control 2 — the note was removed after linking ---
mkdir -p "$work/badroot2/usr/bin"
cp "$work/stripped-id" "$work/badroot2/usr/bin/pf-stripped"
if python3 "$elfbuildid" check "$work/badroot2" >"$work/check-bad2.log" 2>&1; then
    echo "FAIL: stripped-of-build-id ELF was accepted" >&2
    exit 1
fi
grep -F 'no GNU build-id' "$work/check-bad2.log" >/dev/null
grep -F '/usr/bin/pf-stripped' "$work/check-bad2.log" >/dev/null
echo "PASS check: stripped-of-build-id ELF rejected (acceptance negative test)"

# --- 4. check: the closed-path exemption never leaks outside the listed dir ---
# The SAME no-build-id ELF passes under /usr/lib/pvr-rogue (positive, covered by
# step 1's fixtures) but must fail the gate anywhere else.
cp "$work/nobuildid" "$fixtures/usr/bin/would-be-closed"
if python3 "$elfbuildid" check "$fixtures" --closed-paths \
        "$fixtures/usr/lib/pvr-rogue" >"$work/check-4.log" 2>&1; then
    echo "FAIL: closed-path exemption leaked to an ELF outside the closed dirs" >&2
    exit 1
fi
grep -F '/usr/bin/would-be-closed' "$work/check-4.log" >/dev/null
echo "PASS check: closed-path exemption scoped to the listed dir, no leakage"

# --- 5. check: fail-closed on an empty tree (wrong-root guard) ---
mkdir -p "$work/emptyroot"
if python3 "$elfbuildid" check "$work/emptyroot" >"$work/check-5.log" 2>&1; then
    echo "FAIL: empty root accepted (must fail closed)" >&2
    exit 1
fi
echo "PASS check: empty root fails closed"

# --- 6. manifest: exact content, sorted, closed paths omitted ---
# The planted negative-control ELF would make the manifest fail the gate;
# it already proved its point in step 4, so drop it from the fixture tree.
rm -f "$fixtures/usr/bin/would-be-closed"
python3 "$elfbuildid" manifest "$fixtures" --closed-paths "$fixtures/usr/lib/pvr-rogue" \
    >"$work/manifest.tsv"
head -1 "$work/manifest.tsv" | grep -F 'pocketforge elf build-id manifest v1' >/dev/null
if grep -F 'pvr-rogue' "$work/manifest.tsv" | grep -v '^#' >/dev/null; then
    echo "FAIL: closed-path ELF leaked into the manifest" >&2
    exit 1
fi
if grep -F '/usr/bin/readme.txt' "$work/manifest.tsv" >/dev/null; then
    echo "FAIL: non-ELF file leaked into the manifest" >&2
    exit 1
fi
grep -P '^[0-9a-f]{40}\t/usr/bin/pf-app-good$' "$work/manifest.tsv" >/dev/null
grep -P '^[0-9a-f]{40}\t/lib/modules/6\.6\.0/test/pf-test\.ko$' "$work/manifest.tsv" >/dev/null
rows=$(grep -cv '^#' "$work/manifest.tsv")
[ "$rows" -ge 3 ] || { echo "FAIL: manifest row count $rows too low" >&2; exit 1; }
# manifest build-ids must agree with readelf's own answer
readelf -n "$fixtures/usr/bin/pf-app-good" 2>/dev/null \
    | awk '/Build ID/ {gsub("^[ \t]+",""); print $NF}' >"$work/good.buildid"
good_id=$(cat "$work/good.buildid")
grep -P "^${good_id}\t" "$work/manifest.tsv" >/dev/null \
    || { echo "FAIL: manifest build-id disagrees with readelf ($good_id)" >&2; exit 1; }
# determinism: the manifest is a pure function of the imported tree
python3 "$elfbuildid" manifest "$fixtures" --closed-paths "$fixtures/usr/lib/pvr-rogue" \
    >"$work/manifest-2.tsv"
cmp "$work/manifest.tsv" "$work/manifest-2.tsv" >/dev/null \
    || { echo "FAIL: manifest is not deterministic" >&2; exit 1; }
echo "PASS manifest: exact sorted rows, closed paths omitted, deterministic"

# --- 7. split: DWARF-carrying ELF -> buildid/<aa>/<rest>/debuginfo; shipped binary stripped, id kept ---
# Split consumes (strips) the tree, so work on pristine copies of the fixtures.
cp -a "$fixtures" "$work/root-split"
cp -a "$fixtures" "$work/root-split-2"
python3 "$elfbuildid" split "$work/root-split" "$store" --closed-paths "$work/root-split/usr/lib/pvr-rogue" \
    >"$work/split.log"
debug_row=$(grep -P '\t/usr/bin/pf-app-debug$' "$work/manifest.tsv" | head -1)
split_id=${debug_row%%$'\t'*}
split_aa=${split_id:0:2}; split_rest=${split_id:2}
[ -f "$store/buildid/$split_aa/$split_rest/debuginfo" ] \
    || { echo "FAIL: split debuginfo missing at canonical store path for $split_id" >&2; exit 1; }
if ! readelf -S "$store/buildid/$split_aa/$split_rest/debuginfo" 2>/dev/null \
        | grep -Fq '.debug_info'; then
    echo "FAIL: debuginfo store file carries no DWARF" >&2
    exit 1
fi
# the shipped binary keeps its build-id but loses DWARF
if ! readelf -n "$work/root-split/usr/bin/pf-app-debug" | grep -Fq 'Build ID'; then
    echo "FAIL: shipped binary lost its build-id during split" >&2
    exit 1
fi
if readelf -S "$work/root-split/usr/bin/pf-app-debug" 2>/dev/null | grep -Fq '.debug_info'; then
    echo "FAIL: shipped binary still carries DWARF after split" >&2
    exit 1
fi
# negative control: a non-DWARF ELF gets NO store entry and is left intact
good_row=$(grep -P '\t/usr/bin/pf-app-good$' "$work/manifest.tsv" | head -1)
good_split_id=${good_row%%$'\t'*}
[ ! -e "$store/buildid/${good_split_id:0:2}/${good_split_id:2}/debuginfo" ] \
    || { echo "FAIL: non-DWARF ELF wrongly got a store entry" >&2; exit 1; }
if ! readelf -n "$work/root-split/usr/bin/pf-app-good" | grep -Fq 'Build ID'; then
    echo "FAIL: untouched ELF lost its build-id" >&2
    exit 1
fi
# determinism of the store itself
python3 "$elfbuildid" split "$work/root-split-2" "$out/pf-debuginfo-2" \
    --closed-paths "$work/root-split-2/usr/lib/pvr-rogue" >"$work/split-2.log"
cmp "$store/buildid/$split_aa/$split_rest/debuginfo" \
    "$out/pf-debuginfo-2/buildid/$split_aa/$split_rest/debuginfo" >/dev/null \
    || { echo "FAIL: split debuginfo is not deterministic" >&2; exit 1; }
echo "PASS split: canonical store layout, shipped stripped, build-id kept, deterministic"

# --- 8. wrapper: finalize emits the on-device manifest and the build artifacts ---
# The wrapper hard-fails on a tree containing a build-id-less ELF outside
# closed paths: the planted one was removed above, so fixtures are clean.
"$finalize" "$fixtures" "$out" >"$work/finalize.log"
[ -f "$fixtures/usr/share/pocketforge/elf-build-id-manifest.tsv" ] \
    || { echo "FAIL: on-device manifest not installed into rootfs" >&2; exit 1; }
[ -f "$fixtures/usr/share/pocketforge/elf-build-id-manifest.tsv.sha256" ] \
    || { echo "FAIL: on-device manifest sha256 companion missing" >&2; exit 1; }
( cd "$fixtures/usr/share/pocketforge" && sha256sum -c --strict --quiet elf-build-id-manifest.tsv.sha256 )
[ -f "$out/pf-elf-build-id-manifest.tsv" ] \
    || { echo "FAIL: build manifest not emitted to OUT_DIR" >&2; exit 1; }
[ -d "$out/pf-debuginfo/buildid" ] \
    || { echo "FAIL: debuginfo store not emitted to OUT_DIR" >&2; exit 1; }
# negative control: wrapper refuses a build-id-less ELF outside closed paths
mkdir -p "$work/badroot3/usr/bin"
cp "$work/stripped-id" "$work/badroot3/usr/bin/pf-bad3"
if "$finalize" "$work/badroot3" "$work/bad-out3" >"$work/finalize-bad.log" 2>&1; then
    echo "FAIL: finalize accepted a build-id-less ELF" >&2
    exit 1
fi
grep -E 'FAIL|FATAL|no GNU build-id' "$work/finalize-bad.log" >/dev/null
grep -F '/usr/bin/pf-bad3' "$work/finalize-bad.log" >/dev/null
echo "PASS finalize: on-device manifest + artifacts emitted; gates a bad ELF (build acceptance test)"

# --- 9. empty-store positive control: a rootfs with NO DWARF-bearing owned
# ELF (the a523 matrix row) must still finalize: empty store, manifest intact.
mkdir -p "$work/nodwarf/usr/bin"
cc -o "$work/nodwarf/usr/bin/pf-stripped-app" "$work/good.c"
objcopy --strip-debug "$work/nodwarf/usr/bin/pf-stripped-app"
mkdir -p "$work/nodwarf-out"
"$finalize" "$work/nodwarf" "$work/nodwarf-out" >"$work/nodwarf.log"
[ -f "$work/nodwarf-out/pf-elf-build-id-manifest.tsv" ] \
    || { echo "FAIL: manifest missing for the DWARF-free tree" >&2; exit 1; }
[ -d "$work/nodwarf-out/pf-debuginfo/buildid" ] \
    || { echo "FAIL: store dir missing for the DWARF-free tree" >&2; exit 1; }
find "$work/nodwarf-out/pf-debuginfo" -type f | grep -q . \
    && { echo "FAIL: DWARF-free tree produced store entries" >&2; exit 1; }
echo "PASS finalize: DWARF-free rootfs (a523 row) finalizes with an empty store"

echo "test-elf-buildid=ALL PASS"