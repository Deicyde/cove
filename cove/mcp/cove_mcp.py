#!/usr/bin/env python3
"""Cove MCP server (zero-dependency, stdio JSON-RPC).

Lets an agent see and drive the Walking-Terminals cove. It reads the world
state Godot publishes to $KITTY_COVE_DIR/state.json and issues commands by
appending to $KITTY_COVE_DIR/commands.jsonl. Motion planning (avoiding other
terminals, staying nearby without overlapping) is handled by the engine; the
tools here are the primitives an agent composes into a plan.

Register in ~/.claude.json under mcpServers, e.g.:
  "cove": {"command": "python3",
                "args": ["/Users/.../kitty/cove/mcp/cove_mcp.py"]}
"""
import sys, json, os
import cove_find  # sibling module: semantic terminal resolver

DIR = os.environ.get("KITTY_COVE_DIR", "/tmp/cove")
STATE = os.path.join(DIR, "state.json")
CMDS = os.path.join(DIR, "commands.jsonl")


def read_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except Exception:
        return {"terminals": [], "camera": [0, 0, 1], "focused": -1}


def send_cmd(obj):
    os.makedirs(DIR, exist_ok=True)
    with open(CMDS, "a") as f:
        f.write(json.dumps(obj) + "\n")


def resolve(term_id):
    """Accept a cove terminal id OR a kitty pane id; return the term id."""
    tid = int(term_id)
    for t in read_state().get("terminals", []):
        if t.get("id") == tid or t.get("pane_id") == tid:
            return t.get("id")
    return tid


def my_terminal():
    pane = os.environ.get("KITTY_WINDOW_ID")
    if pane is None:
        return None
    pane = int(pane)
    for t in read_state().get("terminals", []):
        if t.get("pane_id") == pane:
            return t
    return None


TOOLS = [
    {"name": "list_terminals",
     "description": "List all terminals in the cove with their id, pane_id, agent (claude/codex/opencode/shell), busy/attention flags, position [x,y], cols/rows, cwd, the zone each is in, and who they're following. Also returns the camera and the list of zones (named regions with their rects).",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "whoami",
     "description": "Which cove terminal is THIS agent running in (uses $KITTY_WINDOW_ID). Returns the terminal record or an error if not inside the cove.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "move",
     "description": "Send a terminal's carriers to a world position (x,y). id may be a terminal id or a kitty pane id. Cancels any follow. The engine avoids clipping other terminals en route.",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "integer"}, "x": {"type": "number"}, "y": {"type": "number"}},
         "required": ["id", "x", "y"]}},
    {"name": "follow",
     "description": "Make one terminal follow another, staying nearby (beside it) without overlapping. Both ids may be terminal or pane ids.",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "integer"}, "target": {"type": "integer"}},
         "required": ["id", "target"]}},
    {"name": "stop",
     "description": "Stop a terminal's follow/move and let it wander again.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}},
    {"name": "focus",
     "description": "Focus a terminal (so typing goes to it) and make the camera track it.",
     "inputSchema": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}},
    {"name": "rename",
     "description": "Give a terminal a name, shown on its nameplate (e.g. 'build', 'logs'). Empty name resets to 'terminal N'. id may be a terminal id or a kitty pane id; from inside a terminal, omit id to name your own.",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "integer"}, "name": {"type": "string"}},
         "required": ["name"]}},
    {"name": "find",
     "description": "Find the terminal(s) matching a natural-language description of what they're doing -- e.g. 'the agent working on the auth refactor', 'the one running the tests', 'logs'. Ranks termlings semantically over their name, agent, window title, project, last event and cwd. By default focuses the best match and makes the camera track it; pass focus=false to only return the ranking. Returns {id, why, ranked:[{id,why}], source}.",
     "inputSchema": {"type": "object", "properties": {
         "query": {"type": "string"}, "focus": {"type": "boolean"}},
         "required": ["query"]}},
    {"name": "gather",
     "description": "Call all terminals to cluster around the camera's current view.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "scatter",
     "description": "Release all terminals from follow/move so they wander freely. Also clears all zones and zone overrides.",
     "inputSchema": {"type": "object", "properties": {}}},
    {"name": "assign",
     "description": "Put a terminal into a named zone (a region on the ground), creating the zone if needed. The termling walks over and confines its wander to that region, so agents on the same project cluster together and location tells you who's working on what. Pass an empty zone to pin it on open ground instead. This overrides auto-zoning (which otherwise groups termlings by their git-repo/cwd) for that terminal. id may be a terminal or pane id.",
     "inputSchema": {"type": "object", "properties": {
         "id": {"type": "integer"}, "zone": {"type": "string"}},
         "required": ["id", "zone"]}},
    {"name": "autozone",
     "description": "Toggle automatic zoning, which clusters termlings into per-project regions by their git-repo/cwd with no commands. On by default. Turning it off keeps only zones set by hand (drag or assign).",
     "inputSchema": {"type": "object", "properties": {"on": {"type": "boolean"}},
         "required": ["on"]}},
]


def call_tool(name, args):
    if name == "list_terminals":
        return read_state()
    if name == "whoami":
        t = my_terminal()
        return t if t else {"error": "not inside a cove terminal", "pane": os.environ.get("KITTY_WINDOW_ID")}
    if name == "move":
        send_cmd({"cmd": "move", "id": resolve(args["id"]), "to": [args["x"], args["y"]]})
        return {"ok": True}
    if name == "follow":
        send_cmd({"cmd": "follow", "id": resolve(args["id"]), "target": resolve(args["target"])})
        return {"ok": True}
    if name == "stop":
        send_cmd({"cmd": "stop", "id": resolve(args["id"])})
        return {"ok": True}
    if name == "focus":
        send_cmd({"cmd": "focus", "id": resolve(args["id"])})
        return {"ok": True}
    if name == "rename":
        # From inside a terminal, id is optional -> rename self.
        tid = args.get("id")
        if tid is None:
            me = my_terminal()
            if not me:
                return {"error": "no id given and not inside a cove terminal"}
            tid = me["id"]
        send_cmd({"cmd": "rename", "id": resolve(tid), "name": str(args["name"])})
        return {"ok": True}
    if name == "find":
        res = cove_find.find(args["query"])
        if args.get("focus", True) and res.get("id") is not None:
            send_cmd({"cmd": "focus", "id": int(res["id"])})
            res["focused"] = int(res["id"])
        return res
    if name == "gather":
        send_cmd({"cmd": "gather"})
        return {"ok": True}
    if name == "scatter":
        send_cmd({"cmd": "scatter"})
        return {"ok": True}
    if name == "assign":
        send_cmd({"cmd": "assign", "id": resolve(args["id"]), "zone": str(args["zone"])})
        return {"ok": True}
    if name == "autozone":
        send_cmd({"cmd": "autozone", "on": bool(args["on"])})
        return {"ok": True}
    raise ValueError("unknown tool: " + name)


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
                        "serverInfo": {"name": "cove", "version": "0.1.0"}})
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
