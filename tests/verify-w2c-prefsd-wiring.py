#!/usr/bin/env python3
"""Recipe-level assertions for the W2c pf-prefsd image deployment."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYSTEMD = ROOT / "rootfs-overlay/etc/systemd/system"
SOCKET = "/run/pocketforge/prefsd.sock"


def text(path: Path) -> str:
    assert path.is_file(), f"missing recipe file: {path.relative_to(ROOT)}"
    return path.read_text()


for relative in (
    "pf-shell-selected.service",
    "pf-foreground@.service",
    "pf-broker.service.d/10-prefsd.conf",
):
    unit = text(SYSTEMD / relative)
    assert "Wants=pf-prefsd.service" in unit, relative
    assert "After=" in unit and "pf-prefsd.service" in unit, relative
    assert f"Environment=PF_PREFSD_SOCK={SOCKET}" in unit, relative
    assert "Requires=pf-prefsd.service" not in unit, relative

assert text(ROOT / "rootfs-overlay/etc/environment").strip() == f"PF_PREFSD_SOCK={SOCKET}"

dockerfile = text(ROOT / "build/Dockerfile.pf")
runtime_guard = re.findall(
    r'^\[ "\$\{PF_RUNTIME_SHA\}" = "([0-9a-f]{40})" \] '
    r'\|\| \{ echo "FATAL: runtime pin drift: \$\{PF_RUNTIME_SHA\}"; exit 1; \}$',
    dockerfile,
    flags=re.MULTILINE,
)
assert runtime_guard == ["1580da3e29184170e63bd4ceaa8391ddcfd4b7b0"], (
    "expected exactly one PF_RUNTIME_SHA drift guard pinned to runtime 1580da3e, "
    f"found: {runtime_guard}"
)
assert "2478b37755bc9968a49105fb9223be1f55ca7ddd" not in dockerfile
assert "cargo build --offline --locked --release --target \"${PF_RUNTIME_TARGET}\" -p pf-prefsd --bin pf-prefsd" in dockerfile
assert "install -D -m 0755 \"${PREFSD_BIN}\" /out/bin/pf-prefsd" in dockerfile
assert "systemd/pf-prefsd.service /out/systemd/pf-prefsd.service" in dockerfile
assert "systemd/pf-session-authorityd.service /out/systemd/pf-session-authorityd.service" in dockerfile
assert "systemd/pocketforge.conf /out/tmpfiles.d/pocketforge.conf" in dockerfile
for crate in (
    "pf-scene",
    "pf-ports",
    "pf-render",
    "pf-framehost",
    "pf-framehost-wayland",
    "pf-theme",
    "pf-input-map",
    "pf-prefs",
    "pf-prefs-port",
    "pf-session-client",
    "pf-session-authority",
    "pf-wire",
):
    assert re.search(rf"\b{re.escape(crate)}\b", dockerfile), crate
assert "COPY --from=runtime-src . /work/runtime-contract" in dockerfile
assert "check-launcher-runtime-contract /work/launcher /work/runtime-contract" in dockerfile

recipe = text(ROOT / "scripts/build-rootfs.sh")
assert '"${ROOTFS}/usr/bin/pf-prefsd"' in recipe
assert 'multi-user.target.wants/pf-prefsd.service' in recipe
assert '"${RUNTIME_DIR}/systemd/pf-prefsd.service"' in recipe
assert '"${RUNTIME_DIR}/systemd/pf-session-authorityd.service"' in recipe
assert '"${RUNTIME_DIR}/tmpfiles.d/pocketforge.conf"' in recipe
assert '"${ROOTFS}/usr/lib/tmpfiles.d/pocketforge.conf"' in recipe
assert 'rootfs-overlay/etc/environment' in recipe
assert "grep -qxF 'PF_PREFSD_SOCK=/run/pocketforge/prefsd.sock'" in recipe
assert not (SYSTEMD / "pf-prefsd.service").exists()
assert not (SYSTEMD / "pf-session-authorityd.service").exists()

print("PASS W2c pf-prefsd recipe wiring")
