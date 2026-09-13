#!/usr/bin/env python3
"""Cove MCP server (zero-dependency, stdio JSON-RPC).

What an agent may do in the Cove. The user owns space and attention: agents
never move termlings, change focus or drive the camera. An agent can read the
world, describe itself (name, status), put ITSELF into a frame on the board,
and keep its OWN notes, todos and arrows on the board. Everything is keyed on
the termling's abduco session ($COVE_SESSION, exported by cove-shell.sh), which
survives kitty restarts, unlike kitty window ids.

Reads $KITTY_COVE_DIR/state.json and board.json (written by Godot). Writes
commands.jsonl (board / assign / rename) and notify.jsonl (status), each line
tagged with a "req" id; Godot answers in replies.jsonl.

Register in ~/.claude.json under mcpServers, e.g.:
  "cove": {"command": "python3",
           "args": ["/Users/.../kitty/cove/mcp/cove_mcp.py"]}
"""
import sys, json, os, time, uuid
import cove_find  # sibling module: semantic terminal resolver

DIR = os.environ.get("KITTY_COVE_DIR", "/tmp/cove")
STATE = os.path.join(DIR, "state.json")
BOARD = os.path.join(DIR, "board.json")
CMDS = os.path.join(DIR, "commands.jsonl")
NOTIFY = os.path.join(DIR, "notify.jsonl")
REPLIES = os.path.join(DIR, "replies.jsonl")
REPLY_WAIT = 1.5   # seconds to wait for Godot to confirm a command

STATUSES = ["working", "needs_you", "blocked", "done"]
NOTE_TYPES = ["note", "todo", "text"]


def _load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def read_state():
    return _load(STATE, {"terminals": [], "camera": [0, 0, 1], "focused": -1})


def read_board():
    return _load(BOARD, {"shapes": []})


def my_session():
    return os.environ.get("COVE_SESSION", "")


def me():
    """This agent's own termling record: by session, else by kitty pane id."""
    terms = read_state().get("terminals", [])
    sess = my_session()
    if sess:
        for t in terms:
            if t.get("session") == sess:
                return t
    pane = os.environ.get("KITTY_WINDOW_ID", "")
    if pane.isdigit():
        for t in terms:
            if t.get("pane_id") == int(pane):
                return t
    return None


def require_me():
    t = me()
    if t is None:
        raise ValueError("not inside a Cove termling (no match for COVE_SESSION / "
                         "KITTY_WINDOW_ID in state.json; is the Cove running?)")
    return t


def _append(path, obj):
    os.makedirs(DIR, exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(obj) + "\n")


def _await_reply(req):
    deadline = time.time() + REPLY_WAIT
    while time.time() < deadline:
        try:
            with open(REPLIES) as f:
                for line in f:
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(r, dict) and r.get("req") == req:
                        return r
        except OSError:
            pass
        time.sleep(0.1)
    return None


def send(path, obj):
    """Queue a line for Godot and return its answer. A Cove build that doesn't
    write replies yet gets {"ok": true, "confirmed": false}."""
    req = uuid.uuid4().hex[:12]
    _append(path, dict(obj, req=req, session=my_session()))
    r = _await_reply(req)
    if r is None:
        return {"ok": True, "confirmed": False}
    if not r.get("ok", False):
        raise ValueError(r.get("error") or "the Cove rejected the command")
    return dict(r, confirmed=True)


def _shape(shape_id):
    for s in read_board().get("shapes", []):
        if s.get("id") == shape_id:
            return s
    return None


def require_own(shape_id):
    """Agents may only change shapes they created (owner == their session)."""
    sess = my_session()
    if not sess:
        raise ValueError("no COVE_SESSION: can't prove ownership of board shapes")
    s = _shape(shape_id)
    if s is None:
        # Just created and not mirrored to board.json yet: our ids carry our session.
        if str(shape_id).startswith(sess + "."):
            return
        raise ValueError("no shape %r on the board" % shape_id)
    if s.get("owner") != sess:
        raise ValueError("shape %r isn't yours; you can only change shapes you created" % shape_id)


def _frames():
    """Containers the user has on the board: [{id, name, type, rect}]."""
    return read_state().get("zones", [])


def _endpoint(v, me_rec):
    """An arrow end: "me" -> my termling id, digits -> termling id, else a shape id."""
    if v in (None, "", "me"):
        return int(me_rec["id"])
    if isinstance(v, int) or str(v).isdigit():
        return int(v)
    return str(v)


TOOLS = [
    {"name": "whoami",
     "description": "Your own termling: id, session, name, frame (container), agent, position. Errors if you're not running inside the Cove.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "list_terminals",
     "description": "Every termling in the Cove: id, session, name, agent (claude/codex/opencode/shell), busy/attention, the frame it belongs to (container), cwd, project, title. Also the board's frames ('zones': id, name, rect). Read-only.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "board",
     "description": "Read the shapes on the Cove's board: the user's frames, boxes, text and arrows, plus agents' notes. mine=true returns only the shapes you own. Read-only.",
     "inputSchema": {"type": "object", "properties": {"mine": {"type": "boolean"}}}},
    {"name": "find",
     "description": "Find the termling(s) matching a natural-language description of what they're doing, e.g. 'the agent working on the auth refactor', 'the one running the tests'. Ranks termlings over their name, agent, title, project, last event and cwd. Returns {id, why, ranked:[{id,why}], source}. Doesn't change the user's focus.",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]}},
    {"name": "status",
     "description": "Tell the user how your work stands. needs_you, blocked and done put a '!' badge on your termling and queue you for the user's attention: focus jumps to you as soon as they're free, so you don't need to repeat it. working clears it. The Stop/Notification hooks already ping when you finish or wait for input; use this for anything more specific. summary: one short line.",
     "inputSchema": {"type": "object", "properties": {
         "state": {"type": "string", "enum": STATUSES}, "summary": {"type": "string"}},
         "required": ["state"]}},
    {"name": "rename",
     "description": "Name your own termling (shown on its nameplate), e.g. 'auth-refactor', 'tests'. Empty resets to the default. You can only name yourself.",
     "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}},
    {"name": "join_frame",
     "description": "Put your own termling into an existing frame on the board, by the frame's name or shape id (see list_terminals 'zones'). It walks over, stays inside, and moves when the frame moves. Only for yourself: the user arranges everyone else.",
     "inputSchema": {"type": "object", "properties": {"frame": {"type": "string"}}, "required": ["frame"]}},
    {"name": "leave_frame",
     "description": "Take your own termling out of its frame onto open ground.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "add_note",
     "description": "Put a note, todo list or text label on the board next to your termling, e.g. your plan as a todo list. You own it: only you (and the user) can change it. Returns its id for update_note/link/delete_notes.",
     "inputSchema": {"type": "object", "properties": {
         "type": {"type": "string", "enum": NOTE_TYPES},
         "text": {"type": "string"},
         "items": {"type": "array", "items": {"type": "string"}, "description": "todo items (type=todo)"},
         "color": {"type": "string"}},
         "required": ["type"]}},
    {"name": "update_note",
     "description": "Change one of your own board shapes: replace text/color/items, append add_items, or check/uncheck/remove a todo item (by index or text).",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "string"}, "text": {"type": "string"}, "color": {"type": "string"},
         "items": {"type": "array", "items": {"type": "string"}},
         "add_items": {"type": "array", "items": {"type": "string"}},
         "check": {}, "uncheck": {}, "remove": {}},
         "required": ["id"]}},
    {"name": "link",
     "description": "Draw an arrow from one of your own shapes (or 'me', your termling) to a termling (its id) or a board shape (its id). The arrow is yours.",
     "inputSchema": {"type": "object", "properties": {
         "from": {"type": "string"}, "to": {"type": "string"}, "text": {"type": "string"}},
         "required": ["to"]}},
    {"name": "delete_notes",
     "description": "Delete board shapes you own, by id.",
     "inputSchema": {"type": "object", "properties": {
         "ids": {"type": "array", "items": {"type": "string"}}}, "required": ["ids"]}},
]


def call_tool(name, args):
    if name == "whoami":
        t = me()
        return t if t else {"error": "not inside a Cove termling",
                            "session": my_session(), "pane": os.environ.get("KITTY_WINDOW_ID")}
    if name == "list_terminals":
        st = read_state()
        return {"terminals": st.get("terminals", []), "zones": st.get("zones", []),
                "you": (me() or {}).get("id")}
    if name == "board":
        shapes = read_board().get("shapes", [])
        if args.get("mine"):
            shapes = [s for s in shapes if s.get("owner") == my_session()]
        return {"shapes": shapes}
    if name == "find":
        return cove_find.find(args["query"])

    if name == "status":
        state = str(args["state"])
        if state not in STATUSES:
            raise ValueError("state must be one of " + ", ".join(STATUSES))
        t = require_me()
        cwd = str(t.get("cwd", ""))
        return send(NOTIFY, {"ts": int(time.time()), "pane": t.get("pane_id"), "event": state,
                             "summary": str(args.get("summary", "")), "cwd": cwd,
                             "project": os.path.basename(cwd)})
    if name == "rename":
        t = require_me()
        return send(CMDS, {"cmd": "rename", "id": t["id"], "name": str(args["name"])})
    if name == "join_frame":
        t = require_me()
        want = str(args["frame"])
        hit = next((z for z in _frames() if z.get("id") == want or z.get("name") == want), None)
        if hit is None:
            names = ["%s (%s)" % (z.get("name") or "unnamed", z.get("id")) for z in _frames()]
            raise ValueError("no frame %r on the board; frames (name (id)): %s" % (want, ", ".join(names)))
        return send(CMDS, {"cmd": "assign", "id": t["id"], "zone": hit.get("name") or hit.get("id")})
    if name == "leave_frame":
        t = require_me()
        return send(CMDS, {"cmd": "assign", "id": t["id"], "zone": ""})

    if name == "add_note":
        t = require_me()
        sess = my_session()
        if not sess:
            raise ValueError("no COVE_SESSION: board shapes need an owner")
        kind = str(args["type"])
        if kind not in NOTE_TYPES:
            raise ValueError("type must be one of " + ", ".join(NOTE_TYPES))
        sid = "%s.%s" % (sess, uuid.uuid4().hex[:6])
        cmd = {"cmd": "board", "op": "add", "type": kind, "id": sid, "near": t["id"], "owner": sess}
        for k in ("text", "items", "color"):
            if k in args:
                cmd[k] = args[k]
        return dict(send(CMDS, cmd), id=sid)
    if name == "update_note":
        require_own(args["id"])
        cmd = {"cmd": "board", "op": "update", "id": args["id"]}
        for k in ("text", "color", "items", "add_items", "check", "uncheck", "remove"):
            if k in args:
                cmd[k] = args[k]
        return send(CMDS, cmd)
    if name == "link":
        t = require_me()
        sess = my_session()
        src = args.get("from", "me")
        if src not in (None, "", "me"):
            require_own(src)
        sid = "%s.%s" % (sess or "agent", uuid.uuid4().hex[:6])
        cmd = {"cmd": "board", "op": "add", "type": "arrow", "id": sid, "owner": sess,
               "from": _endpoint(src, t), "to": _endpoint(args["to"], t)}
        if "text" in args:
            cmd["text"] = args["text"]
        return dict(send(CMDS, cmd), id=sid)
    if name == "delete_notes":
        ids = [str(i) for i in args["ids"]]
        for i in ids:
            require_own(i)
        return send(CMDS, {"cmd": "board", "op": "delete", "ids": ids})
    raise ValueError("unknown tool: " + str(name))


def reply(rid, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    sys.stdout.flush()


def reply_error(rid, code, msg):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": msg}}) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue
        method = req.get("method")
        rid = req.get("id")
        if method == "initialize":
            reply(rid, {"protocolVersion": "2024-11-05",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "cove", "version": "0.2.0"}})
        elif method == "tools/list":
            reply(rid, {"tools": TOOLS})
        elif method == "tools/call":
            params = req.get("params", {})
            try:
                result = call_tool(params.get("name"), params.get("arguments", {}) or {})
                reply(rid, {"content": [{"type": "text", "text": json.dumps(result)}]})
            except Exception as e:
                reply(rid, {"content": [{"type": "text", "text": "error: " + str(e)}], "isError": True})
        elif method and method.startswith("notifications/"):
            pass  # notifications get no response
        elif rid is not None:
            reply_error(rid, -32601, "method not found: " + str(method))


if __name__ == "__main__":
    main()
