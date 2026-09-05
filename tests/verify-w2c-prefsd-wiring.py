#!/usr/bin/env python3
"""Recipe-level assertions for the W2c pf-prefsd image deployment."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SYSTEMD = ROOT / "rootfs-overlay/etc/systemd/system"
SOCKET = "/run/pocketforge/prefsd.sock"


def text(path: Path) -> str:
    assert path.is_file(), f"missing recipe file: {path.relative_to(ROOT)}"
    return path.read_text()


prefsd = text(SYSTEMD / "pf-prefsd.service")
assert "Description=PocketForge preference state authority" in prefsd
assert (
    "ExecStart=/usr/bin/pf-prefsd "
    "--state-dir /var/lib/pocketforge/shell "
    f"--socket {SOCKET}"
) in prefsd
assert "User=gamer" in prefsd
assert "StateDirectory=pocketforge/shell" in prefsd
assert "RuntimeDirectory=pocketforge" in prefsd
assert "RuntimeDirectory=pocketforge" in text(SYSTEMD / "pf-session-authorityd.service")
assert "Restart=on-failure" in prefsd
assert "WantedBy=multi-user.target" in prefsd

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
assert "78e4754cd0d6ccdc0aa858bc2d889b7f33458ec0" in dockerfile
assert "cargo build --locked --release --target \"${PF_RUNTIME_TARGET}\" -p pf-prefsd --bin pf-prefsd" in dockerfile
assert "install -D -m 0755 \"${PREFSD_BIN}\" /out/bin/pf-prefsd" in dockerfile

recipe = text(ROOT / "scripts/build-rootfs.sh")
assert '"${ROOTFS}/usr/bin/pf-prefsd"' in recipe
assert 'multi-user.target.wants/pf-prefsd.service' in recipe
assert 'rootfs-overlay/etc/environment' in recipe
assert "grep -qxF 'PF_PREFSD_SOCK=/run/pocketforge/prefsd.sock'" in recipe

print("PASS W2c pf-prefsd recipe wiring")
