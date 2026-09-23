#!/usr/bin/env python3
"""cove-quick -- "new termling" from the Cmd+F bar, in one line.

  cove_quick.py <token> "new claude part of vibefox for the tab-group bug"

The Cove has already spawned (and is following) a fresh shell termling by the
time this runs; we only decide what it should become, and write the plan to
$KITTY_COVE_DIR/quick-<token>.json for Godot to apply:

  {"token", "name", "zone": <existing frame id> | "",
   "new_frame": {"title", "x", "y", "w", "h", "from": <project box id> | ""} | null,
   "cwd", "agent", "line": <shell line to type, or "">, "why", "source"}

The termling is the user's own (no lineage, no owner): it's a faster Cmd+N,
not an agent's child. Like cove_find, the brain is a direct Anthropic API call
with a cheap model and a prefilled "{" (~1s); with no key it falls back to a
local guess (claude, no frame).
"""
import sys, os, json, re, shlex, urllib.request, urllib.error

import cove_mcp   # board geometry (find_space), state/board readers

DIR = cove_mcp.DIR
MODEL = os.environ.get("COVE_QUICK_MODEL", "claude-haiku-4-5")
API_URL = "https://api.anthropic.com/v1/messages"
CODE = os.path.expanduser("~/Documents/code")
AGENTS = {"claude": "claude", "codex": "codex", "opencode": "opencode", "shell": ""}

PROMPT = """The user typed a one-line request into their terminal board's launcher \
to open a new terminal ("termling"). Decide what it becomes.

Request: {query}
{chat}
The board has frames (titled boxes grouping termlings). Each frame lists the \
termlings in it with their working directory and agent:
{frames}

Termlings in no frame: {loose}
The one the user has focused: {focused}
Frame under the user's current view: {here}
Project folders in ~/Documents/code: {dirs}

Decide:
- agent: "claude" unless they name another (codex, opencode) or ask for a plain \
shell/terminal ("shell").
- frame: where it goes. The user's layout: project boxes (e.g. "Cove \
development") with arrows out to one box per topic, and each topic box holds the \
termlings working on it. So "part of X" / "under X" / "for X" where X is a project \
box (it has "arrows_to") -> a NEW topic box linked from it: \
{{"new": "<title>", "from": <X's id>}}. "in X" / "join X" / X is a topic box that \
already fits the request -> {{"id": <X's id>}}. Match frames by meaning, not \
spelling. Nothing named -> {{"new": "<title>"}} on its own, or "from" the project \
box whose topics share the request's folder/subject if one clearly fits. The title \
is a short topic in the user's words, sentence case, no quotes. "here"/"this" means \
the frame under their view. null only if they say loose / no box.
- name: short termling name (2-5 words), usually the topic.
- cwd: absolute directory to start in. Prefer the directory the termlings in the \
chosen/related frame use; else a project folder the request names; else null.
- prompt: a task to hand the agent ONLY if they spell one out as an instruction \
("... and fix X", "to review PR 12", "tell it: ..."). A topic ("for the zoom lag") \
is just the name, not a prompt. Otherwise null.

{ask_rule}
Respond with ONLY a JSON object:
{{"agent": "...", "frame": {{"id": "..."}} | {{"new": "...", "from": "<id>"|null}} | null, "name": "...", "cwd": "..." | null, \
"prompt": "..." | null, "why": "<max 12 words>"}}"""


def _board_context():
    st = cove_mcp.read_state()
    terms = st.get("terminals", [])
    zones = st.get("zones", []) or []
    by_zone = {}
    loose = []
    for t in terms:
        rec = {"name": t.get("name") or "", "cwd": t.get("cwd") or "",
               "agent": t.get("agent") or "shell"}
        if t.get("container"):
            by_zone.setdefault(t["container"], []).append(rec)
        else:
            loose.append(rec)
    names = {z["id"]: z.get("name") or "" for z in zones}
    arrows = {}
    for sh in cove_mcp.read_board().get("shapes", []):
        a, b = sh.get("bind_a"), sh.get("bind_b")
        if sh.get("type") == "arrow" and a in names and b in names:
            arrows.setdefault(a, []).append(names[b])
    frames = []
    for z in zones:
        f = {"id": z["id"], "title": names[z["id"]], "termlings": by_zone.get(z["id"], [])}
        if z["id"] in arrows:
            f["arrows_to"] = arrows[z["id"]][:8]
        frames.append(f)
    focused = next((t for t in terms if t.get("id") == st.get("focused")), None)
    v = st.get("view") or [0, 0, 0, 0]
    cx, cy = v[0] + v[2] / 2.0, v[1] + v[3] / 2.0
    here = None
    for z in zones:   # the smallest frame under the view centre
        r = z.get("rect") or [0, 0, 0, 0]
        if r[0] <= cx <= r[0] + r[2] and r[1] <= cy <= r[1] + r[3]:
            if here is None or r[2] * r[3] < here["rect"][2] * here["rect"][3]:
                here = z
    try:
        dirs = sorted(d for d in os.listdir(CODE)
                      if not d.startswith(".") and os.path.isdir(os.path.join(CODE, d)))
    except OSError:
        dirs = []
    return {
        "frames": frames, "loose": loose[:30], "zones": {z["id"]: z for z in zones},
        "focused": ({"name": focused.get("name"), "cwd": focused.get("cwd"),
                     "frame": focused.get("container")} if focused else None),
        "here": ({"id": here["id"], "title": here.get("name")} if here else None),
        "view_centre": [cx, cy], "dirs": dirs,
    }


ASK_RULE = """If you genuinely can't tell where it goes (two or more boxes fit equally \
well and nothing in the request or board picks one), don't guess: the user will \
point at the box themselves. Reply {{"ask": "<question, max 10 words>", "options": \
["<box title>", ...up to 4], "name": "<termling name>"}}. Otherwise decide.
"""
NO_ASK = "Do not ask anything: decide now, using your best guess.\n"


def _chat_text(chat):
    if not chat:
        return ""
    lines = ["You asked the user questions; their answers (the latest wins):"]
    for turn in chat:
        lines.append("- you: %s\n  user: %s" % (turn.get("q", ""), turn.get("a", "")))
    return "\n".join(lines) + "\n"


def _ask(query, ctx, chat=(), allow_ask=True):
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return None, "no ANTHROPIC_API_KEY"
    prompt = PROMPT.format(
        query=query, chat=_chat_text(chat), ask_rule=ASK_RULE if allow_ask else NO_ASK,
        frames=json.dumps(ctx["frames"]), loose=json.dumps(ctx["loose"]),
        focused=json.dumps(ctx["focused"]), here=json.dumps(ctx["here"]),
        dirs=", ".join(ctx["dirs"]))
    body = json.dumps({"model": MODEL, "max_tokens": 400, "messages": [
        {"role": "user", "content": prompt},
        {"role": "assistant", "content": "{"}]}).encode()
    req = urllib.request.Request(API_URL, data=body, method="POST", headers={
        "x-api-key": key, "anthropic-version": "2023-06-01",
        "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        return None, "api %d: %s" % (e.code, e.read().decode()[:200])
    except Exception as e:
        return None, "api call failed: %s" % e
    text = "".join(b.get("text", "") for b in data.get("content", []) if b.get("type") == "text")
    import cove_find
    obj = cove_find._extract_json("{" + text)
    return (obj, None) if isinstance(obj, dict) else (None, "could not parse model output")


def _guess(query):
    """No API: pick the agent from the words, nothing else."""
    q = query.lower()
    agent = next((a for a in ("codex", "opencode") if a in q), None)
    if agent is None:
        agent = "shell" if re.search(r"\b(plain shell|just a shell|shell|zsh)\b", q) else "claude"
    return {"agent": agent, "frame": None, "name": "", "cwd": None, "prompt": None,
            "why": "offline guess"}


def plan(token, query, chat=(), allow_ask=True, force_zone="", force_from=""):
    ctx = _board_context()
    chat = list(chat)
    for sid, how in ((force_zone, "in the box"), (force_from, "under the project box")):
        if sid in ctx["zones"]:
            chat.append({"q": "Where does it go?", "a": 'I put it %s "%s" (id %s).'
                         % (how, ctx["zones"][sid].get("name") or "", sid)})
    obj, err = _ask(query, ctx, chat, allow_ask) if query.strip() else (None, "empty")
    source = "claude"
    if obj is None:
        obj, source = _guess(query), "fallback"
    if allow_ask and query.rstrip().endswith("?") and not obj.get("ask"):
        obj["ask"] = "(you asked to pick)"   # a trailing "?": the user points at the box
    if allow_ask and isinstance(obj.get("ask"), str) and obj["ask"].strip():
        opts = [str(o)[:60] for o in (obj.get("options") or []) if str(o).strip()][:4]
        return {"token": token, "query": query, "source": source, "ask": obj["ask"].strip(),
                "options": opts, "name": str(obj.get("name") or "")[:60]}
    out = {"token": token, "query": query, "source": source, "error": err,
           "name": str(obj.get("name") or "")[:60], "why": str(obj.get("why") or ""),
           "zone": "", "new_frame": None, "cwd": None, "line": ""}
    agent = str(obj.get("agent") or "claude").lower()
    agent = agent if agent in AGENTS else "claude"
    named = _guess(query)["agent"]
    if named != "claude":
        agent = named   # an agent the user names outright beats the model's pick
    out["agent"] = agent

    fr = obj.get("frame")
    if force_zone:   # the user pointed at the box
        fr = {"id": force_zone}
    elif force_from:   # ...or at a project box: a new topic box hangs off it
        title = fr.get("new") if isinstance(fr, dict) and fr.get("new") else out["name"]
        fr = {"new": title or "New termling", "from": force_from}
    if isinstance(fr, dict) and fr.get("id") in ctx["zones"]:
        out["zone"] = fr["id"]
    else:
        # Every quick termling gets a box unless they asked for it loose: a loose
        # one wanders off, and a box is the whole point.
        if not (isinstance(fr, dict) and fr.get("new")):
            if re.search(r"\b(loose|no box|no frame|unboxed)\b", query.lower()):
                fr = None
            else:
                rest = re.sub(r"^\s*(\+|new|spawn)\s*", "", query, flags=re.I).strip()
                fr = {"new": out["name"] or rest[:40] or "New termling"}
    if isinstance(fr, dict) and fr.get("new") and not out["zone"]:
        # A box sized for one termling, in free space beside the project box it
        # hangs off (arrow from there), else where the user is looking.
        w, h = 600.0, 420.0
        src = fr.get("from") if fr.get("from") in ctx["zones"] else None
        try:
            spot = cove_mcp.find_space(w, h, near=src or ctx["view_centre"])
        except ValueError:
            c = ctx["view_centre"]
            spot = {"x": c[0] - w / 2, "y": c[1] - h / 2}
        out["new_frame"] = {"title": str(fr["new"])[:80], "x": spot["x"], "y": spot["y"],
                            "w": w, "h": h, "from": src or ""}

    cwd = obj.get("cwd")
    if isinstance(cwd, str) and cwd:
        cwd = os.path.expanduser(cwd)
        if not os.path.isabs(cwd):
            cwd = os.path.join(CODE, cwd)
        if os.path.isdir(cwd):
            out["cwd"] = cwd

    if force_zone:
        # the folder the box's termlings work in beats the model's guess
        cwds = [f["cwd"] for fr_ in ctx["frames"] if fr_["id"] == force_zone
                for f in fr_["termlings"] if f.get("cwd") and os.path.isdir(f["cwd"])]
        if cwds:
            out["cwd"] = max(set(cwds), key=cwds.count)

    parts = []
    if out["cwd"]:
        parts.append("cd " + shlex.quote(out["cwd"]))
    cmd = AGENTS[agent]
    if cmd:
        p = obj.get("prompt")
        if isinstance(p, str) and p.strip():
            os.makedirs(os.path.join(DIR, "prompts"), exist_ok=True)
            pf = os.path.join(DIR, "prompts", "quick-%s.md" % token)
            with open(pf, "w") as f:
                f.write(p.strip())
            cmd += ' "$(cat %s)"' % shlex.quote(pf)
            out["prompt"] = p.strip()
        parts.append(cmd)
    out["line"] = " && ".join(parts)
    return out


def _log(res):
    try:
        with open(os.path.join(DIR, "quick.log"), "a") as f:
            f.write(json.dumps(res) + "\n")
    except OSError:
        pass


def main(argv):
    chat, allow_ask = [], True
    force = {"--zone": "", "--from": ""}
    for flag in force:
        if flag in argv:
            i = argv.index(flag)
            force[flag] = argv[i + 1] if i + 1 < len(argv) else ""
            argv = argv[:i] + argv[i + 2:]
    if "--no-ask" in argv:
        argv = [a for a in argv if a != "--no-ask"]
        allow_ask = False
    if "--chat" in argv:
        i = argv.index("--chat")
        try:
            with open(argv[i + 1]) as f:
                chat = json.load(f)
        except (OSError, ValueError, IndexError):
            chat = []
        argv = argv[:i] + argv[i + 2:]
        allow_ask = allow_ask and len(chat) < 3   # three questions is plenty
    if len(argv) < 1:
        print("usage: cove_quick.py [--no-ask] [--chat file] [--zone id | --from id] <token> <request...>",
              file=sys.stderr)
        return 2
    token, query = argv[0], " ".join(argv[1:])
    try:
        res = plan(token, query, chat, allow_ask, force["--zone"], force["--from"])
    except Exception as e:   # never leave the Cove waiting: a bare claude is still useful
        res = {"token": token, "query": query, "source": "error", "error": str(e),
               "name": "", "zone": "", "new_frame": None, "cwd": None,
               "agent": "claude", "line": "claude", "why": ""}
    path = os.path.join(DIR, "quick-%s.json" % token)
    with open(path + ".tmp", "w") as f:
        json.dump(res, f)
    os.replace(path + ".tmp", path)
    _log(res)
    print(json.dumps(res))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
