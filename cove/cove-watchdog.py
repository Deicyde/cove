#!/usr/bin/env python3
"""cove-watchdog -- detect and heal wedged termling sessions.

abduco (0.6) relays with blocking I/O and no write backoff, which leaves two
ways a termling can freeze while every process in it stays alive:

  1. Spinning attach client: the client busy-retries a failing write() to the
     kitty pane's tty at ~100% CPU and stops relaying input. Symptom: an
     `abduco -A cove-N` process with a real tty pegging a core for minutes.
     Heal: kill the client (the session master holds the shell, nothing is
     lost) and reattach the session in a fresh kitty OS window.

  2. Pty deadlock: the agent blocks writing output into a full pty buffer the
     master never drains, while the master blocks writing input into a buffer
     the agent never reads. Both sit at 0% CPU forever. Symptom: the slave's
     output queue (TIOCOUTQ) is nonzero and byte-identical across samples
     while the master's CPU time does not move. Heal: tcflush both queues
     (drops the jammed bytes; the TUI repaints) and SIGWINCH the foreground
     process group so it redraws.

Run periodically (Cove.gd invokes it every ~30s from the ls-poll loop). Keeps
one sample of state in /tmp/cove/watchdog.json so every trigger needs two
consecutive positive samples. Logs actions to /tmp/cove-watchdog.log; a run
with nothing to do writes nothing.
"""

import fcntl
import json
import os
import signal
import struct
import subprocess
import sys
import termios
import time

STATE = "/tmp/cove/watchdog.json"
LOG = "/tmp/cove-watchdog.log"
CPU_SPIN = 50.0          # %cpu above this on two consecutive samples = spinning
OUTQ_MIN = 1             # any stuck bytes count; healthy idle sessions sit at 0
TIOCOUTQ = getattr(termios, "TIOCOUTQ", 0x40047473)  # _IOR('t',115,int), macOS


def log(msg):
    line = "%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1 << 20:
            os.rename(LOG, LOG + ".1")
        with open(LOG, "a") as f:
            f.write(line)
    except OSError:
        pass


def ps_snapshot():
    out = subprocess.run(
        ["/bin/ps", "-Ao", "pid=,ppid=,tty=,%cpu=,time=,command="],
        capture_output=True, text=True).stdout
    procs = {}
    for raw in out.splitlines():
        parts = raw.split(None, 5)
        if len(parts) < 6:
            continue
        pid, ppid, tty, cpu, cputime, command = parts
        try:
            procs[int(pid)] = {
                "ppid": int(ppid), "tty": tty, "cpu": float(cpu),
                "time": cputime, "cmd": command,
            }
        except ValueError:
            continue
    return procs


def session_token(cmd):
    for tok in cmd.split():
        if tok.startswith("cove-") and tok[5:].isdigit():
            return tok
    return ""


def classify(procs):
    """Split cove abduco processes into session masters and attach clients.

    The master is detached from any terminal (tty '??') and parents the shell
    subtree; a client is wired to the kitty pane's tty and has no children.
    """
    has_child = {p["ppid"] for p in procs.values()}
    masters, clients = {}, []
    for pid, p in procs.items():
        if "abduco" not in p["cmd"]:
            continue
        sess = session_token(p["cmd"])
        if not sess:
            continue
        if p["tty"] == "??" and pid in has_child:
            masters[sess] = pid
        elif p["tty"] != "??":
            clients.append((pid, sess))
    return masters, clients


def shell_tty(procs, master_pid):
    for pid, p in procs.items():
        if p["ppid"] == master_pid and p["tty"] != "??":
            t = p["tty"]  # `ps -o tty=` gives 'ttys010'; `ps aux` style is 's010'
            return "/dev/" + (t if t.startswith("tty") else "tty" + t)
    return ""


def outq_bytes(tty_path):
    try:
        fd = os.open(tty_path, os.O_RDWR | os.O_NONBLOCK | os.O_NOCTTY)
    except OSError:
        return -1
    try:
        return struct.unpack("i", fcntl.ioctl(fd, TIOCOUTQ, b"\0\0\0\0"))[0]
    except OSError:
        return -1
    finally:
        os.close(fd)


def flush_and_repaint(tty_path, pids):
    fd = os.open(tty_path, os.O_RDWR | os.O_NONBLOCK | os.O_NOCTTY)
    try:
        termios.tcflush(fd, termios.TCIOFLUSH)
    finally:
        os.close(fd)
    # tcgetpgrp only works on one's own controlling terminal, so signal the
    # session's processes directly; SIGWINCH is a no-op for anything that
    # isn't a TUI waiting to repaint.
    for pid in pids:
        try:
            os.kill(pid, signal.SIGWINCH)
        except ProcessLookupError:
            pass


def respawn_window(sess):
    kitten = os.environ.get("COVE_KITTEN", "")
    sock = os.environ.get("COVE_KITTY_SOCKET", "unix:/tmp/cove-kitty")
    abduco = "/opt/homebrew/bin/abduco"
    shell = os.environ.get("SHELL", "/bin/zsh")
    if not kitten or not os.path.exists(kitten):
        log("respawn %s skipped: no kitten (COVE_KITTEN=%r)" % (sess, kitten))
        return
    subprocess.run(
        [kitten, "@", "--to", sock, "launch", "--type=os-window",
         abduco, "-A", sess, shell],
        capture_output=True, timeout=10)
    log("respawned window for %s" % sess)


def main():
    procs = ps_snapshot()
    masters, clients = classify(procs)

    try:
        with open(STATE) as f:
            prev = json.load(f)
    except (OSError, ValueError):
        prev = {}

    state = {"clients": {}, "masters": {}}

    # 1. Spinning attach clients.
    for pid, sess in clients:
        cpu = procs[pid]["cpu"]
        key = "%d:%s" % (pid, sess)
        if cpu >= CPU_SPIN:
            if prev.get("clients", {}).get(key):
                log("client %d (%s) spinning at %.0f%% cpu on two samples: "
                    "killing + reattaching" % (pid, sess, cpu))
                try:
                    os.kill(pid, signal.SIGTERM)
                    time.sleep(0.5)
                    os.kill(pid, 0)          # still alive -> escalate
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                if sess in masters:
                    time.sleep(0.5)
                    respawn_window(sess)
            else:
                state["clients"][key] = True

    # 2. Deadlocked session ptys.
    for sess, mpid in masters.items():
        tty = shell_tty(procs, mpid)
        if not tty:
            continue
        outq = outq_bytes(tty)
        if outq < OUTQ_MIN:
            continue
        sig = {"outq": outq, "mtime": procs[mpid]["time"]}
        prev_sig = prev.get("masters", {}).get(sess)
        if prev_sig == sig:
            log("session %s wedged (outq=%d frozen, master %d idle): "
                "flushing pty %s" % (sess, outq, mpid, tty))
            tty_short = tty[len("/dev/tty"):]
            on_tty = [p for p, v in procs.items() if v["tty"].endswith(tty_short)]
            try:
                flush_and_repaint(tty, on_tty)
            except OSError as e:
                log("flush of %s failed: %s" % (tty, e))
        else:
            state["masters"][sess] = sig

    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "w") as f:
        json.dump(state, f)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:                                    # noqa: BLE001
        log("watchdog error: %r" % e)
        sys.exit(1)
