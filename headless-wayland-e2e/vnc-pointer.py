#!/usr/bin/env python3
"""Pointer gestures that sway's `seat ... cursor` command cannot produce.

Two things turn out to be unreachable through sway IPC on sway 1.12, and both
are needed to drive a real app:

1. **Wheel / axis events.**  `seat <s> cursor press button4|button5` answers
   `{"success": true}` but sends nothing a client can use: sway resolves those
   names to the internal SWAY_SCROLL_UP/DOWN pseudo-codes, which exist so that
   `bindsym button4 ...` can match, and `cursor press` pushes the pseudo-code
   down the ordinary button path.  No `wl_pointer.axis` is ever emitted.

2. **Motion while a button is held** (i.e. any drag).  `cursor set`/`cursor
   move` only *rebase* the pointer, and sway's `seatop_down` -- the seat
   operation that is active for as long as a button is pressed on a client
   surface -- implements no rebase handler, so the motion is dropped on the
   floor.  The client sees press and release at the same pixel.

Both were verified against two unrelated clients: a terminal emulator
(scrollback would not move, drag-select selected nothing) and a WebKitGTK
webview (no scrolling at any notch count, scrollbar thumb never followed the
cursor -- while a plain *click* on the scrollbar track did jump it, proving the
button events themselves arrive fine).

wayvnc drives a `zwlr_virtual_pointer_v1`, which emits proper
motion_absolute / button / axis + frame.  So both gestures are synthesised by
speaking RFB to the wayvnc the harness already runs for its seat capability.
The connection is shared, so vnc-hold.py and any real viewer stay put.

RFB PointerEvent button-mask bits (RFC 6143 sec. 7.5.5):
    bit 0 (0x01) = left        bit 1 (0x02) = middle    bit 2 (0x04) = right
    bit 3 (0x08) = wheel up    bit 4 (0x10) = wheel down
    bit 5 (0x20) = wheel left  bit 6 (0x40) = wheel right

Usage:
    vnc-pointer.py HOST PORT scroll X Y NOTCHES [vertical|horizontal]
    vnc-pointer.py HOST PORT drag X1 Y1 X2 Y2 [STEPS]

NOTCHES > 0 scrolls down/right, < 0 scrolls up/left.
"""

import importlib.util
import os
import socket
import struct
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))

# Reuse the RFB handshake from vnc-hold.py (its filename is not importable).
# Never leave a __pycache__ behind: ui.sh runs this on every scroll and drag,
# and a stray build artifact in a working tree is pure noise.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location(
    "vnc_hold", os.path.join(_HERE, "vnc-hold.py"))
_vnc_hold = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_vnc_hold)

CLIENT_POINTER_EVENT = 5

BTN_LEFT = 1 << 0
WHEEL_UP = 1 << 3
WHEEL_DOWN = 1 << 4
WHEEL_LEFT = 1 << 5
WHEEL_RIGHT = 1 << 6

# wayvnc only flushes its virtual-pointer requests while the client is
# connected, so never close the socket immediately after the last event.
SETTLE = 0.25


def log(msg):
    print("vnc-pointer: %s" % msg, file=sys.stderr, flush=True)


class Pointer:
    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.settimeout(10)
        self.width, self.height, _name = _vnc_hold.handshake(self.sock)

    def close(self):
        time.sleep(SETTLE)
        self.sock.close()

    def clamp(self, x, y):
        return (max(0, min(int(x), self.width - 1)),
                max(0, min(int(y), self.height - 1)))

    def event(self, mask, x, y, settle=0.02):
        x, y = self.clamp(x, y)
        self.sock.sendall(struct.pack(">BBHH", CLIENT_POINTER_EVENT, mask, x, y))
        if settle:
            time.sleep(settle)


def do_scroll(p, x, y, notches, axis):
    if axis == "horizontal":
        bit = WHEEL_RIGHT if notches > 0 else WHEEL_LEFT
    else:
        bit = WHEEL_DOWN if notches > 0 else WHEEL_UP
    # Park the pointer on the target first: the compositor routes the axis to
    # whatever surface is under the virtual pointer, and wayvnc only knows the
    # position carried by a PointerEvent.
    p.event(0, x, y, settle=0.05)
    for _ in range(abs(notches)):
        p.event(bit, x, y)
        p.event(0, x, y, settle=0.03)


def do_drag(p, x1, y1, x2, y2, steps):
    p.event(0, x1, y1, settle=0.05)
    p.event(BTN_LEFT, x1, y1, settle=0.08)
    for i in range(1, steps + 1):
        p.event(BTN_LEFT,
                x1 + (x2 - x1) * i // steps,
                y1 + (y2 - y1) * i // steps)
    p.event(BTN_LEFT, x2, y2, settle=0.08)
    p.event(0, x2, y2, settle=0.05)


def main(argv):
    if len(argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    host, port, mode = argv[1], int(argv[2]), argv[3]
    rest = argv[4:]
    try:
        if mode == "scroll":
            if len(rest) < 3:
                print(__doc__, file=sys.stderr)
                return 2
            x, y, notches = int(rest[0]), int(rest[1]), int(rest[2])
            axis = rest[3] if len(rest) > 3 else "vertical"
            if notches == 0:
                return 0
            p = Pointer(host, port)
            try:
                do_scroll(p, x, y, notches, axis)
            finally:
                p.close()
        elif mode == "drag":
            if len(rest) < 4:
                print(__doc__, file=sys.stderr)
                return 2
            x1, y1, x2, y2 = (int(v) for v in rest[:4])
            steps = int(rest[4]) if len(rest) > 4 else 20
            steps = max(1, steps)
            p = Pointer(host, port)
            try:
                do_drag(p, x1, y1, x2, y2, steps)
            finally:
                p.close()
        else:
            log("unknown mode: %s (expected scroll or drag)" % mode)
            return 2
    except (OSError, ConnectionError) as exc:
        log("failed: %s" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
