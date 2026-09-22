#!/usr/bin/env python3
"""Forward the Cove's page-critter input to Vibefox's control socket.

Godot keeps one of these alive (OS.execute_with_pipe) and writes one JSON
command per line to its stdin; each line is sent verbatim to the unix socket
(default /tmp/vibefox/control.sock) and the reply lines are drained and
dropped. The socket is (re)connected on demand, so Vibefox can restart, and
input while it's away is simply ignored. We exit only when Godot closes stdin.
"""
import os
import socket
import sys
import threading
import time

SOCK = sys.argv[1] if len(sys.argv) > 1 else "/tmp/vibefox/control.sock"
LOG = os.environ.get("COVE_VIBEFOX_LOG", "/tmp/cove-vibefox.log")
LOG_MAX = 256 * 1024
_lock = threading.Lock()
_log_lock = threading.Lock()
_sock = None


def log(direction, text):
    """Both halves of the conversation, so a dead input path is one file away."""
    try:
        with _log_lock:
            if os.path.exists(LOG) and os.path.getsize(LOG) > LOG_MAX:
                os.remove(LOG)
            with open(LOG, "a") as f:
                f.write("%s %s %s\n" % (time.strftime("%H:%M:%S"), direction, text[:400]))
    except OSError:
        pass


def _drain(s):
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            for line in chunk.decode("utf-8", "replace").splitlines():
                if line.strip():
                    log("<--", line.strip())
    except OSError:
        pass
    with _lock:
        global _sock
        if _sock is s:
            _sock = None


def _connect():
    global _sock
    if _sock is not None:
        return _sock
    if not os.path.exists(SOCK):
        return None
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(0.5)
        s.connect(SOCK)
        s.settimeout(None)
    except OSError:
        s.close()
        return None
    _sock = s
    threading.Thread(target=_drain, args=(s,), daemon=True).start()
    return s


def _send(line):
    for _attempt in range(2):
        with _lock:
            s = _connect()
        if s is None:
            log("!!!", "no connection to %s; dropped: %s" % (SOCK, line.decode("utf-8", "replace").strip()))
            return
        try:
            s.sendall(line)
            log("-->", line.decode("utf-8", "replace").strip())
            return
        except OSError:
            with _lock:
                if _sock is s:
                    _sock = None
            try:
                s.close()
            except OSError:
                pass


while True:
    raw = sys.stdin.buffer.readline()
    if not raw:
        break
    line = raw.strip()
    if line:
        _send(line + b"\n")
time.sleep(0.3)   # let the drain thread log the last replies before we go
