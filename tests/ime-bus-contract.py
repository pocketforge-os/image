#!/usr/bin/env python3
"""Contract stub and clients for the real private-bus/proxy security test."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib


PORTAL_NAME = "org.freedesktop.portal.Fcitx"
PORTAL_PATH = "/org/freedesktop/portal/inputmethod"
IM_IFACE = "org.fcitx.Fcitx.InputMethod1"
IC_IFACE = "org.fcitx.Fcitx.InputContext1"


class AccessDenied(dbus.DBusException):
    _dbus_error_name = "org.pocketforge.Error.AccessDenied"


class Context(dbus.service.Object):
    def __init__(self, bus: dbus.Bus, path: str, owner: str, app_id: str, focus_file: Path) -> None:
        super().__init__(bus, path)
        self.owner = owner
        self.app_id = app_id
        self.focus_file = focus_file
        self.surrounding = ""

    def owned(self, sender: str | None) -> None:
        if sender != self.owner:
            raise AccessDenied("input context belongs to another door")

    @dbus.service.method(IC_IFACE, in_signature="s", out_signature="s", sender_keyword="sender")
    def TypeText(self, text: str, sender: str | None = None) -> str:
        self.owned(sender)
        return text

    @dbus.service.method(IC_IFACE, in_signature="", out_signature="b", sender_keyword="sender")
    def InvokeAction(self, sender: str | None = None) -> bool:
        self.owned(sender)
        return True

    @dbus.service.method(IC_IFACE, in_signature="", out_signature="b", sender_keyword="sender")
    def FocusIn(self, sender: str | None = None) -> bool:
        self.owned(sender)
        front = self.focus_file.read_text(encoding="utf-8").strip()
        if front != self.app_id:
            raise AccessDenied("door app is not the gamescope-confirmed front app")
        return True

    @dbus.service.method(IC_IFACE, in_signature="s", out_signature="", sender_keyword="sender")
    def SetSurroundingText(self, text: str, sender: str | None = None) -> None:
        self.owned(sender)
        self.surrounding = text

    @dbus.service.method(IC_IFACE, in_signature="", out_signature="s", sender_keyword="sender")
    def GetSurroundingText(self, sender: str | None = None) -> str:
        self.owned(sender)
        return self.surrounding


class InputMethod(dbus.service.Object):
    def __init__(self, bus: dbus.Bus, focus_file: Path) -> None:
        super().__init__(bus, PORTAL_PATH)
        self.bus = bus
        self.focus_file = focus_file
        self.contexts: list[Context] = []

    @dbus.service.method(IM_IFACE, in_signature="", out_signature="o", sender_keyword="sender")
    def CreateInputContext(self, sender: str | None = None) -> dbus.ObjectPath:
        if sender is None:
            raise AccessDenied("missing sender")
        index = len(self.contexts)
        app_id = f"app-{'a' if index == 0 else 'b' if index == 1 else index}"
        path = f"/org/freedesktop/portal/inputcontext/{index + 1}"
        self.contexts.append(Context(self.bus, path, sender, app_id, self.focus_file))
        return dbus.ObjectPath(path)


def serve(focus_file: Path) -> None:
    DBusGMainLoop(set_as_default=True)
    bus = dbus.bus.BusConnection(os.environ["DBUS_SESSION_BUS_ADDRESS"])
    names = [
        dbus.service.BusName(PORTAL_NAME, bus=bus, do_not_queue=True),
        dbus.service.BusName("org.fcitx.Fcitx5", bus=bus, do_not_queue=True),
    ]
    input_method = InputMethod(bus, focus_file)
    print("READY", flush=True)
    GLib.MainLoop().run()
    assert names and input_method


def expect_denied(name: str, call) -> None:
    try:
        call()
    except dbus.DBusException as exc:
        error = exc.get_dbus_name()
        if error not in {
            "org.freedesktop.DBus.Error.AccessDenied",
            "org.freedesktop.DBus.Error.ServiceUnknown",
            "org.pocketforge.Error.AccessDenied",
        }:
            raise AssertionError(f"{name}: wrong error {error}: {exc}") from exc
        print(f"PASS {name}: refused ({error})")
        return
    raise AssertionError(f"{name}: unexpectedly allowed")


def proxy_bus(address: str) -> dbus.Bus:
    return dbus.bus.BusConnection(address)


def run_clients(address_a: str, address_b: str, focus_file: Path) -> None:
    DBusGMainLoop(set_as_default=True)
    a = proxy_bus(address_a)
    b = proxy_bus(address_b)
    def obj(bus: dbus.Bus, name: str, path: str):
        return bus.get_object(
            name,
            path,
            introspect=False,
            follow_name_owner_changes=True,
        )

    method_a = dbus.Interface(obj(a, PORTAL_NAME, PORTAL_PATH), IM_IFACE)
    method_b = dbus.Interface(obj(b, PORTAL_NAME, PORTAL_PATH), IM_IFACE)
    context_a_path = str(method_a.CreateInputContext())
    context_b_path = str(method_b.CreateInputContext())
    context_a = dbus.Interface(obj(a, PORTAL_NAME, context_a_path), IC_IFACE)
    context_b = dbus.Interface(obj(b, PORTAL_NAME, context_b_path), IC_IFACE)
    context_a_from_b = dbus.Interface(obj(b, PORTAL_NAME, context_a_path), IC_IFACE)

    assert str(context_a.TypeText("typed-through-own-door")) == "typed-through-own-door"
    assert str(context_b.TypeText("second-door-positive-control")) == "second-door-positive-control"
    context_a.SetSurroundingText("app-a private text")
    assert str(context_a.GetSurroundingText()) == "app-a private text"
    assert bool(context_a.FocusIn())
    print("PASS door_create_and_type: each app creates and uses its own context")

    controller = dbus.Interface(
        obj(a, "org.fcitx.Fcitx5", "/controller"),
        "org.fcitx.Fcitx.Controller1",
    )
    expect_denied("door_controller1_refused", lambda: controller.Ping())

    dbus_iface = dbus.Interface(
        obj(a, "org.freedesktop.DBus", "/org/freedesktop/DBus"),
        "org.freedesktop.DBus",
    )
    expect_denied("door_own_name_refused", lambda: dbus_iface.RequestName("org.pocketforge.Attacker", 0))

    unknown = dbus.Interface(obj(a, PORTAL_NAME, PORTAL_PATH), "org.pocketforge.Unknown")
    expect_denied("door_unknown_method_refused", lambda: unknown.Poke())
    expect_denied("door_invokeaction_other_ctx_refused", lambda: context_a_from_b.InvokeAction())
    expect_denied("door_focus_other_ctx_refused", lambda: context_a_from_b.FocusIn())
    expect_denied("door_surrounding_text_other_ctx_refused", lambda: context_a_from_b.GetSurroundingText())

    focus_file.write_text("app-b\n", encoding="utf-8")
    expect_denied("door_focus_not_front_refused", lambda: context_a.FocusIn())
    assert bool(context_b.FocusIn())
    print("PASS second_app_isolated: other context and front-app focus remain private")


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("usage: ime-bus-contract.py serve FOCUS | client ADDR_A ADDR_B FOCUS")
    if sys.argv[1] == "serve" and len(sys.argv) == 3:
        serve(Path(sys.argv[2]))
    elif sys.argv[1] == "client" and len(sys.argv) == 5:
        run_clients(sys.argv[2], sys.argv[3], Path(sys.argv[4]))
    else:
        raise SystemExit("invalid arguments")


if __name__ == "__main__":
    main()
