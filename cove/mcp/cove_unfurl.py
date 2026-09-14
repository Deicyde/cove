#!/usr/bin/env python3
"""Unfurl a URL for a board bookmark card: title, description, preview image
and favicon, as tldraw does when you paste a link.

    cove_unfurl.py <url> <out.json> <assets-dir>

Writes <out.json> atomically; Godot polls for it. Images are fetched with curl,
converted to PNG with sips (Godot can't read ico/gif) and kept in <assets-dir>
under a hash of their source URL, so the board keeps them offline.

GitHub pull requests and issues also get their live state (open / draft /
merged / closed) from `gh api`, which works for private repos too. The Cove
re-runs this every few minutes for those, so a PR card on the board tracks its
PR.
"""
import sys, os, re, json, time, shutil, hashlib, subprocess, tempfile, html
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")
CURL = "/usr/bin/curl"
SIPS = "/usr/bin/sips"
GH_RE = re.compile(r"^https?://(?:www\.)?github\.com/([^/]+)/([^/]+)/(pull|issues)/(\d+)")


def curl(url, out=None, limit=4_000_000, timeout=12):
    args = [CURL, "-sSL", "--compressed", "--max-time", str(timeout), "--max-filesize", str(limit),
            "-A", UA, "-H", "Accept-Language: en-GB,en;q=0.9", "-w", "%{http_code}"]
    if out:
        args += ["-o", out]
    args.append(url)
    try:
        p = subprocess.run(args, capture_output=True, timeout=timeout + 3)
    except Exception:
        return None
    body = p.stdout
    code = body[-3:] if not out else body
    if not out:
        body = body[:-3]
    if p.returncode != 0 or not code.decode(errors="replace").startswith("2"):
        return None
    return True if out else body


class Head(HTMLParser):
    """Collects <meta>, <title> and <link rel=icon> from the head."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.meta, self.title, self.icons = {}, "", []
        self._in_title = False
        self.done = False

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or "") for k, v in attrs}
        if tag == "meta":
            key = (a.get("property") or a.get("name") or "").lower()
            if key and "content" in a and key not in self.meta:
                self.meta[key] = a["content"]
        elif tag == "title":
            self._in_title = True
        elif tag == "link" and "icon" in a.get("rel", "").lower() and a.get("href"):
            self.icons.append(a["href"])
        elif tag == "body":
            self.done = True

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        elif tag == "head":
            self.done = True

    def handle_data(self, data):
        if self._in_title and not self.title:
            self.title = data.strip()


def parse_head(raw):
    m = re.search(rb'<meta[^>]+charset=["\']?([\w-]+)', raw[:4096], re.I)
    enc = m.group(1).decode() if m else "utf-8"
    try:
        text = raw.decode(enc, errors="replace")
    except LookupError:
        text = raw.decode("utf-8", errors="replace")
    h = Head()
    # Feed in chunks and stop at the body: some pages are megabytes of script.
    for i in range(0, len(text), 32768):
        try:
            h.feed(text[i:i + 32768])
        except Exception:
            break
        if h.done:
            break
    return h


def clean(s, n):
    s = re.sub(r"\s+", " ", html.unescape(s or "")).strip()
    return s if len(s) <= n else s[:n - 1].rstrip() + "…"


def fetch_image(src, assets, max_px):
    """Download src, convert to PNG, return the local path (or "")."""
    if not src:
        return ""
    name = hashlib.sha1(src.encode()).hexdigest()[:20] + ".png"
    dest = os.path.join(assets, name)
    if os.path.exists(dest):
        return dest
    fd, tmp = tempfile.mkstemp(prefix="cove-unfurl-")
    os.close(fd)
    try:
        if not curl(src, out=tmp, limit=8_000_000):
            return ""
        part = dest + ".part.png"
        p = subprocess.run([SIPS, "-s", "format", "png", "-Z", str(max_px), tmp, "--out", part],
                           capture_output=True, timeout=20)
        if p.returncode != 0 or not os.path.exists(part):
            return ""
        os.replace(part, dest)
        return dest
    except Exception:
        return ""
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def gh_exe():
    for p in (shutil.which("gh"), "/opt/homebrew/bin/gh", "/usr/local/bin/gh",
              os.path.expanduser("~/.local/bin/gh")):
        if p and os.path.exists(p):
            return p
    return None


def github(owner, repo, kind, num):
    """State of a PR/issue via `gh api` (authenticated, so private repos work)."""
    gh = gh_exe()
    if not gh:
        return None
    path = "repos/%s/%s/%s/%s" % (owner, repo, "pulls" if kind == "pull" else "issues", num)
    try:
        p = subprocess.run([gh, "api", path], capture_output=True, timeout=15)
        d = json.loads(p.stdout) if p.returncode == 0 else None
    except Exception:
        d = None
    if not isinstance(d, dict) or "title" not in d:
        return None
    if kind == "pull":
        state = "merged" if d.get("merged_at") else ("draft" if d.get("draft") and d.get("state") == "open"
                                                      else d.get("state", ""))
    else:
        state = d.get("state", "")
        if state == "closed" and d.get("state_reason") == "not_planned":
            state = "not_planned"
    return {
        "kind": kind, "state": state, "number": int(num), "repo": "%s/%s" % (owner, repo),
        "title": d.get("title", ""), "body": d.get("body") or "",
        "author": (d.get("user") or {}).get("login", ""),
        "additions": d.get("additions"), "deletions": d.get("deletions"),
        "changed_files": d.get("changed_files"), "comments": d.get("comments"),
    }


def unfurl(url, assets):
    os.makedirs(assets, exist_ok=True)
    u = urlparse(url)
    host = (u.hostname or "").removeprefix("www.")
    out = {"url": url, "ok": False, "title": "", "description": "", "image": "", "favicon": "",
           "site": host or url, "fetched": int(time.time())}

    gh = None
    m = GH_RE.match(url)
    if m:
        gh = github(*m.groups())

    raw = curl(url)
    h = parse_head(raw) if raw else None
    if h:
        meta = h.meta
        out["title"] = clean(meta.get("og:title") or meta.get("twitter:title") or h.title, 300)
        out["description"] = clean(meta.get("og:description") or meta.get("twitter:description")
                                   or meta.get("description"), 400)
        img = meta.get("og:image") or meta.get("og:image:url") or meta.get("twitter:image") \
            or meta.get("twitter:image:src")
        if img:
            out["image"] = fetch_image(urljoin(url, html.unescape(img)), assets, 1200)
    if gh:
        out["github"] = {k: v for k, v in gh.items() if k not in ("title", "body")}
        out["title"] = clean(gh["title"], 300)
        if not out["description"]:
            body = re.sub(r"<!--.*?-->", " ", gh["body"], flags=re.S)
            out["description"] = clean(body, 400)
        out["site"] = "%s #%d" % (gh["repo"], gh["number"])
    if host:
        # Google's favicon service always answers with a PNG, unlike /favicon.ico.
        out["favicon"] = fetch_image("https://www.google.com/s2/favicons?sz=64&domain=" + host, assets, 64)
    out["ok"] = bool(out["title"] or out["image"] or gh)
    return out


def main():
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    url, out_path, assets = sys.argv[1:]
    try:
        res = unfurl(url, assets)
    except Exception as e:
        res = {"url": url, "ok": False, "error": str(e), "fetched": int(time.time())}
    tmp = out_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(res, f)
    os.replace(tmp, out_path)


if __name__ == "__main__":
    main()
