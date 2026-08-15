#!/usr/bin/env python3
"""cove-find -- resolve a natural-language query to a cove terminal.

"the agent working on the auth refactor" -> the matching termling's id.

Reads the world state Godot publishes to $KITTY_COVE_DIR/state.json, ranks the
termlings against the query, and writes the ranked result to
$KITTY_COVE_DIR/find-result.json (which the in-app search overlay polls).

Ranking is semantic: we POST a compact table of the termlings (name, agent,
window title, project, last hook event, cwd) to the Anthropic API with a cheap
model and ask it to pick the best match. We use the API directly (not the
`claude` CLI) so the resolver stays fast (~1-2s), inherits no global config,
hooks, or MCP servers, and can never recurse back into the cove tools. Auth is
$ANTHROPIC_API_KEY, which the Cove process already has in its env. If the key is
missing or the call errors, we fall back to local fuzzy scoring so the search
still works offline.

Usage:
  cove_find.py "the one running the tests"          # rank, write result json
  cove_find.py --focus "the auth refactor agent"     # ...and focus the top hit
  cove_find.py --json "logs"                          # ...and print result json
"""
import sys, os, json, urllib.request, urllib.error

DIR = os.environ.get("KITTY_COVE_DIR", "/tmp/cove")
STATE = os.path.join(DIR, "state.json")
CMDS = os.path.join(DIR, "commands.jsonl")
RESULT = os.path.join(DIR, "find-result.json")

MODEL = os.environ.get("COVE_FIND_MODEL", "claude-haiku-4-5")
API_URL = "https://api.anthropic.com/v1/messages"


def read_terminals():
    try:
        with open(STATE) as f:
            return json.load(f).get("terminals", [])
    except Exception:
        return []


def _card(t):
    """The searchable fields for one termling, trimmed for the prompt."""
    return {
        "id": t.get("id"),
        "name": t.get("name") or "",
        "agent": t.get("agent") or "shell",
        "busy": bool(t.get("busy")),
        "attention": bool(t.get("attention")),
        "title": (t.get("title") or "")[:120],
        "project": (t.get("project") or "")[:80],
        "last_event": (t.get("last_event") or "")[:160],
        "cwd": t.get("cwd") or "",
    }


def fuzzy_rank(query, terms):
    """Cheap local fallback / instant filter: substring-word overlap scoring."""
    q = query.lower().strip()
    words = [w for w in q.split() if w]
    scored = []
    for t in terms:
        c = _card(t)
        hay = " ".join(str(c[k]).lower() for k in
                       ("name", "agent", "title", "project", "last_event", "cwd"))
        score = 0.0
        if q and q in hay:
            score += 5.0
        for w in words:
            if w in hay:
                score += 1.0
            # a hit in the name is worth more than one buried in the cwd
            if w in c["name"].lower():
                score += 2.0
        if score > 0:
            scored.append((score, c))
    scored.sort(key=lambda s: -s[0])
    return [{"id": c["id"], "why": "text match", "score": round(sc, 1)}
            for sc, c in scored]


PROMPT = """You are a resolver for a terminal-window search. Given a user query \
and a list of terminals ("termlings"), pick which termling(s) the user means.

Match on what each terminal is *doing*: its name, the agent running in it \
(claude/codex/opencode/shell), its window title, its project, its most recent \
event, and its working directory. The query is natural language, e.g. "the one \
debugging the wasm build" or "logs".

User query:
{query}

Termlings (JSON):
{cards}

Respond with ONLY a JSON object, no prose and no code fence:
{{"id": <best matching id, or null if nothing matches>,
  "why": "<short reason, max 12 words>",
  "ranked": [{{"id": <id>, "why": "<short reason>"}}, ...]}}
Order "ranked" best-first; include only plausible matches (omit the rest)."""


def _extract_json(text):
    """Parse a JSON object out of model text (assistant is prefilled with '{')."""
    text = text.strip()
    if not text.startswith("{"):
        i = text.find("{")
        text = text[i:] if i != -1 else "{" + text
    j = text.rfind("}")
    if j != -1:
        text = text[:j + 1]
    try:
        return json.loads(text)
    except Exception:
        return None


def semantic_rank(query, terms):
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return None, "no ANTHROPIC_API_KEY"
    cards = [_card(t) for t in terms]
    prompt = PROMPT.format(query=query, cards=json.dumps(cards, indent=2))
    body = json.dumps({
        "model": MODEL,
        "max_tokens": 400,
        "messages": [
            {"role": "user", "content": prompt},
            {"role": "assistant", "content": "{"},  # prefill -> forces bare JSON
        ],
    }).encode()
    req = urllib.request.Request(API_URL, data=body, method="POST", headers={
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        return None, "api %d: %s" % (e.code, e.read().decode()[:200])
    except Exception as e:
        return None, "api call failed: %s" % e
    parts = [b.get("text", "") for b in data.get("content", []) if b.get("type") == "text"]
    obj = _extract_json("{" + "".join(parts))  # re-attach the prefilled brace
    if obj is None:
        return None, "could not parse model output"
    return obj, None


def find(query, terms=None):
    """Return {"id", "why", "ranked", "source"} for a query. Never raises."""
    if terms is None:
        terms = read_terminals()
    valid = {t.get("id") for t in terms}
    obj, err = semantic_rank(query, terms) if terms else (None, "no terminals")
    if obj is not None:
        ranked = [r for r in obj.get("ranked", [])
                  if isinstance(r, dict) and r.get("id") in valid]
        top = obj.get("id")
        if top not in valid:
            top = ranked[0]["id"] if ranked else None
        return {"id": top, "why": obj.get("why", ""),
                "ranked": ranked, "source": "claude"}
    # fall back to local fuzzy scoring
    ranked = fuzzy_rank(query, terms)
    return {"id": ranked[0]["id"] if ranked else None,
            "why": ranked[0]["why"] if ranked else (err or "no match"),
            "ranked": ranked, "source": "fuzzy", "error": err}


def write_result(query, res):
    os.makedirs(DIR, exist_ok=True)
    tmp = RESULT + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"query": query, **res}, f)
    os.replace(tmp, RESULT)  # atomic, so the overlay never reads a half file


def focus(term_id):
    os.makedirs(DIR, exist_ok=True)
    with open(CMDS, "a") as f:
        f.write(json.dumps({"cmd": "focus", "id": int(term_id)}) + "\n")


def main(argv):
    do_focus = "--focus" in argv
    do_print = "--json" in argv
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        print("usage: cove_find.py [--focus] [--json] <query>", file=sys.stderr)
        return 2
    query = " ".join(args)
    res = find(query)
    write_result(query, res)
    if do_focus and res.get("id") is not None:
        focus(res["id"])
    if do_print or not do_focus:
        print(json.dumps(res))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
