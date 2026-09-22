#!/usr/bin/env python3
"""Changed-file and touched-file scans for the Cove's folder views.

    cove_files.py changes <out.json> <root>
    cove_files.py touched <out.json> <agent> <pid> <cwd>   (see touched() below)

Writes {"ok", "root", "top", "files": {abs path: {"st", "mtime"}}} to out.json
(atomically: a temp file renamed into place, so Cove never reads half of it).
"st" is the git porcelain status ("M", "A", "D", "R", "??", ...) or "recent"
for a file under root modified in the last RECENT_S seconds that git doesn't
report (outside a repo, or ignored-by-nothing churn). Cove polls for the file,
reads it and deletes it, the same way it does cove_calendar.py's output.
"""
import json
import os
import subprocess
import sys
import time

RECENT_S = 2 * 3600
MAX_WALK = 4000          # files stat'ed in the recent-mtime walk
MAX_DEPTH = 5
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__", "target", "build",
             "dist", ".godot", ".cache", ".next", ".tox", ".mypy_cache"}


def git(root, *args):
    try:
        p = subprocess.run(["git", "-C", root, *args], capture_output=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout if p.returncode == 0 else None


def git_changes(root):
    top = git(root, "rev-parse", "--show-toplevel")
    if top is None:
        return "", {}
    top = top.decode().strip()
    out = git(root, "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--", ".")
    files = {}
    if out is None:
        return top, files
    parts = out.decode("utf-8", "replace").split("\0")
    i = 0
    while i < len(parts):
        e = parts[i]
        i += 1
        if len(e) < 4:
            continue
        st = e[:2].strip() or "M"
        path = e[3:]
        if st.startswith("R") or st.startswith("C"):
            i += 1   # the rename source follows as its own field
        full = os.path.join(top, path)
        if full.endswith("/"):   # an untracked directory: mark the dir itself
            full = full[:-1]
        try:
            mt = os.stat(full).st_mtime
        except OSError:
            mt = 0
        files[full] = {"st": st, "mtime": mt}
    return top, files


def recent(root, files):
    now = time.time()
    seen = 0
    base = root.rstrip("/").count("/")
    for d, dirs, names in os.walk(root):
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS and not x.startswith(".")]
        if d.count("/") - base >= MAX_DEPTH:
            dirs[:] = []
        for n in names:
            seen += 1
            if seen > MAX_WALK:
                return
            p = os.path.join(d, n)
            if p in files:
                continue
            try:
                mt = os.stat(p).st_mtime
            except OSError:
                continue
            if now - mt < RECENT_S:
                files[p] = {"st": "recent", "mtime": mt}


# --- touched: the files an agent has been reading and editing ------------------
#
#     cove_files.py touched <out.json> <agent> <pid> <cwd>
#
# Writes {"ok", "agent", "source", "files": {abs path: {"op", "t", "n"}}}: op is
# "edit" if the agent ever wrote it, else "read"; t is the last touch (unix s).
# It reads the agent's own transcript, found from its pid:
#   claude   ~/.claude/sessions/<pid>.json -> sessionId -> ~/.claude/projects/*/<id>.jsonl
#            (plus that session's subagent transcripts)
#   codex    the rollout-*.jsonl the process has open, else the newest rollout for cwd
#   opencode the newest session for cwd in ~/.local/share/opencode/opencode.db
# Every tool call's input is mined the same way: explicit path fields, patch
# headers, and any path-looking token in commands that exists on disk.

import glob
import re
import sqlite3
from datetime import datetime

TAIL_BYTES = 6 * 1024 * 1024
KEEP = 300
PATH_KEYS = ("file_path", "filePath", "filepath", "notebook_path", "path", "target_file", "file")
EDIT_TOOLS = {"edit", "write", "multiedit", "notebookedit", "apply_patch", "patch", "create", "str_replace",
              "str_replace_based_edit_tool", "write_file", "edit_file"}
PATCH_RE = re.compile(r"\*\*\* (Update|Add|Delete) File: (\S[^\n\\\"]*)")
TOKEN_RE = re.compile(r"(?:~|\.{0,2}/)?[\w@+\-.]*(?:/[\w@+\-.]+)*\.[A-Za-z0-9_]{1,10}|/(?:[\w@+\-.]+/)+[\w@+\-.]+")
WRITE_CMD_RE = re.compile(r"(?:>>?\s*|sed\s+-i\S*\s+(?:'[^']*'|\"[^\"]*\"|\S+)\s+|tee\s+(?:-a\s+)?)(\S+)")


def _tail_lines(path):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - TAIL_BYTES))
            data = f.read()
    except OSError:
        return []
    lines = data.split(b"\n")
    if size > TAIL_BYTES:
        lines = lines[1:]   # the first one is cut
    return lines


def _ts(s):
    if isinstance(s, (int, float)):
        return s / 1000.0 if s > 1e11 else float(s)
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


class Touches:
    def __init__(self, cwd):
        self.cwd = cwd
        self.files = {}

    def add(self, path, op, t, base=None):
        if not path or len(path) > 1024:
            return
        path = path.strip().strip("'\"`,;:()[]{}")
        if path.startswith("~"):
            path = os.path.expanduser(path)
        if not os.path.isabs(path):
            path = os.path.join(base or self.cwd, path)
        path = os.path.normpath(path)
        if not os.path.isfile(path):
            return
        e = self.files.setdefault(path, {"op": "read", "t": 0.0, "n": 0})
        if op == "edit":
            e["op"] = "edit"
        e["t"] = max(e["t"], t)
        e["n"] += 1

    def scan_text(self, text, t, base=None, edit=False):
        if not isinstance(text, str) or not text:
            return
        for m in PATCH_RE.finditer(text):
            self.add(m.group(2), "edit", t, base)
        writes = {m.group(1).strip("'\"") for m in WRITE_CMD_RE.finditer(text)}
        for tok in TOKEN_RE.findall(text):
            tok = tok.strip("'\"")
            self.add(tok, "edit" if edit or tok in writes else "read", t, base)

    def call(self, name, inp, t):
        name = str(name or "").lower()
        edit = name in EDIT_TOOLS or name.endswith("__edit") or name.endswith("__write")
        if isinstance(inp, str):
            try:
                inp = json.loads(inp)
            except ValueError:
                self.scan_text(inp, t, edit=edit)
                return
        if not isinstance(inp, dict):
            return
        base = inp.get("workdir") or inp.get("cwd")
        base = base if isinstance(base, str) and os.path.isabs(base) else None
        for k in PATH_KEYS:
            v = inp.get(k)
            if isinstance(v, str):
                self.add(v, "edit" if edit else "read", t, base)
        for k, v in inp.items():
            if k in PATH_KEYS:
                continue
            if isinstance(v, list):
                v = " ".join(str(x) for x in v)
            if isinstance(v, str) and k not in ("content", "old_string", "new_string", "description", "prompt"):
                self.scan_text(v, t, base, edit and k in ("input", "patch"))


def _claude(pid, touches):
    try:
        with open(os.path.expanduser("~/.claude/sessions/%d.json" % pid)) as f:
            sid = json.load(f).get("sessionId", "")
    except (OSError, ValueError):
        return ""
    if not sid:
        return ""
    paths = glob.glob(os.path.expanduser("~/.claude/projects/*/%s.jsonl" % sid))
    paths += glob.glob(os.path.expanduser("~/.claude/projects/*/%s/subagents/*.jsonl" % sid))
    for p in paths:
        for raw in _tail_lines(p):
            if b'"tool_use"' not in raw:
                continue
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            t = _ts(d.get("timestamp", 0))
            for c in (d.get("message") or {}).get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    touches.call(c.get("name"), c.get("input"), t)
    return paths[0] if paths else ""


def _proc_start(pid):
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=2).stdout
        return datetime.strptime(out.strip(), "%a %b %d %H:%M:%S %Y").timestamp()
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 0.0


def _codex(pid, cwd, touches):
    path = ""
    try:
        out = subprocess.run(["lsof", "-p", str(pid), "-Fn"], capture_output=True, text=True, timeout=3).stdout
        for line in out.splitlines():
            if line.startswith("n") and "/rollout-" in line and line.endswith(".jsonl"):
                path = line[1:]
    except (OSError, subprocess.TimeoutExpired):
        pass
    if not path:
        start = _proc_start(pid)
        best = 0.0
        for p in glob.glob(os.path.expanduser("~/.codex/sessions/*/*/*/rollout-*.jsonl")):
            try:
                mt = os.stat(p).st_mtime
            except OSError:
                continue
            if mt < start or mt <= best:
                continue
            try:
                with open(p) as f:
                    meta = json.loads(f.readline())
            except (OSError, ValueError):
                continue
            if (meta.get("payload") or {}).get("cwd") == cwd:
                path, best = p, mt
    if not path:
        return ""
    for raw in _tail_lines(path):
        if b'"response_item"' not in raw and b'"event_msg"' not in raw:
            continue
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        p = d.get("payload") or {}
        t = _ts(d.get("timestamp", 0))
        kind = p.get("type")
        if kind == "function_call":
            touches.call(p.get("name"), p.get("arguments"), t)
        elif kind == "custom_tool_call":
            touches.call(p.get("name"), {"input": p.get("input", "")}, t)
        elif kind == "local_shell_call":
            touches.call("shell", (p.get("action") or {}), t)
        elif kind == "patch_apply_begin":
            for f in (p.get("changes") or {}):
                touches.add(f, "edit", t)
    return path


def _opencode(cwd, touches):
    db = os.path.expanduser("~/.local/share/opencode/opencode.db")
    if not os.path.exists(db):
        return ""
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=2)
        row = con.execute("select id from session where directory = ? order by time_updated desc limit 1",
                          (cwd,)).fetchone()
        if not row:
            return ""
        for created, data in con.execute(
                "select time_created, data from part where session_id = ? and data like '%\"type\":\"tool\"%' "
                "order by time_created desc limit 2000", (row[0],)):
            try:
                d = json.loads(data)
            except ValueError:
                continue
            touches.call(d.get("tool"), (d.get("state") or {}).get("input") or {}, _ts(created))
        con.close()
        return "opencode:" + row[0]
    except sqlite3.Error:
        return ""


def touched(out, agent, pid, cwd):
    touches = Touches(cwd)
    src = ""
    if agent == "claude":
        src = _claude(pid, touches)
    elif agent == "codex":
        src = _codex(pid, cwd, touches)
    elif agent == "opencode":
        src = _opencode(cwd, touches)
    files = dict(sorted(touches.files.items(), key=lambda kv: -kv[1]["t"])[:KEEP])
    return {"ok": True, "agent": agent, "source": src, "files": files}


def _write(out, res):
    tmp = out + ".tmp"
    with open(tmp, "w") as f:
        json.dump(res, f)
    os.replace(tmp, out)


def main():
    if len(sys.argv) >= 6 and sys.argv[1] == "touched":
        out = sys.argv[2]
        try:
            res = touched(out, sys.argv[3], int(sys.argv[4]), sys.argv[5])
        except Exception as e:  # noqa: BLE001 - report, don't crash the poll
            res = {"ok": False, "error": str(e)}
        _write(out, res)
        return
    if len(sys.argv) < 4 or sys.argv[1] != "changes":
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    out, root = sys.argv[2], os.path.abspath(os.path.expanduser(sys.argv[3]))
    res = {"ok": True, "root": root, "top": "", "files": {}}
    try:
        top, files = git_changes(root)
        # Only what's under root (git reports repo-wide paths outside it too).
        pre = root.rstrip("/") + "/"
        files = {p: v for p, v in files.items() if p.startswith(pre) or p == root}
        if not top:
            recent(root, files)
        res["top"] = top
        res["files"] = files
    except Exception as e:  # noqa: BLE001 - report, don't crash the poll
        res = {"ok": False, "root": root, "error": str(e)}
    _write(out, res)


if __name__ == "__main__":
    main()
