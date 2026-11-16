"""Log actual button presses in a dedicated scratch Xvfb; never use a host display."""

import ctypes as c
from pathlib import Path
import sys


class Button(c.Structure):
    _fields_ = [
        ("type", c.c_int), ("serial", c.c_ulong), ("sent", c.c_int), ("display", c.c_void_p),
        ("window", c.c_ulong), ("root", c.c_ulong), ("subwindow", c.c_ulong), ("time", c.c_ulong),
        ("x", c.c_int), ("y", c.c_int), ("root_x", c.c_int), ("root_y", c.c_int),
        ("state", c.c_uint), ("button", c.c_uint), ("same_screen", c.c_int),
    ]


class Event(c.Union):
    _fields_ = [("button", Button), ("pad", c.c_long * 24)]


def main():
    lib = c.CDLL("libX11.so.6")
    address = c.c_void_p
    window_id = c.c_ulong
    lib.XOpenDisplay.argtypes, lib.XOpenDisplay.restype = [c.c_char_p], address
    lib.XDefaultRootWindow.argtypes, lib.XDefaultRootWindow.restype = [address], window_id
    lib.XCreateSimpleWindow.argtypes = [address, window_id, c.c_int, c.c_int, c.c_uint, c.c_uint, c.c_uint, c.c_ulong, c.c_ulong]
    lib.XCreateSimpleWindow.restype = window_id
    lib.XSelectInput.argtypes = [address, window_id, c.c_long]
    lib.XMapRaised.argtypes = [address, window_id]
    lib.XSetInputFocus.argtypes = [address, window_id, c.c_int, c.c_ulong]
    lib.XSync.argtypes = [address, c.c_int]
    lib.XNextEvent.argtypes = [address, c.POINTER(Event)]
    display = lib.XOpenDisplay(None)
    assert display
    root = lib.XDefaultRootWindow(display)
    window = lib.XCreateSimpleWindow(display, root, 0, 0, 1280, 800, 0, 0, 0x242747)
    lib.XSelectInput(display, window, (1 << 2) | (1 << 0))  # ButtonPressMask | KeyPressMask
    lib.XMapRaised(display, window)
    lib.XSync(display, 0)
    lib.XSetInputFocus(display, window, 1, 0)
    lib.XSync(display, 0)
    event = Event()
    with Path(sys.argv[1]).open("w", buffering=1) as log:
        print("ready", file=log)
        print("\x1b]7501;state=idle\x1b\\", end="", flush=True)
        while True:
            lib.XNextEvent(display, c.byref(event))
            if event.button.type == 4:
                print(f"click {event.button.button} {event.button.root_x} {event.button.root_y}", file=log)
            elif event.button.type == 2:
                print("key", file=log)  # Observe delivery; don't record which key.


if __name__ == "__main__":
    main()
