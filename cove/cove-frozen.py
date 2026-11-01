#!/usr/bin/env python3
"""cove-frozen.py -- run when a termling stops updating, to see which stage stopped.

  cove-frozen.py [TERMLING] [--secs N]

TERMLING is an id, name or session; by default the termling this runs in
($COVE_SESSION), else the focused one. A termling's picture travels: its program
writes to the pty -> abduco relays that to kitty -> kitty draws a frame into
/tmp/cove/term-<id>.rgba -> the Cove shows it. For N seconds (default 5) this
watches the screen text kitty holds, kitty's frame counter and the session's
abduco processes, then says where it stopped. The report is also appended to
~/Library/Logs/cove-frozen.log, so another termling can read it when this one's
display is stuck. Typing into the stuck termling during the check gives it new
text to draw.
"""
import hashlib
import importlib.util
import json
import os
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.environ.get("KITTY_COVE_DIR", "/tmp/cove")
KITTEN = os.environ.get("COVE_KITTEN") or os.path.join(
    HERE, "..", "kitty", "launcher", "kitty.app", "Contents", "MacOS", "kitten")
SOCK = os.environ.get("COVE_KITTY_SOCKET") or "unix:/tmp/cove-kitty"
LOG = os.path.expanduser("~/Library/Logs/cove-frozen.log")


def load_watchdog():
    spec = importlib.util.spec_from_file_location("cove_watchdog", os.path.join(HERE, "cove-watchdog.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def verdict(text_changed, frames, master, client_cpu, outq, kitty_answers=True, kitty_pid=None):
    """Which stage stopped, from what the check saw."""
    if not kitty_answers and not frames:
        return ("kitty answers neither its control socket nor draws frames: its main thread is stuck, so "
                "every termling is frozen while typing still gets through. Before restarting, get its stack: "
                "sudo sample %s 3 -file ~/kitty-hang.txt" % (kitty_pid or "<kitty pid>"))
    if text_changed and not frames:
        return "kitty has new screen text but published no frame: kitty stopped drawing this window"
    if text_changed:
        return ("kitty published %d frame(s) of new text: if the picture is still stuck, "
                "the Cove (Godot) isn't showing them" % frames)
    if not master:
        return "its abduco session is gone: the program in it has exited"
    if max(client_cpu, default=0.0) >= 50.0:
        return ("abduco's attach client is spinning and has stopped relaying output to kitty "
                "(the watchdog kills and reattaches it within about a minute)")
    if outq > 0:
        return "%d bytes sit in the pty unread: the session is deadlocked (the watchdog flushes these)" % outq
    return ("kitty's screen text didn't change and nothing is queued: the program printed nothing. "
            "Run it again and type into the termling during the check")


def target(arg):
    st = json.load(open(os.path.join(DIR, "state.json")))
    want = arg or os.environ.get("COVE_SESSION") or str(st.get("focused", ""))
    for key in ("id", "session", "name"):
        for t in st.get("terminals", []):
            if str(t.get(key, "")) == str(want):
                return t
    sys.exit("no termling %r in %s/state.json" % (want, DIR))


def screen_text(pane):
    r = subprocess.run([KITTEN, "@", "--to", SOCK, "get-text", "--match", "id:%d" % pane],
                       capture_output=True, timeout=20)
    return hashlib.sha1(r.stdout).hexdigest() if r.returncode == 0 else None


def kitty_pid():
    out = subprocess.run(["/bin/ps", "-Ao", "pid=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        pid, _, cmd = line.strip().partition(" ")
        if "launcher/kitty " in cmd and SOCK.replace("unix:", "") in cmd:
            return int(pid)
    return None


def frame_seq(tid):
    try:
        with open(os.path.join(DIR, "term-%d.rgba" % tid), "rb") as f:
            f.seek(12)
            return struct.unpack("<I", f.read(4))[0]
    except (OSError, struct.error):
        return None


def main():
    args = sys.argv[1:]
    secs = 5.0
    if "--secs" in args:
        i = args.index("--secs")
        secs = float(args[i + 1])
        del args[i:i + 2]
    t = target(args[0] if args else None)
    tid, pane, sess = int(t["id"]), int(t["pane_id"]), str(t.get("session", ""))
    wd = load_watchdog()

    text0, seq0 = screen_text(pane), frame_seq(tid)
    seqs = {seq0}
    end = time.time() + secs
    while time.time() < end:
        seqs.add(frame_seq(tid))
        time.sleep(0.1)
    text1, seq1 = screen_text(pane), frame_seq(tid)
    seqs.add(seq1)
    procs = wd.ps_snapshot()
    masters, clients = wd.classify(procs)
    master = masters.get(sess)
    client_cpu = [procs[p]["cpu"] for p, s in clients if s == sess]
    outq = wd.outq_bytes(wd.shell_tty(procs, master)) if master else 0
    frames = 0 if seq0 is None or seq1 is None else ((seq1 - seq0) & 0xFFFFFFFF) // 2

    lines = [
        "%s  termling %d %r (pane %d, %s)" % (time.strftime("%Y-%m-%d %H:%M:%S"), tid, t.get("name", ""), pane, sess),
        "  screen text changed in %.0fs: %s" % (secs, "unreadable" if None in (text0, text1) else text0 != text1),
        "  kitty frames: seq %s -> %s (%d new, %d distinct seen)" % (seq0, seq1, frames, len(seqs - {None})),
        "  abduco master %s, attach client cpu %s, pty queue %d bytes" % (master, client_cpu or "none", max(outq, 0)),
        "  => " + verdict(text0 is not None and text0 != text1, frames, master, client_cpu, max(outq, 0),
                          None not in (text0, text1), kitty_pid()),
    ]
    print("\n".join(lines))
    try:
        with open(LOG, "a") as f:
            f.write("\n".join(lines) + "\n")
    except OSError:
        pass


if __name__ == "__main__":
    main()
