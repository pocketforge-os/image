#!/usr/bin/env python3
"""Hermetic test: the A133 SD assembly's disk and FAT identities are fixed
(bd tsp-mc9m.41.984.20.1).

Two cold runner builds of identical inputs differed in the GPT (disk GUID, the
five partition GUIDs, and the header and entry-array CRCs, in both tables) and
in the boot-resource FAT (volume serial, and the POCKETFORGE label entry's
wall-clock timestamps). This test pins both:

  static   boards/tsp/genimage.cfg sets disk-uuid to fs-uuids.env DISK_UUID and
           every in-table partition's partition-uuid to uuid5(DISK_UUID, name);
           build-sd-image.sh makes boot-resource.vfat only through
           scripts/make-reproducible-vfat.sh with BOOTRES_VOLID.
  fat      (needs mkdosfs, mlabel) make-reproducible-vfat.sh twice, under two
           TZ values, gives identical bytes. The serial (boot sector and backup)
           is BOOTRES_VOLID, the boot-sector and root-directory labels read
           POCKETFORGE, and the label entry's timestamps are SOURCE_DATE_EPOCH in
           UTC. A different SOURCE_DATE_EPOCH changes them. A missing one is
           refused. Control: `mkdosfs -n` twice differs.
  gpt      (needs genimage) the real genimage.cfg over stub inputs, twice, gives
           identical bytes. Both GPT headers and entry arrays carry valid CRCs,
           DISK_UUID, and the derived partition GUIDs. Control: the same config
           with the GUID lines stripped gives two different images.

Without the tools a leg prints SKIP, or fails under --require-tools.
--container IMAGE runs the tool legs in the pinned build container
(docker run --rm --network none, unprivileged, the repository mounted read-only)
and implies --require-tools.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import uuid
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOARD = os.path.join(REPO, "boards", "tsp")
GENIMAGE_CFG = os.path.join(BOARD, "genimage.cfg")
FS_UUIDS = os.path.join(BOARD, "fs-uuids.env")
BUILD_SD = os.path.join(REPO, "scripts", "build-sd-image.sh")
TABLE_PARTITIONS = ["boot", "env", "env-redund", "boot-resource", "userdata"]
SDE = 1700000000        # 2023-11-14 22:13:20 UTC; a FAT timestamp is 2-second grained
SDE_OTHER = 1790000000
LABEL = "POCKETFORGE"

failures: list[str] = []


def check(condition: bool, label: str) -> None:
    print(f"{'ok  ' if condition else 'FAIL'} {label}")
    if not condition:
        failures.append(label)


def fs_uuids() -> dict[str, str]:
    values = {}
    with open(FS_UUIDS, encoding="utf-8") as handle:
        for line in handle:
            match = re.match(r"^([A-Z_]+)=(\S+)$", line.strip())
            if match:
                values[match.group(1)] = match.group(2)
    return values


def genimage_blocks(text: str) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    """Return (hdimage options, {partition name: options}) from a genimage config."""
    text = re.sub(r"#[^\n]*", "", text)
    hdimage = re.search(r"hdimage\s*\{([^}]*)\}", text)
    options = lambda body: dict(re.findall(r'([a-z-]+)\s*=\s*"?([^"\n]*?)"?\s*\n', body + "\n"))
    parts = {name: options(body) for name, body in re.findall(r"partition\s+([\w-]+)\s*\{([^}]*)\}", text)}
    return options(hdimage.group(1) if hdimage else ""), parts


# ---------------------------------------------------------------- static leg
def test_static() -> None:
    ids = fs_uuids()
    disk = ids.get("DISK_UUID", "")
    with open(GENIMAGE_CFG, encoding="utf-8") as handle:
        hd, parts = genimage_blocks(handle.read())
    check(hd.get("disk-uuid", "").lower() == disk.lower() != "",
          f"genimage.cfg disk-uuid is fs-uuids.env DISK_UUID ({hd.get('disk-uuid')})")
    in_table = [name for name, opt in parts.items() if opt.get("in-partition-table") != "no"]
    check(in_table == TABLE_PARTITIONS, f"in-table partitions are {TABLE_PARTITIONS} ({in_table})")
    for name in in_table:
        want = str(uuid.uuid5(uuid.UUID(disk), name)) if disk else "?"
        got = parts[name].get("partition-uuid", "").lower()
        check(got == want, f"partition {name} partition-uuid is uuid5(DISK_UUID, {name!r}) ({got or 'unset'})")
    guids = [parts[name].get("partition-uuid", "").lower() for name in in_table] + [disk.lower()]
    check(len(set(guids)) == len(guids), "disk and partition GUIDs are distinct")
    check(re.fullmatch(r"[0-9A-F]{8}", ids.get("BOOTRES_VOLID", "")) is not None,
          f"fs-uuids.env BOOTRES_VOLID is 8 hex digits ({ids.get('BOOTRES_VOLID')})")

    with open(BUILD_SD, encoding="utf-8") as handle:
        build = handle.read()
    code = "\n".join(line for line in build.splitlines() if not line.lstrip().startswith("#"))
    check(re.search(r'make-reproducible-vfat\.sh" \\\n\s+"\$\{GENIMAGE_INPUT\}/boot-resource\.vfat" 64 POCKETFORGE '
                    r'"\$\{BOOTRES_VOLID\}"', code) is not None,
          "build-sd-image.sh makes boot-resource.vfat with make-reproducible-vfat.sh and BOOTRES_VOLID")
    check(re.search(r"\b(mkdosfs|mkfs\.vfat|mkfs\.fat)\b", code) is None,
          "build-sd-image.sh runs no mkfs.fat of its own")
    check(re.search(r"^export SOURCE_DATE_EPOCH$", build, re.M) is not None,
          "build-sd-image.sh exports SOURCE_DATE_EPOCH for the FAT helper")


# ------------------------------------------------------------------ tool runner
class Tools:
    def __init__(self, container: str | None, work: str) -> None:
        self.container = container
        self.work = work

    def run(self, script: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        """Run a bash script with $SRC (repository) and $OUT (work dir)."""
        env = dict(env or {})
        if self.container:
            exports = "".join(f"export {k}={shlex.quote(v)}\n" for k, v in env.items())
            cmd = ["docker", "run", "--rm", "--network", "none", "--user", f"{os.getuid()}:{os.getgid()}",
                   "-v", f"{REPO}:/src:ro", "-v", f"{self.work}:/out", "--entrypoint", "/bin/bash",
                   self.container, "-c", f"set -euo pipefail\nSRC=/src OUT=/out\n{exports}{script}"]
            return subprocess.run(cmd, capture_output=True, text=True, check=False)
        full = dict(os.environ, SRC=REPO, OUT=self.work, **env)
        return subprocess.run(["bash", "-c", f"set -euo pipefail\n{script}"], env=full,
                              capture_output=True, text=True, check=False)

    def have(self, *names: str) -> bool:
        probe = " && ".join(f"command -v {n} >/dev/null" for n in names)
        return self.run(probe).returncode == 0


def must(result: subprocess.CompletedProcess, what: str) -> None:
    if result.returncode != 0:
        raise AssertionError(f"{what} failed rc={result.returncode}: {result.stderr.strip()[-600:]}")


def read(path: str) -> bytes:
    with open(path, "rb") as handle:
        return handle.read()


# ---------------------------------------------------------------------- FAT leg
def fat_datetime(date: int, tm: int) -> tuple[int, ...]:
    return (1980 + (date >> 9), (date >> 5) & 0xF, date & 0x1F, tm >> 11, (tm >> 5) & 0x3F, (tm & 0x1F) * 2)


def fat_facts(data: bytes) -> dict:
    bps, spc, reserved, nfats = struct.unpack_from("<HBHB", data, 11)
    fat_size, = struct.unpack_from("<I", data, 36)
    root_cluster, = struct.unpack_from("<I", data, 44)
    backup_sector, = struct.unpack_from("<H", data, 50)
    root = (reserved + nfats * fat_size + (root_cluster - 2) * spc) * bps
    labels, deleted = [], 0
    for offset in range(root, root + spc * bps, 32):
        entry = data[offset:offset + 32]
        if entry[0] == 0:
            break
        if entry[0] == 0xE5:
            deleted += 1
            continue
        if entry[11] & 0x08 and entry[11] != 0x0F:
            ctime_cs = entry[13]
            ctime, cdate, adate, _hi, wtime, wdate = struct.unpack_from("<HHHHHH", entry, 14)
            labels.append({"name": entry[:11].decode("ascii", "replace"), "ctime_cs": ctime_cs,
                           "created": fat_datetime(cdate, ctime), "written": fat_datetime(wdate, wtime),
                           "accessed": fat_datetime(adate, 0)[:3]})
    return {
        "serial": struct.unpack_from("<I", data, 0x43)[0],
        "backup_serial": struct.unpack_from("<I", data, backup_sector * bps + 0x43)[0],
        "bpb_label": data[0x47:0x52].decode("ascii", "replace"),
        "labels": labels,
        "deleted": deleted,
    }


def test_fat(tools: Tools, require: bool) -> None:
    if not tools.have("mkdosfs", "mlabel"):
        if require:
            check(False, "fat leg: mkdosfs and mlabel are available")
        else:
            print("SKIP fat leg: mkdosfs/mlabel not installed (use --container)")
        return
    volid = fs_uuids()["BOOTRES_VOLID"]
    helper = '"$SRC/scripts/make-reproducible-vfat.sh"'
    for name, tz, sde in (("a", "UTC", SDE), ("b", "Pacific/Kiritimati", SDE), ("c", "UTC", SDE_OTHER)):
        must(tools.run(f'bash {helper} "$OUT/{name}.vfat" 64 {LABEL} {volid}',
                       {"TZ": tz, "SOURCE_DATE_EPOCH": str(sde)}), f"make-reproducible-vfat {name}")
    a, b, c = (read(os.path.join(tools.work, f"{n}.vfat")) for n in "abc")
    check(a == b, "make-reproducible-vfat.sh: same SOURCE_DATE_EPOCH, two TZ values -> identical bytes")
    facts = fat_facts(a)
    want_serial = int(volid, 16)
    check(facts["serial"] == want_serial and facts["backup_serial"] == want_serial,
          f"volume serial is BOOTRES_VOLID in the boot and backup boot sectors "
          f"({facts['serial']:08X}/{facts['backup_serial']:08X})")
    check(facts["bpb_label"] == LABEL, f"boot-sector label is {LABEL} ({facts['bpb_label']!r})")
    check(len(facts["labels"]) == 1 and facts["labels"][0]["name"] == LABEL,
          f"root directory holds one {LABEL} label entry ({facts['labels']})")
    check(facts["deleted"] == 0, "root directory holds no deleted entry")
    want = time.gmtime(SDE)
    want_dt = (want.tm_year, want.tm_mon, want.tm_mday, want.tm_hour, want.tm_min, want.tm_sec - want.tm_sec % 2)
    if facts["labels"]:
        label = facts["labels"][0]
        check(label["written"] == want_dt, f"label write time is SOURCE_DATE_EPOCH UTC {want_dt} ({label['written']})")
        check(label["created"] in (want_dt, (1980, 0, 0, 0, 0, 0)),
              f"label create time is SOURCE_DATE_EPOCH UTC or unset ({label['created']})")
    other = fat_facts(c)["labels"]
    check(bool(other) and other[0]["written"] != facts["labels"][0]["written"] if facts["labels"] else False,
          "a different SOURCE_DATE_EPOCH changes the label timestamp (it is not a constant)")
    check(sum(x != y for x, y in zip(a, c)) <= 16,
          "a different SOURCE_DATE_EPOCH changes only the label entry's timestamp bytes")

    refused = tools.run(f'unset SOURCE_DATE_EPOCH; bash {helper} "$OUT/d.vfat" 64 {LABEL} {volid}')
    check(refused.returncode != 0 and "reason=source_date_epoch_missing" in refused.stderr,
          f"refuses without SOURCE_DATE_EPOCH (rc={refused.returncode})")

    # Control: the previous command is not reproducible, so the equality above is informative.
    for name in ("o1", "o2"):
        must(tools.run(f'dd if=/dev/zero of="$OUT/{name}.vfat" bs=1M count=64 status=none\n'
                       f'mkdosfs -F 32 -n {LABEL} "$OUT/{name}.vfat" >/dev/null'), f"control mkdosfs {name}")
    check(read(os.path.join(tools.work, "o1.vfat")) != read(os.path.join(tools.work, "o2.vfat")),
          "control: `mkdosfs -F 32 -n POCKETFORGE` twice gives different bytes")


# ---------------------------------------------------------------------- GPT leg
def gpt_guid(raw: bytes) -> str:
    return str(uuid.UUID(bytes_le=raw))


def gpt_table(image: bytes, header_lba: int) -> dict:
    header = image[header_lba * 512:header_lba * 512 + 512]
    (signature, _rev, size, crc, _res, current, backup, _first, _last, disk, entries_lba, count, entry_size,
     entries_crc) = struct.unpack_from("<8sIIIIQQQQ16sQIII", header)
    zeroed = header[:16] + b"\0\0\0\0" + header[20:size]
    entries = image[entries_lba * 512:entries_lba * 512 + count * entry_size]
    parts = {}
    for i in range(count):
        entry = entries[i * entry_size:(i + 1) * entry_size]
        if entry[:16] == b"\0" * 16:
            continue
        name = entry[56:128].decode("utf-16-le").rstrip("\0")
        parts[name] = gpt_guid(entry[16:32])
    return {
        "signature": signature, "current": current, "backup": backup, "disk": gpt_guid(disk),
        "header_crc_ok": zlib.crc32(zeroed) & 0xFFFFFFFF == crc,
        "entries_crc_ok": zlib.crc32(entries) & 0xFFFFFFFF == entries_crc,
        "parts": parts, "entries": entries,
    }


GENIMAGE_RUN = r'''
mkdir -p "$OUT/in"
head -c 65536 /dev/zero > "$OUT/in/boot0.img"
head -c 65536 /dev/zero > "$OUT/in/boot_package.fex"
head -c 1048576 /dev/zero > "$OUT/in/boot.img"
head -c 131072 /dev/zero > "$OUT/in/env.img"
head -c 1048576 /dev/zero > "$OUT/in/boot-resource.vfat"
head -c 1048576 /dev/zero > "$OUT/in/userdata.ext4"
run() {  # <config> <name>
    rm -rf "$OUT/tmp" "$OUT/root" "$OUT/res"; mkdir -p "$OUT/tmp" "$OUT/root" "$OUT/res"
    genimage --config "$1" --inputpath "$OUT/in" --outputpath "$OUT/res" \
        --rootpath "$OUT/root" --tmppath "$OUT/tmp" > "$OUT/$2.log" 2>&1
    mv "$OUT/res/pocketforge-tsp.img" "$OUT/$2.img"
}
run "$SRC/boards/tsp/genimage.cfg" g1
run "$SRC/boards/tsp/genimage.cfg" g2
grep -v -E '^[[:space:]]*(disk-uuid|partition-uuid)[[:space:]]*=' "$SRC/boards/tsp/genimage.cfg" > "$OUT/unpinned.cfg"
run "$OUT/unpinned.cfg" u1
run "$OUT/unpinned.cfg" u2
'''


def test_gpt(tools: Tools, require: bool) -> None:
    if not tools.have("genimage"):
        if require:
            check(False, "gpt leg: genimage is available")
        else:
            print("SKIP gpt leg: genimage not installed (use --container)")
        return
    must(tools.run(GENIMAGE_RUN), "genimage")
    g1, g2, u1, u2 = (read(os.path.join(tools.work, f"{n}.img")) for n in ("g1", "g2", "u1", "u2"))
    check(g1 == g2, f"genimage with boards/tsp/genimage.cfg twice -> identical bytes ({len(g1)} B)")
    check(u1 != u2, "control: the same config without the GUID lines gives two different images")
    disk = fs_uuids()["DISK_UUID"].lower()
    want = {name: str(uuid.uuid5(uuid.UUID(disk), name)) for name in TABLE_PARTITIONS}
    primary = gpt_table(g1, 1)
    backup = gpt_table(g1, primary["backup"])
    for label, table in (("primary", primary), ("backup", backup)):
        check(table["signature"] == b"EFI PART", f"{label} GPT header signature")
        check(table["header_crc_ok"] and table["entries_crc_ok"], f"{label} GPT header and entry-array CRCs are valid")
        check(table["disk"] == disk, f"{label} GPT disk GUID is DISK_UUID ({table['disk']})")
        check(table["parts"] == want, f"{label} GPT partition GUIDs are uuid5(DISK_UUID, name) ({table['parts']})")
    check(primary["entries"] == backup["entries"], "primary and backup entry arrays are identical")
    diff = [i for i, (x, y) in enumerate(zip(u1, u2)) if x != y]
    print(f"     control diff: {len(diff)} bytes differ between the unpinned images")


def main() -> int:
    ap = argparse.ArgumentParser(description="A133 SD assembly reproducibility (bd tsp-mc9m.41.984.20.1)")
    ap.add_argument("--container", help="pinned build image to run the tool legs in")
    ap.add_argument("--require-tools", action="store_true", help="fail, not skip, a leg whose tools are missing")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    args = ap.parse_args()
    require = args.require_tools or bool(args.container)
    work = tempfile.mkdtemp(prefix="repro-assembly-")
    os.chmod(work, 0o755)
    try:
        test_static()
        tools = Tools(args.container, work)
        test_fat(tools, require)
        test_gpt(tools, require)
    finally:
        if args.keep:
            print(f"work directory: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)
    if failures:
        print(f"reproducible assembly: FAIL ({len(failures)} failed)")
        return 1
    print("reproducible assembly: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
