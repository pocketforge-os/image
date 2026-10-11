#!/usr/bin/env python3
"""Fail-closed static checks for the private PocketForge IME bus."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    path = ROOT / relative
    assert path.is_file(), f"missing {relative}"
    return path.read_text(encoding="utf-8")


def require(text: str, needle: str, where: str) -> None:
    assert needle in text, f"{where}: missing {needle!r}"


def main() -> None:
    packages = read("rootfs-packages.txt").splitlines()
    package_names = {
        line.strip()
        for line in packages
        if line.strip() and not line.lstrip().startswith("#")
    }
    assert "dbus" in package_names
    assert "xdg-dbus-proxy" in package_names
    for package_file in ROOT.glob("rootfs-packages*.txt"):
        names = {
            line.strip()
            for line in package_file.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        assert "dbus-user-session" not in names, package_file
        assert "dbus-x11" not in names, package_file

    sysusers = read("rootfs-overlay/usr/lib/sysusers.d/pf-ime.conf")
    require(sysusers, 'u pf-ime - "PocketForge input method" /nonexistent /usr/sbin/nologin', "sysusers")

    bus = read("rootfs-overlay/etc/systemd/system/pf-ime-bus.service")
    require(bus, "User=pf-ime", "pf-ime-bus.service")
    require(bus, "RuntimeDirectory=pf-ime", "pf-ime-bus.service")
    require(bus, "RuntimeDirectoryMode=0700", "pf-ime-bus.service")
    require(bus, "PrivateNetwork=yes", "pf-ime-bus.service")
    require(bus, "LimitCORE=0", "pf-ime-bus.service")
    assert "[Install]" not in bus, "private bus must stay dormant"

    policy = read("rootfs-overlay/usr/share/pocketforge/ime/bus.conf")
    for needle in (
        "<auth>EXTERNAL</auth>",
        '<deny user="*"/>',
        '<allow user="pf-ime"/>',
        '<deny eavesdrop="true"/>',
        '<deny own="*"/>',
        '<allow own="org.fcitx.Fcitx5"/>',
        '<allow own="org.freedesktop.portal.Fcitx"/>',
        '<allow receive_sender="*" eavesdrop="false"/>',
    ):
        require(policy, needle, "bus.conf")

    door = read("rootfs-overlay/etc/systemd/system/pf-ime-door@.service")
    require(door, "User=pf-ime", "pf-ime-door@.service")
    require(door, "UMask=0000", "pf-ime-door@.service")
    require(
        door,
        "ExecStartPost=/usr/bin/timeout 2 /bin/sh -c 'until [ -S \"/run/pf-ime-door/$1/bus\" ]; do sleep 0.05; done' sh %i",
        "pf-ime-door@.service",
    )
    require(door, "--filter", "pf-ime-door@.service")
    require(
        door,
        "--call=org.freedesktop.portal.Fcitx=org.fcitx.Fcitx.InputMethod1.CreateInputContext@/org/freedesktop/portal/inputmethod",
        "pf-ime-door@.service",
    )
    require(
        door,
        "--call=org.freedesktop.portal.Fcitx=org.fcitx.Fcitx.InputContext1.*@/org/freedesktop/portal/inputcontext/*",
        "pf-ime-door@.service",
    )
    for forbidden in ("--talk=", "--own=", "--see="):
        assert forbidden not in door, f"door grants broad policy: {forbidden}"
    assert "/run/pf-ime-door/%i/bus ];" not in door, "instance id is interpolated into shell code"

    app = read("rootfs-overlay/etc/systemd/system/pf-app@.service")
    for needle in (
        "Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/pf-no-session-bus",
        "InaccessiblePaths=-/run/pf-ime",
        "TemporaryFileSystem=/run/pf-ime-door:ro",
        "ProtectProc=invisible",
    ):
        require(app, needle, "pf-app@.service")

    app_door = read("rootfs-overlay/usr/share/pocketforge/ime/pf-app-door.conf")
    for needle in (
        "Requires=pf-ime-door@%i.service",
        "After=pf-ime-door@%i.service",
        "BindPaths=/run/pf-ime-door/%i",
        "Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/pf-ime-door/%i/bus",
        "GTK_IM_MODULE=fcitx",
        "QT_IM_MODULE=fcitx",
        "XMODIFIERS=@im=none",
    ):
        require(app_door, needle, "pf-app-door.conf")

    osk = read("rootfs-overlay/etc/systemd/system/pf-osk.service.d/10-pf-ime-sandbox.conf")
    fcitx = read("rootfs-overlay/etc/systemd/system/pf-fcitx5.service.d/10-pf-ime-sandbox.conf")
    for needle in (
        "User=pf-ime",
        "Group=pf-ime",
        "PrivateNetwork=yes",
        "RestrictAddressFamilies=AF_UNIX",
        "IPAddressDeny=any",
        "LimitCORE=0",
        "ProtectProc=invisible",
        "CapabilityBoundingSet=",
    ):
        require(osk, needle, "pf-osk sandbox")
        require(fcitx, needle, "pf-fcitx5 sandbox")

    builder = read("scripts/build-rootfs.sh")
    for relative in (
        "usr/lib/sysusers.d/pf-ime.conf",
        "usr/lib/tmpfiles.d/pf-ime.conf",
        "usr/share/pocketforge/ime/bus.conf",
        "usr/share/pocketforge/ime/pf-app-door.conf",
        "etc/systemd/system/pf-ime-bus.service",
        "etc/systemd/system/pf-ime-door@.service",
        "etc/systemd/system/pf-fcitx5.service.d/10-pf-ime-sandbox.conf",
        "etc/systemd/system/pf-osk.service.d/10-pf-ime-sandbox.conf",
    ):
        require(builder, relative, "build-rootfs.sh installer")

    workflow = read(".github/workflows/hermetic-tests.yml")
    require(workflow, "tests/test-ime-bus-security.sh", "hermetic workflow")
    print("PASS ime bus static wiring and fail-closed package policy")


if __name__ == "__main__":
    main()
