#!/usr/bin/env python3
"""X11 events may precede the GetInputFocus reply (G' gps1: x11-authorization-refused
reason=unexpected_x11_reply killed the session when Xwayland was replaced).
connect_authorized() and probe() must skip events, still fail closed on errors and
on a server that only ever sends events."""
from importlib.machinery import SourceFileLoader
from pathlib import Path
import os
import socket
import struct
import sys
import tempfile
import threading
import types

root = Path(__file__).resolve().parent.parent
module = types.ModuleType("pf_x11_authorize")
SourceFileLoader(module.__name__, str(root / "rootfs-overlay/usr/lib/pocketforge/pf-x11-authorize")).exec_module(module)


def recv_exact(c, n):
    d = bytearray()
    while len(d) < n:
        k = c.recv(n - len(d))
        assert k
        d.extend(k)
    return bytes(d)


def serve(path, packets_before, final):
    lst = socket.socket(socket.AF_UNIX)
    lst.bind(str(path))
    lst.listen(1)

    def run():
        c, _ = lst.accept()
        with c, lst:
            assert recv_exact(c, 12)[0] == ord("l")
            c.sendall(struct.pack("<BBHHH", 1, 0, 11, 0, 0))
            h = recv_exact(c, 8)
            recv_exact(c, struct.unpack_from("<H", h, 2)[0] * 4 - 8)
            recv_exact(c, 4)
            try:
                for p in packets_before:
                    c.sendall(p)
                if final is not None:
                    c.sendall(final)
                c.recv(1)
            except OSError:
                pass  # client closed after deciding

    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t


def event(code=28):
    return bytes([code]) + b"\0" * 31


def attempt(packets, final):
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "X0"
        t = serve(p, packets, final)
        try:
            c = module.connect_authorized(p, "gamer", os.getgid(), 0o660, 2)
            c.close()
            return None
        except SystemExit as e:
            return str(e)
        finally:
            t.join(3)


ok = b"\1\0" + struct.pack("<H", 2) + b"\0" * 28
assert attempt([], ok) is None, "plain reply"
assert attempt([event()], ok) is None, "event before reply must be skipped"
assert attempt([event(28), event(0x80 | 28), event(2)], ok) is None, "several events (incl. send_event flag)"
err = attempt([], b"\0\0" + struct.pack("<H", 2) + b"\0" * 28)
assert err and "server_rejected_acl" in err, f"X error must still fail closed: {err}"
assert attempt([event(34)], ok) is None, "MappingNotify (34) before the reply"
generic = bytes([35]) + b"\0\0\0" + struct.pack("<I", 2) + b"\0" * 24 + b"\0" * 8
assert attempt([generic], ok) is None, "GenericEvent carries 4*length extra bytes"
bad = attempt([], b"\1\0" + struct.pack("<H", 9) + b"\0" * 28)
assert bad and "seq_mismatch" in bad, f"wrong sequence must fail closed: {bad}"
flood = attempt([event() for _ in range(200)], None)
assert flood and "unexpected_x11_reply" in flood, f"events-only server must fail closed: {flood}"
print("PF_X11_AUTHORIZE_EVENTS PASS")
