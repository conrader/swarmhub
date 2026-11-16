#!/usr/bin/env python3
"""Exercise a scratch Xvfb display and both local VNC sockets; no host display or TCP VNC."""

import ctypes as c
import json
import os
from pathlib import Path
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time


def read_exact(conn, count):
    result = bytearray()
    while len(result) < count:
        chunk = conn.recv(count - len(result))
        if not chunk:
            raise RuntimeError("VNC closed before initialization")
        result.extend(chunk)
    return bytes(result)


def attach(path):
    conn = socket.socket(socket.AF_UNIX)
    conn.settimeout(8)
    conn.connect(str(path))
    assert read_exact(conn, 12) == b"RFB 003.008\n"
    conn.sendall(b"RFB 003.008\n")
    assert 1 in read_exact(conn, read_exact(conn, 1)[0])
    conn.sendall(b"\x01")
    assert read_exact(conn, 4) == b"\0\0\0\0"
    conn.sendall(b"\x01")
    width, height = struct.unpack("!HH", read_exact(conn, 4))
    assert (width, height) == (1280, 800)
    read_exact(conn, 16)
    name_size = struct.unpack("!I", read_exact(conn, 4))[0]
    assert name_size < 1024
    read_exact(conn, name_size)
    return conn


def until(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("Desktop did not reach the expected state")


def verify_pointer(display_name, watch, control):
    lib = c.CDLL("libX11.so.6")
    lib.XOpenDisplay.argtypes = [c.c_char_p]
    lib.XOpenDisplay.restype = c.c_void_p
    lib.XCloseDisplay.argtypes = [c.c_void_p]
    lib.XDefaultRootWindow.argtypes = [c.c_void_p]
    lib.XDefaultRootWindow.restype = c.c_ulong
    lib.XQueryPointer.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong),
                                 c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(c.c_int),
                                 c.POINTER(c.c_int), c.POINTER(c.c_uint)]
    handle = lib.XOpenDisplay(display_name.encode())
    assert handle
    root = lib.XDefaultRootWindow(handle)

    def pointer():
        actual_root, child = c.c_ulong(), c.c_ulong()
        root_x, root_y, win_x, win_y, mask = c.c_int(), c.c_int(), c.c_int(), c.c_int(), c.c_uint()
        assert lib.XQueryPointer(handle, root, c.byref(actual_root), c.byref(child), c.byref(root_x),
                                 c.byref(root_y), c.byref(win_x), c.byref(win_y), c.byref(mask))
        return root_x.value, root_y.value

    try:
        control.sendall(struct.pack("!BBHH", 5, 0, 311, 217))
        assert until(lambda: pointer() == (311, 217))
        watch.sendall(struct.pack("!BBHH", 5, 0, 73, 85))
        # The real VNC process must ignore pointer events on its viewer socket.
        for _ in range(12):
            time.sleep(0.05)
            assert pointer() == (311, 217)
    finally:
        lib.XCloseDisplay(handle)


def main(bridge):
    with tempfile.TemporaryDirectory(prefix="swarmhub-desktop-", dir=os.environ.get("TMPDIR", "/var/tmp")) as temp:
        root = Path(temp)
        journal = root / "workspace.sqlite3"
        identity = "1" * 32
        with sqlite3.connect(str(journal)) as db:
            db.execute("CREATE TABLE journal (launch_key TEXT UNIQUE)")
            db.execute("INSERT INTO journal VALUES (?)", (identity,))
        ready = root / "ready.json"
        finish = root / "finish"
        program = ("import json,os,pathlib,sys,time; "
                   "pathlib.Path(sys.argv[1]).write_text(json.dumps([os.environ['DISPLAY'],os.environ['XAUTHORITY']])); "
                   "exec('while not pathlib.Path(sys.argv[2]).exists():\\n time.sleep(.03)')")
        env = dict(os.environ, SWARMHUB_JOURNAL=str(journal), SWARMHUB_LAUNCH_KEY=identity)
        with (root / "launcher.log").open("w+") as log:
            child = subprocess.Popen([bridge, "run-desktop", "--", sys.executable, "-c", program,
                                      str(ready), str(finish)], env=env, stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=log)
            try:
                until(lambda: ready.is_file() and ready.stat().st_size or child.poll() is not None, 45)
                assert child.poll() is None
                display_name, auth = json.loads(ready.read_text())
                os.environ["XAUTHORITY"] = auth
                folder = root / ("desktop-" + identity)
                assert folder.stat().st_mode & 0o777 == 0o700
                no_access = subprocess.run(["/usr/bin/xdpyinfo", "-display", display_name],
                    env=dict(os.environ, XAUTHORITY=str(root / "wrong-auth")), capture_output=True, timeout=3)
                assert no_access.returncode != 0
                with attach(folder / "view") as watch, attach(folder / "control") as control:
                    verify_pointer(display_name, watch, control)
                finish.touch()
                assert child.wait(timeout=8) == 0
                assert not folder.exists()
            except BaseException:
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=5)
    print("Desktop smoke passed: private X11 authorization, watch-only input rejection, takeover, cleanup.")


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).absolute()))
