#!/usr/bin/env python3
"""Hold one idle RFB connection open against the E2E wayvnc.

Why this exists: sway only advertises `wl_seat` pointer/keyboard capability when
the seat actually has a device, and the wlroots headless backend creates none.
wayvnc registers a `wlr_virtual_pointer_v1` + `wlr_virtual_keyboard_v1` pair on
the seat -- but only *per connected client*, and it tears them down again the
moment the last client disconnects.  Measured on wayvnc 0.10.1 / sway 1.12:

    no client connected -> seat0: capabilities=0 [none]      devices=0
    client connected    -> seat0: capabilities=3 [pointer,keyboard] devices=2

So merely running wayvnc is not enough; something has to stay connected.  This
script is that something: it completes the RFB handshake and then sits there,
never requesting a framebuffer update, so it costs nothing but a socket.  It
reconnects with backoff if wayvnc restarts or drops it.

Usage: vnc-hold.py [HOST [PORT]]   (defaults: localhost 5910)

Note that the connection is deliberately passive: no SetEncodings, no
FramebufferUpdateRequest.  A server only sends framebuffer updates in response
to a request, so an idle holder generates no encoding work at all -- which also
sidesteps wayvnc's "No supported buffer formats were found" capture errors on
this headless output.  Real VNC viewers can connect alongside it.
"""

import socket
import struct
import sys
import time

RFB_VERSION = b"RFB 003.008\n"
SEC_NONE = 1


def log(msg):
    print("vnc-hold: %s" % msg, file=sys.stderr, flush=True)


def handshake(sock):
    """Perform an RFB 3.8 None-auth handshake. Returns (width, height, name)."""
    server_version = recv_exactly(sock, 12)
    if not server_version.startswith(b"RFB "):
        raise ConnectionError("not an RFB server: %r" % server_version)
    sock.sendall(RFB_VERSION)

    count = recv_exactly(sock, 1)[0]
    if count == 0:
        # Failure: a 4-byte length plus a reason string.
        reason_len = struct.unpack(">I", recv_exactly(sock, 4))[0]
        raise ConnectionError(
            "server refused: %s" % recv_exactly(sock, reason_len).decode("utf-8", "replace")
        )
    types = list(recv_exactly(sock, count))
    if SEC_NONE not in types:
        raise ConnectionError(
            "server requires authentication (security types %r); "
            "start wayvnc without auth, or hold the seat some other way" % types
        )
    sock.sendall(bytes([SEC_NONE]))

    result = struct.unpack(">I", recv_exactly(sock, 4))[0]
    if result != 0:
        raise ConnectionError("security handshake failed (result=%d)" % result)

    sock.sendall(bytes([1]))  # ClientInit: shared = 1, so viewers can join too.
    init = recv_exactly(sock, 24)
    width, height = struct.unpack(">HH", init[:4])
    name_len = struct.unpack(">I", init[20:24])[0]
    name = recv_exactly(sock, name_len).decode("utf-8", "replace") if name_len else ""
    return width, height, name


def recv_exactly(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("server closed the connection")
        buf += chunk
    return buf


def hold(host, port):
    # create_connection walks every getaddrinfo result, which matters because
    # wayvnc bound to "localhost" listens on ::1 only.
    sock = socket.create_connection((host, port), timeout=10)
    try:
        sock.settimeout(None)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        width, height, name = handshake(sock)
        log("connected to %s:%s (%dx%d, %r) -- holding the seat open" % (
            host, port, width, height, name))
        # Idle forever, draining anything the server volunteers (it should send
        # nothing, since we never request an update).
        while True:
            if not sock.recv(65536):
                raise ConnectionError("server closed the connection")
    finally:
        sock.close()


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "localhost"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5910
    delay = 0.5
    while True:
        try:
            hold(host, port)
            delay = 0.5
        except KeyboardInterrupt:
            return 0
        except (OSError, ConnectionError) as exc:
            log("%s -- retrying in %.1fs" % (exc, delay))
            time.sleep(delay)
            delay = min(delay * 2, 10.0)


if __name__ == "__main__":
    sys.exit(main())
