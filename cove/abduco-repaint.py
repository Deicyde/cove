#!/usr/bin/env python3
"""Make the program in an abduco session repaint: abduco-repaint.py SESSION ROWS COLS

Sends the session a real resize (one row fewer, then ROWS x COLS) as MSG_REDRAW
packets, which abduco applies from any client, then detaches. TUIs only repaint
when the size actually changes, so this is what brings back a termling that's
blank after a kitty restart (abduco keeps processes, not kitty's screen), or one
that sat in Darwin background (see Cove.gd _apply_bg_policy) and fell behind.
"""
import glob
import os
import socket
import struct
import sys
import time

MSG_DETACH, MSG_REDRAW = 2, 4


def packet(kind: int, payload: bytes = b"") -> bytes:
    # abduco 0.6 Packet: unsigned type; size_t len; then the payload union.
    return struct.pack("<I4xQ", kind, len(payload)) + payload


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.splitlines()[0], file=sys.stderr)
        return 2
    sess, rows, cols = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    if rows < 3 or cols < 1:
        return 2
    sock_dir = os.environ.get("ABDUCO_SOCKET_DIR") or os.path.expanduser("~/.abduco")
    paths = glob.glob(os.path.join(sock_dir, sess + "@*"))
    if not paths:
        return 1
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(2)
    s.connect(paths[0])
    s.sendall(packet(MSG_REDRAW, struct.pack("HHHH", rows - 1, cols, 0, 0)))
    time.sleep(0.3)   # let the program handle the first size before the second
    s.sendall(packet(MSG_REDRAW, struct.pack("HHHH", rows, cols, 0, 0)))
    time.sleep(0.1)
    s.sendall(packet(MSG_DETACH))
    s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
