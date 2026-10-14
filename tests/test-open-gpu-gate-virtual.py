#!/usr/bin/env python3
"""Strict virtual-GPU branch of the open-GPU gate (tsp-mc9m.41.984.54.18).

The real production gate script runs in an unprivileged bwrap view over a
fixture rootfs; nothing on the host is modified and no container is built.
The fixture root carries a fake sysfs (renderD128 -> driver symlink), a fake
probe (a shell script with canned per-mode outputs), a fake Venus ICD
manifest and, for the physical controls, the powervr firmware + provenance.

Cases:
  v1  virtio_gpu node + venus probe + zink GLES probe -> PASS branch=virtual,
      labelled virtual, and the receipt never claims GE8300 conformance
  v2  guest lavapipe driver (driver=lavapipe) -> rejected
  v3  non-virtio render node (vgem) -> falls through to the physical branch
      and fails there; a generic node is never accepted as virtual
  v4  probe fails the venus capset/readback (exit != 0) -> rejected
  v5  capset=virgl (non-venus capset) -> rejected
  v6  no virtio ICD manifest in /usr/share/vulkan/icd.d -> rejected
  v7  GLES renderer is llvmpipe, not zink -> rejected
  v8  GLES probe fails -> rejected
  p1  physical fixture: the gate at BASE_REF and the working-tree gate run
      byte-identical (rc, stdout, stderr) and PASS with km=/firmware_sha256=
  p2  physical firmware-sha mismatch: byte-identical failure
  p3  physical probe failure: byte-identical failure

Exit status: 0 PASS, 1 FAIL, 75 BLOCKED (no bwrap / no git history).
"""

import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

BLOCKED = 75
# origin/main when the virtual branch was written; the physical-branch
# byte-identity controls diff against this exact gate text.
BASE_REF = "7aeddf9cfb6da435da0685aebe8e53a3f7bb4c10"
GATE_REL = "rootfs-overlay/usr/lib/pocketforge/open-gpu-gate.sh"
FW_REL = "lib/firmware/powervr/rogue_22.102.54.38_v1.fw"
FW_BYTES = b"fixture-firmware\n"
FW_SHA = "9cf55c6822bcb041ebdfa2117f826ab449425b33ffe0231b42330780da7dea30"

PROBE_SCRIPT = """#!/bin/sh
mode=$(cat /usr/lib/pocketforge/fake-probe-mode 2>/dev/null || echo none)
case "$1" in
    --venus-readback)
        case "$mode" in
            venus-ok|gles-software|gles-fail)
                echo 'renderer=lavapipe (LLVM 15.0.7) driver=venus/1 submit=ok capset=venus readback=0x5046564e'
                exit 0 ;;
            lavapipe)
                echo 'renderer=lavapipe (LLVM 15.0.7) driver=lavapipe/1 submit=ok capset=venus readback=0x5046564e'
                exit 0 ;;
            capset-fail)
                echo 'open-gpu-probe: venus capset absent' >&2
                exit 1 ;;
            malformed)
                echo 'renderer=lavapipe driver=venus/1 submit=ok capset=virgl readback=0x5046564e'
                exit 0 ;;
        esac ;;
    --gles32-zink-readback)
        case "$mode" in
            venus-ok)
                echo 'gles_version=3.2 renderer=zink (Venus/lavapipe) draw=readback-ok label=virtual'
                exit 0 ;;
            gles-fail)
                echo 'open-gpu-probe: GLES 3.2 context unavailable' >&2
                exit 1 ;;
            gles-software)
                echo 'gles_version=3.2 renderer=llvmpipe (LLVM 15.0.7) draw=readback-ok label=virtual'
                exit 0 ;;
        esac ;;
    "")
        case "$mode" in
            phys-ok)
                echo 'renderer=PowerVR GE8300 driver=PowerVR/6938624 submit=ok'
                exit 0 ;;
            phys-fail)
                echo 'open-gpu-probe: vkQueueSubmit failed (VkResult=-4)' >&2
                exit 1 ;;
        esac ;;
esac
exit 9
"""


class Blocked(Exception):
    pass


class Failed(Exception):
    pass


def check(cond: bool, message: str) -> None:
    if not cond:
        raise Failed(message)


def bwrap() -> str:
    b = shutil.which("bwrap")
    if not b:
        raise Blocked("bwrap not installed")
    return b


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def base_gate_text() -> str:
    root = repo_root()
    r = subprocess.run(["git", "-C", str(root), "show", f"{BASE_REF}:{GATE_REL}"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise Blocked(f"git show {BASE_REF}:{GATE_REL}: {r.stderr.strip()}")
    return r.stdout


def build_root(work: Path, *, gate_text: str, node_driver: str | None,
               powervr_module: bool, icd: bool, firmware: bool,
               provenance_sha: str | None, probe_mode: str) -> Path:
    """A fixture rootfs skeleton: fake /sys, /dev/dri, /usr/lib/pocketforge,
    /usr/share/vulkan/icd.d and the powervr firmware + provenance files."""
    root = work / "root"
    for rel in ("dev/dri", "proc", "sys/class/drm", "usr/bin", "usr/lib",
                "usr/lib/pocketforge", "usr/share/vulkan/icd.d"):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).mkdir(parents=True, exist_ok=True)
    os.symlink("usr/bin", root / "bin")

    if node_driver is not None:
        driver_dir = root / f"sys/bus/drivers/{node_driver}"
        driver_dir.mkdir(parents=True)
        device = root / "sys/class/drm/renderD128/device"
        device.mkdir(parents=True)
        os.symlink(f"../../../../bus/drivers/{node_driver}", device / "driver")
        (root / "dev/dri/renderD128").write_text("")
    if powervr_module:
        (root / "sys/module/powervr").mkdir(parents=True)
    if firmware:
        fw = root / FW_REL
        fw.parent.mkdir(parents=True, exist_ok=True)
        fw.write_bytes(FW_BYTES)
    if provenance_sha is not None:
        (root / "usr/lib/pocketforge/gpu-fw-provenance").write_text(
            f"powervr firmware sha256={provenance_sha}\n")
    if icd:
        (root / "usr/share/vulkan/icd.d/virtio_icd.aarch64.json").write_text("{}\n")

    (root / "usr/lib/pocketforge/open-gpu-gate.sh").write_text(gate_text)
    (root / "usr/lib/pocketforge/open-gpu-gate.sh").chmod(0o755)
    (root / "usr/lib/pocketforge/open-gpu-probe").write_text(PROBE_SCRIPT)
    (root / "usr/lib/pocketforge/open-gpu-probe").chmod(0o755)
    (root / "usr/lib/pocketforge/fake-probe-mode").write_text(probe_mode + "\n")
    return root


def host_lib_dirs() -> list[tuple[str, str]]:
    """(host source, fixture destination) binds for the dynamic loader's view:
    the multiarch lib dir under both /lib and /usr/lib, plus /lib64 when the
    host has one (the ELF interpreter)."""
    binds: list[tuple[str, str]] = []
    triplet = {
        "x86_64": "x86_64-linux-gnu",
        "aarch64": "aarch64-linux-gnu",
        "armv7l": "arm-linux-gnueabihf",
    }.get(platform.machine())
    if triplet is None or not Path(f"/usr/lib/{triplet}").is_dir():
        raise Blocked(f"host has no /usr/lib multiarch dir for {platform.machine()}")
    binds.append((f"/usr/lib/{triplet}", f"/lib/{triplet}"))
    binds.append((f"/usr/lib/{triplet}", f"/usr/lib/{triplet}"))
    if Path("/lib64").exists():
        binds.append((os.path.realpath("/lib64"), "/lib64"))
    return binds


def run_gate(root: Path) -> tuple[int, str, str]:
    argv = [bwrap(), "--bind", str(root), "/",
            "--ro-bind", "/usr/bin", "/usr/bin"]
    for src, dst in host_lib_dirs():
        argv += ["--ro-bind", src, dst]
    argv += ["--proc", "/proc", "--dev-bind", "/dev/null", "/dev/null"]
    argv += ["--setenv", "PATH", "/usr/bin:/bin",
             "/bin/sh", "/usr/lib/pocketforge/open-gpu-gate.sh"]
    r = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout, r.stderr


def scenario(work: Path, name: str, gate_text: str, **kw) -> tuple[int, str, str]:
    root = build_root(work / name, **({"gate_text": gate_text} | kw))
    return run_gate(root)


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] != "--work":
        print(f"usage: {sys.argv[0]} --work DIR", file=sys.stderr)
        return 2
    work = Path(sys.argv[2])
    failed = blocked = False
    notes: list[str] = []

    try:
        bw = bwrap()
    except Blocked as e:
        print(f"open-gpu-gate-virtual: BLOCKED: {e}")
        return BLOCKED
    del bw

    new_gate = (repo_root() / GATE_REL).read_text()
    try:
        old_gate = base_gate_text()
    except Blocked as e:
        print(f"open-gpu-gate-virtual: BLOCKED: {e}")
        return BLOCKED

    virtio = dict(node_driver="virtio_gpu", powervr_module=False, icd=True,
                  firmware=False, provenance_sha=None)

    def case(name: str, **kw) -> tuple[int, str, str]:
        try:
            r = scenario(work, name, new_gate, **kw)
            notes.append(f"{name}: rc={r[0]}")
            return r
        except Failed:
            raise

    try:
        # v1: the strict virtual success path.
        rc, out, err = case("v1-virtual-pass", probe_mode="venus-ok", **virtio)
        check(rc == 0, f"v1: rc={rc} stderr={err.strip()!r}, expected 0")
        check("PF-OPEN-GPU PASS: branch=virtual backend=virtio_gpu+venus" in out,
              f"v1: stdout lacks the virtual receipt: {out.strip()!r}")
        check("label=virtual" in out, f"v1: virtual result not labelled: {out!r}")
        check("GE8300" not in out and "GE8300" not in err,
              f"v1: virtual branch claims GE8300: {out!r} {err!r}")
        check("km=" not in out, f"v1: virtual receipt carries physical km= field: {out!r}")
        check("driver=venus/" in out and "capset=venus" in out,
              f"v1: venus probe result not echoed: {out!r}")
        check("gles_version=3.2" in out and "renderer=zink" in out,
              f"v1: zink GLES result not echoed: {out!r}")

        # v2: a direct guest lavapipe ICD is never the virtual success path.
        rc, out, err = case("v2-lavapipe-rejected", probe_mode="lavapipe", **virtio)
        check(rc == 1 and "PASS" not in out, f"v2: rc={rc} stdout={out!r}, expected rejection")
        check("driver=venus" in err, f"v2: failure does not name the venus requirement: {err.strip()!r}")

        # v3: a non-virtio render node (vgem) falls through to the physical
        # branch and fails there; it is never accepted as virtual.
        rc, out, err = case("v3-vgem-not-virtual", probe_mode="venus-ok",
                            node_driver="vgem", powervr_module=False, icd=True,
                            firmware=False, provenance_sha=None)
        check(rc == 1 and "branch=virtual" not in out, f"v3: rc={rc} stdout={out!r}")
        check("powervr is not loaded" in err,
              f"v3: vgem node did not fall through to the physical failure: {err.strip()!r}")

        # v4: venus capset/readback failure (probe exits non-zero).
        rc, out, err = case("v4-capset-fail", probe_mode="capset-fail", **virtio)
        check(rc == 1 and "Venus readback probe failed" in err,
              f"v4: rc={rc} stderr={err.strip()!r}")

        # v5: a non-venus capset is rejected even with driver=venus output.
        rc, out, err = case("v5-virgl-capset-rejected", probe_mode="malformed", **virtio)
        check(rc == 1 and "capset=venus" in err, f"v5: rc={rc} stderr={err.strip()!r}")

        # v6: no Venus ICD manifest installed.
        rc, out, err = case("v6-icd-absent", probe_mode="venus-ok", icd=False,
                            node_driver="virtio_gpu", powervr_module=False,
                            firmware=False, provenance_sha=None)
        check(rc == 1 and "Venus ICD manifest is absent" in err,
              f"v6: rc={rc} stderr={err.strip()!r}")

        # v7: GLES through software rasterization, not zink, is rejected.
        rc, out, err = case("v7-gles-software-rejected", probe_mode="gles-software", **virtio)
        check(rc == 1 and "zink" in err, f"v7: rc={rc} stderr={err.strip()!r}")

        # v8: the GLES probe itself fails.
        rc, out, err = case("v8-gles-fail", probe_mode="gles-fail", **virtio)
        check(rc == 1 and "GLES 3.2 Zink readback probe failed" in err,
              f"v8: rc={rc} stderr={err.strip()!r}")

        # p1-p3: the physical branch is byte-identical to BASE_REF.
        phys_ok = dict(node_driver="powervr", powervr_module=True, icd=False,
                       firmware=True, provenance_sha=FW_SHA)
        for name, mode, mutate in (
                ("p1-physical-pass", "phys-ok", {}),
                ("p2-physical-fw-mismatch", "phys-ok", {"provenance_sha": "0" * 64}),
                ("p3-physical-probe-fail", "phys-fail", {})):
            kw = dict(phys_ok) | {"probe_mode": mode} | mutate
            old = scenario(work, name + "-old", old_gate, **kw)
            new = scenario(work, name + "-new", new_gate, **kw)
            check(old == new,
                  f"{name}: physical branch changed: base rc/out/err={old!r} vs new={new!r}")
            if name == "p1-physical-pass":
                check(old[0] == 0 and "PF-OPEN-GPU PASS: km=" in old[1]
                      and f"firmware_sha256={FW_SHA}" in old[1]
                      and "mesa_renderer=PowerVR GE8300" in old[1],
                      f"{name}: unexpected physical receipt: rc={old[0]} stdout={old[1]!r}")
            else:
                check(old[0] == 1 and "PF-OPEN-GPU FAIL:" in old[2],
                      f"{name}: expected identical physical failure, got rc={old[0]}")
            notes.append(f"{name}: base and working-tree gate byte-identical (rc={old[0]})")
    except Failed as e:
        failed = True
        print(f"  FAIL {e}")
    except Blocked as e:
        blocked = True
        print(f"  BLOCKED {e}")

    for n in notes:
        print(f"  case: {n}")
    verdict = "FAIL" if failed else "BLOCKED" if blocked else "PASS"
    print(f"open-gpu-gate-virtual={verdict}")
    return 1 if failed else BLOCKED if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
