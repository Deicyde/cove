#!/usr/bin/env python3
"""Calendar and task data for the Cove's board widgets.

    cove_calendar.py fetch <out.json> <start-date> <end-date>
    cove_calendar.py task <out.json> <op> <task-id> [text]
    cove_calendar.py google-auth <out.json> [--no-open]

Reads every source in ~/.config/cove/calendars.json and writes one normalised
JSON blob that Cove.gd polls for (same pattern as cove_unfurl.py). Sources:

  caldav   Nextcloud (or any CalDAV server). Recurrences are expanded by the
           server (RFC 4791 <C:expand>), so nothing here has to understand
           RRULE. Password comes from the macOS keychain.
  google   Google Calendar API v3, singleEvents=true. OAuth token lives in
           ~/.config/cove/google_token.json and is refreshed here.
  eventkit macOS Reminders, via the cove-reminders helper (cove/bin).

Stdlib only, so it starts fast and can't break on a missing wheel.
"""
import sys, os, re, json, time, base64, subprocess, tempfile, urllib.request, urllib.parse, urllib.error
import xml.etree.ElementTree as ET
from datetime import datetime, date, timedelta, timezone
from zoneinfo import ZoneInfo

CONFIG = os.path.expanduser("~/.config/cove/calendars.json")
HELPER_DIR = os.path.dirname(os.path.abspath(__file__))
REMINDERS_BIN = os.path.join(os.path.dirname(HELPER_DIR), "bin", "cove-reminders")
DAV_NS = {"d": "DAV:", "c": "urn:ietf:params:xml:ns:caldav",
          "ap": "http://apple.com/ns/ical/", "cs": "http://calendarserver.org/ns/"}
LOCAL = datetime.now().astimezone().tzinfo


# --- config -------------------------------------------------------------------

DEFAULT_CONFIG = {
    "sources": [
        {"id": "nc", "kind": "caldav", "enabled": True,
         "url": "https://calendar.kirancodes.me/remote.php/dav/calendars/kirang%40comp.nus.edu.sg/",
         "user": "kirang@comp.nus.edu.sg",
         "keychain": {"service": "cove-calendar", "account": "kirang@comp.nus.edu.sg"}},
        {"id": "g", "kind": "google", "enabled": True},
        {"id": "mac", "kind": "eventkit", "enabled": True, "events": False},
    ],
}


def load_config():
    try:
        with open(CONFIG) as f:
            cfg = json.load(f)
    except FileNotFoundError:
        os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
        tmp_write(CONFIG, json.dumps(DEFAULT_CONFIG, indent=2))
        cfg = DEFAULT_CONFIG
    except Exception as e:
        return {"sources": [], "error": "%s: %s" % (CONFIG, e)}
    return cfg


def tmp_write(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def keychain(service, account):
    try:
        p = subprocess.run(["/usr/bin/security", "find-generic-password",
                            "-s", service, "-a", account, "-w"],
                           capture_output=True, text=True, timeout=20)
    except Exception:
        return ""
    return p.stdout.strip() if p.returncode == 0 else ""


def source_password(src):
    if src.get("password"):
        return str(src["password"])
    if src.get("password_cmd"):
        try:
            p = subprocess.run(["/bin/sh", "-c", src["password_cmd"]],
                               capture_output=True, text=True, timeout=30)
            return p.stdout.strip()
        except Exception:
            return ""
    kc = src.get("keychain") or {}
    return keychain(kc.get("service", "cove-calendar"), kc.get("account", src.get("user", "")))


# --- time ---------------------------------------------------------------------

def as_local(dt):
    if isinstance(dt, date) and not isinstance(dt, datetime):
        return dt
    if dt.tzinfo is None:
        return dt.replace(tzinfo=LOCAL)
    return dt.astimezone(LOCAL)


def iso(dt):
    """Local wall-clock ISO, which is all the widget draws with."""
    if isinstance(dt, date) and not isinstance(dt, datetime):
        return dt.isoformat()
    return as_local(dt).strftime("%Y-%m-%dT%H:%M:%S")


def parse_day(s):
    return datetime.strptime(s[:10], "%Y-%m-%d").date()


def utcstamp(d):
    return d.strftime("%Y%m%dT%H%M%SZ")


# --- ICS ----------------------------------------------------------------------

def unfold(text):
    out = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line[:1] in (" ", "\t") and out:
            out[-1] += line[1:]
        else:
            out.append(line)
    return out


def ics_value(v):
    return (v.replace("\\n", "\n").replace("\\N", "\n").replace("\\,", ",")
             .replace("\\;", ";").replace("\\\\", "\\"))


def parse_ics(text):
    """[(component-name, {prop: (value, {param: value})})] for VEVENT/VTODO."""
    comps, stack = [], []
    for line in unfold(text):
        if not line.strip():
            continue
        name, _, rest = line.partition(":")
        key = name.split(";")[0].upper()
        if key == "BEGIN":
            stack.append([rest.strip().upper(), {}])
            continue
        if key == "END":
            if stack:
                comp = stack.pop()
                if comp[0] in ("VEVENT", "VTODO"):
                    comps.append(comp)
            continue
        if not stack:
            continue
        params = {}
        for part in name.split(";")[1:]:
            k, _, v = part.partition("=")
            params[k.upper()] = v.strip('"')
        # Repeated properties (EXDATE, CATEGORIES) keep the first; nothing here needs more.
        stack[-1][1].setdefault(key, (ics_value(rest), params))
    return comps


def ics_time(prop):
    if prop is None:
        return None
    raw, params = prop
    raw = raw.strip()
    if params.get("VALUE", "").upper() == "DATE" or (len(raw) == 8 and "T" not in raw):
        try:
            return datetime.strptime(raw, "%Y%m%d").date()
        except ValueError:
            return None
    tz = None
    if raw.endswith("Z"):
        raw, tz = raw[:-1], timezone.utc
    elif params.get("TZID"):
        try:
            tz = ZoneInfo(params["TZID"])
        except Exception:
            tz = None
    try:
        dt = datetime.strptime(raw, "%Y%m%dT%H%M%S")
    except ValueError:
        return None
    return dt.replace(tzinfo=tz) if tz else dt


def ics_duration(raw):
    m = re.match(r"^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$", raw.strip())
    if not m:
        return timedelta(0)
    sign = -1 if m.group(1) == "-" else 1
    w, d, h, mi, s = (int(x) if x else 0 for x in m.groups()[1:])
    return sign * timedelta(weeks=w, days=d, hours=h, minutes=mi, seconds=s)


def event_from_ics(comp, cal_id):
    props = comp[1]
    start = ics_time(props.get("DTSTART"))
    if start is None:
        return None
    end = ics_time(props.get("DTEND"))
    if end is None and "DURATION" in props:
        end = start + ics_duration(props["DURATION"][0])
    if end is None:
        end = start + (timedelta(days=1) if isinstance(start, date) and not isinstance(start, datetime)
                       else timedelta(hours=1))
    allday = isinstance(start, date) and not isinstance(start, datetime)
    uid = props.get("UID", ("", {}))[0]
    rid = props.get("RECURRENCE-ID")
    return {
        "id": "%s/%s/%s" % (cal_id, uid, iso(start)),
        "uid": uid,
        "cal": cal_id,
        "title": props.get("SUMMARY", ("(no title)", {}))[0],
        "start": iso(start),
        "end": iso(end),
        "allday": allday,
        "location": props.get("LOCATION", ("", {}))[0],
        "status": props.get("STATUS", ("", {}))[0].upper(),
        "recurring": bool(props.get("RRULE") or rid),
    }


def task_from_ics(comp, cal_id, href=""):
    props = comp[1]
    due = ics_time(props.get("DUE")) or ics_time(props.get("DTSTART"))
    status = props.get("STATUS", ("", {}))[0].upper()
    pct = props.get("PERCENT-COMPLETE", ("0", {}))[0]
    try:
        pct = int(pct)
    except ValueError:
        pct = 0
    prio = props.get("PRIORITY", ("0", {}))[0]
    try:
        prio = int(prio)
    except ValueError:
        prio = 0
    uid = props.get("UID", ("", {}))[0]
    return {
        "id": "%s/%s" % (cal_id, uid),
        "uid": uid,
        "cal": cal_id,
        "href": href,
        "title": props.get("SUMMARY", ("(no title)", {}))[0],
        "due": iso(due) if due is not None else "",
        "allday": bool(due is not None and isinstance(due, date) and not isinstance(due, datetime)),
        "done": status == "COMPLETED" or pct >= 100,
        "priority": prio,
        "notes": props.get("DESCRIPTION", ("", {}))[0],
        "completed": iso(ics_time(props.get("COMPLETED")) or ics_time(props.get("LAST-MODIFIED"))
                         or datetime(1970, 1, 1)),
    }


# --- CalDAV -------------------------------------------------------------------

class Dav:
    def __init__(self, url, user, password, timeout=25):
        self.url = url if url.endswith("/") else url + "/"
        self.auth = "Basic " + base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
        self.timeout = timeout

    def request(self, method, url, body=None, depth="1", ctype="application/xml; charset=utf-8"):
        req = urllib.request.Request(url, data=body.encode() if body else None, method=method)
        req.add_header("Authorization", self.auth)
        req.add_header("Content-Type", ctype)
        if depth is not None:
            req.add_header("Depth", depth)
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            return r.status, r.read()

    def calendars(self):
        body = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:ap="http://apple.com/ns/ical/">
  <d:prop>
    <d:displayname/><d:resourcetype/><c:supported-calendar-component-set/><ap:calendar-color/>
  </d:prop>
</d:propfind>"""
        _, raw = self.request("PROPFIND", self.url, body)
        out = []
        for resp in ET.fromstring(raw).findall("d:response", DAV_NS):
            href = resp.findtext("d:href", "", DAV_NS)
            if href.rstrip("/") == urllib.parse.urlparse(self.url).path.rstrip("/"):
                continue
            rt = resp.find(".//d:resourcetype", DAV_NS)
            if rt is None or rt.find("c:calendar", DAV_NS) is None:
                continue
            comps = [c.get("name") for c in resp.findall(".//c:comp", DAV_NS)]
            colour = (resp.findtext(".//ap:calendar-color", "", DAV_NS) or "").strip()
            out.append({
                "uid": urllib.parse.unquote(href.rstrip("/").rsplit("/", 1)[-1]),
                "name": resp.findtext(".//d:displayname", "", DAV_NS) or "",
                "color": colour[:7] if colour.startswith("#") else "",
                "href": urllib.parse.urljoin(self.url, href),
                "events": (not comps) or "VEVENT" in comps,
                "tasks": "VTODO" in comps,
            })
        return out

    def query(self, cal_href, comp, start=None, end=None, expand=False):
        rng = ""
        if start and end:
            rng = '<c:time-range start="%s" end="%s"/>' % (utcstamp(start), utcstamp(end))
        data = "<c:calendar-data/>"
        if expand and start and end:
            data = '<c:calendar-data><c:expand start="%s" end="%s"/></c:calendar-data>' % (
                utcstamp(start), utcstamp(end))
        body = """<?xml version="1.0" encoding="utf-8"?>
<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
  <d:prop><d:getetag/>%s</d:prop>
  <c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="%s">%s</c:comp-filter></c:comp-filter></c:filter>
</c:calendar-query>""" % (data, comp, rng)
        _, raw = self.request("REPORT", cal_href, body)
        out = []
        for resp in ET.fromstring(raw).findall("d:response", DAV_NS):
            text = resp.findtext(".//c:calendar-data", "", DAV_NS)
            if text:
                out.append((urllib.parse.urljoin(cal_href, resp.findtext("d:href", "", DAV_NS)), text))
        return out


def caldav_fetch(src, start, end, want_tasks):
    sid = src.get("id", "dav")
    pw = source_password(src)
    if not pw:
        return {"error": "no password for %s (keychain %s)" % (sid, (src.get("keychain") or {}).get("service", "?"))}
    dav = Dav(src["url"], src.get("user", ""), pw)
    only = src.get("calendars")
    cals, events, tasks = [], [], []
    recent = iso(datetime.now() - timedelta(days=14))
    for cal in dav.calendars():
        if only and cal["uid"] not in only:
            continue
        cal_id = "%s/%s" % (sid, cal["uid"])
        cals.append({"id": cal_id, "name": cal["name"] or cal["uid"], "color": cal["color"],
                     "source": sid, "events": cal["events"], "tasks": cal["tasks"]})
        if cal["events"]:
            for _, text in dav.query(cal["href"], "VEVENT", start, end, expand=True):
                for comp in parse_ics(text):
                    if comp[0] != "VEVENT":
                        continue
                    ev = event_from_ics(comp, cal_id)
                    if ev:
                        events.append(ev)
        if want_tasks and cal["tasks"]:
            for href, text in dav.query(cal["href"], "VTODO"):
                for comp in parse_ics(text):
                    if comp[0] != "VTODO":
                        continue
                    t = task_from_ics(comp, cal_id, href)
                    # Open ones, plus what was finished lately (so "show done" has something).
                    if not t["done"] or t["completed"] >= recent:
                        tasks.append(t)
    return {"calendars": cals, "events": events, "tasks": tasks}


# --- Google -------------------------------------------------------------------

GOOGLE_TOKEN = os.path.expanduser("~/.config/cove/google_token.json")
GOOGLE_CLIENT = os.path.expanduser("~/.config/cove/google_client.json")
GOOGLE_SCOPE = "https://www.googleapis.com/auth/calendar"


def google_client():
    with open(GOOGLE_CLIENT) as f:
        d = json.load(f)
    d = d.get("installed") or d.get("web") or d
    return d["client_id"], d.get("client_secret", "")


def http_json(url, data=None, headers=None, method=None, timeout=25):
    body = None
    if isinstance(data, dict):
        body = urllib.parse.urlencode(data).encode()
    elif isinstance(data, (bytes, str)):
        body = data.encode() if isinstance(data, str) else data
    req = urllib.request.Request(url, data=body, method=method or ("POST" if body else "GET"))
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode() or "{}")


def google_access_token():
    with open(GOOGLE_TOKEN) as f:
        tok = json.load(f)
    if tok.get("access_token") and tok.get("expires_at", 0) > time.time() + 60:
        return tok["access_token"]
    cid, secret = google_client()
    fresh = http_json("https://oauth2.googleapis.com/token",
                      {"client_id": cid, "client_secret": secret,
                       "refresh_token": tok["refresh_token"], "grant_type": "refresh_token"},
                      {"Content-Type": "application/x-www-form-urlencoded"})
    tok["access_token"] = fresh["access_token"]
    tok["expires_at"] = time.time() + int(fresh.get("expires_in", 3600))
    tmp_write(GOOGLE_TOKEN, json.dumps(tok))
    return tok["access_token"]


def google_fetch(src, start, end, want_tasks):
    sid = src.get("id", "g")
    try:
        token = google_access_token()
    except FileNotFoundError:
        return {"error": "google not connected (run: cove_calendar.py google-auth)"}
    auth = {"Authorization": "Bearer " + token}
    only = src.get("calendars")
    cals, events = [], []
    page = None
    entries = []
    while True:
        url = "https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=250"
        if page:
            url += "&pageToken=" + page
        d = http_json(url, headers=auth)
        entries += d.get("items", [])
        page = d.get("nextPageToken")
        if not page:
            break
    # Default: your own calendars and ones you can edit, not every colleague's
    # calendar you've subscribed to ("calendars": [...] in the config overrides).
    roles = src.get("roles", ["owner", "writer"])
    for cal in entries:
        if only:
            if cal["id"] not in only:
                continue
        elif not cal.get("primary") and (cal.get("selected") is False or cal.get("accessRole") not in roles):
            continue
        cal_id = "%s/%s" % (sid, cal["id"])
        cals.append({"id": cal_id, "name": cal.get("summary", cal["id"]),
                     "color": cal.get("backgroundColor", ""), "source": sid,
                     "events": True, "tasks": False})
        params = {"timeMin": start.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
                  "timeMax": end.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
                  "singleEvents": "true", "orderBy": "startTime", "maxResults": "2500"}
        url = ("https://www.googleapis.com/calendar/v3/calendars/%s/events?%s"
               % (urllib.parse.quote(cal["id"], safe=""), urllib.parse.urlencode(params)))
        d = http_json(url, headers=auth)
        for ev in d.get("items", []):
            if ev.get("status") == "cancelled":
                continue
            s, e = ev.get("start", {}), ev.get("end", {})
            allday = "date" in s
            if allday:
                st, en = parse_day(s["date"]), parse_day(e.get("date", s["date"]))
            else:
                st = as_local(datetime.fromisoformat(s["dateTime"]))
                en = as_local(datetime.fromisoformat(e.get("dateTime", s["dateTime"])))
            events.append({
                "id": "%s/%s" % (cal_id, ev["id"]),
                "uid": ev["id"], "cal": cal_id,
                "title": ev.get("summary", "(no title)"),
                "start": iso(st), "end": iso(en), "allday": allday,
                "location": ev.get("location", ""),
                "status": (ev.get("status") or "").upper(),
                "recurring": bool(ev.get("recurringEventId")),
                "url": ev.get("htmlLink", ""),
            })
    return {"calendars": cals, "events": events, "tasks": []}


# --- macOS Reminders / EventKit ------------------------------------------------

def eventkit_fetch(src, start, end, want_tasks):
    if not os.path.exists(REMINDERS_BIN):
        return {"error": "cove-reminders helper not built"}
    args = [REMINDERS_BIN, "fetch", "--start", start.date().isoformat(), "--end", end.date().isoformat()]
    if not src.get("events", False):
        args.append("--reminders-only")
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=40)
    except Exception as e:
        return {"error": "cove-reminders: %s" % e}
    if p.returncode != 0:
        return {"error": (p.stderr or "cove-reminders failed").strip()[:200]}
    try:
        d = json.loads(p.stdout)
    except Exception:
        return {"error": "cove-reminders: bad output"}
    sid = src.get("id", "mac")
    for c in d.get("calendars", []):
        c["source"] = sid
    return d


# --- writing back --------------------------------------------------------------

def task_write(cfg, op, task_id, text=""):
    """op: done | undone | add | delete. task_id is <source>/<calendar>/<uid>,
    or <source>/<calendar> for add."""
    sid = task_id.split("/", 1)[0]
    src = next((s for s in cfg.get("sources", []) if s.get("id") == sid), None)
    if src is None:
        return {"ok": False, "error": "unknown source %s" % sid}
    if src["kind"] == "eventkit":
        args = [REMINDERS_BIN, op, task_id]
        if text:
            args.append(text)
        p = subprocess.run(args, capture_output=True, text=True, timeout=30)
        if p.returncode != 0:
            return {"ok": False, "error": (p.stderr or "").strip()[:200]}
        return {"ok": True}
    if src["kind"] != "caldav":
        return {"ok": False, "error": "%s tasks are read-only" % src["kind"]}
    pw = source_password(src)
    dav = Dav(src["url"], src.get("user", ""), pw)
    parts = task_id.split("/")
    cal_uid, uid = parts[1], "/".join(parts[2:])
    cal_href = urllib.parse.urljoin(dav.url, urllib.parse.quote(cal_uid) + "/")
    if op == "add":
        new_uid = "cove-%d@cove" % int(time.time() * 1000)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        ics = ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Cove//EN\r\nBEGIN:VTODO\r\n"
               "UID:%s\r\nDTSTAMP:%s\r\nSUMMARY:%s\r\nSTATUS:NEEDS-ACTION\r\n"
               "END:VTODO\r\nEND:VCALENDAR\r\n") % (new_uid, stamp, text.replace("\n", "\\n"))
        dav.request("PUT", cal_href + urllib.parse.quote(new_uid) + ".ics", ics,
                    depth=None, ctype="text/calendar; charset=utf-8")
        return {"ok": True, "uid": new_uid}
    found = None
    for href, ics in dav.query(cal_href, "VTODO"):
        for comp in parse_ics(ics):
            if comp[0] == "VTODO" and comp[1].get("UID", ("", {}))[0] == uid:
                found = (href, ics)
                break
        if found:
            break
    if not found:
        return {"ok": False, "error": "task not found"}
    href, ics = found
    if op == "delete":
        dav.request("DELETE", href, depth=None)
        return {"ok": True}
    done = op == "done"
    lines = [l for l in unfold(ics) if not re.match(
        r"^(STATUS|PERCENT-COMPLETE|COMPLETED|LAST-MODIFIED)[;:]", l, re.I)]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = []
    for line in lines:
        out.append(line)
        if line.upper().startswith("BEGIN:VTODO"):
            out.append("LAST-MODIFIED:" + stamp)
            if done:
                out += ["STATUS:COMPLETED", "PERCENT-COMPLETE:100", "COMPLETED:" + stamp]
            else:
                out += ["STATUS:NEEDS-ACTION", "PERCENT-COMPLETE:0"]
    dav.request("PUT", href, "\r\n".join(out), depth=None, ctype="text/calendar; charset=utf-8")
    return {"ok": True}


# --- fetch --------------------------------------------------------------------

FETCHERS = {"caldav": caldav_fetch, "google": google_fetch, "eventkit": eventkit_fetch}


def fetch(start_day, end_day, want_tasks=True):
    cfg = load_config()
    start = datetime.combine(start_day, datetime.min.time(), LOCAL)
    end = datetime.combine(end_day, datetime.min.time(), LOCAL)
    out = {"ok": True, "fetched": int(time.time()), "start": start_day.isoformat(),
           "end": end_day.isoformat(), "calendars": [], "events": [], "tasks": [], "errors": [], "failed": []}
    if cfg.get("error"):
        out["errors"].append(cfg["error"])
    for src in cfg.get("sources", []):
        if not src.get("enabled", True):
            continue
        fn = FETCHERS.get(src.get("kind", ""))
        if fn is None:
            out["errors"].append("unknown source kind %r" % src.get("kind"))
            continue
        try:
            got = fn(src, start, end, want_tasks)
        except urllib.error.HTTPError as e:
            got = {"error": "%s: HTTP %s" % (src.get("id"), e.code)}
        except Exception as e:
            got = {"error": "%s: %s" % (src.get("id"), e)}
        if got.get("error"):
            out["errors"].append(got["error"])
            out["failed"].append(src.get("id", ""))
        for k in ("calendars", "events", "tasks"):
            out[k] += got.get(k, [])
    dedupe(out)
    out["events"].sort(key=lambda e: (e["start"], e["title"]))
    out["tasks"].sort(key=lambda t: (t["done"], t["due"] or "9999", t["title"]))
    return out


def dedupe(out):
    """macOS Reminders/Calendar usually mirror the same CalDAV account, so an
    EventKit item whose external id is a UID another source already gave us is
    the same thing twice: keep the direct one. A mirrored list left empty by
    that goes too, so the lists menu doesn't show everything twice."""
    # The same meeting through two sources (a Nextcloud calendar mirroring
    # Google, say) is kept once, from whichever source the config lists first.
    seen = set()
    events = []
    for e in out["events"]:
        key = (e["title"].strip().lower(), e["start"], e["end"])
        if key not in seen:
            seen.add(key)
            events.append(e)
    out["events"] = events
    kit = {s for s in (c.get("source") for c in out["calendars"])
           if any(src.get("kind") == "eventkit" and src.get("id") == s for src in load_config().get("sources", []))}
    if not kit:
        return
    def is_kit(x):
        return x["cal"].split("/", 1)[0] in kit
    seen_t = {t["uid"] for t in out["tasks"] if not is_kit(t)}
    seen_e = {(e["uid"], e["start"]) for e in out["events"] if not is_kit(e)}
    out["tasks"] = [t for t in out["tasks"] if not (is_kit(t) and t.get("ext") in seen_t)]
    out["events"] = [e for e in out["events"] if not (is_kit(e) and (e.get("ext"), e["start"]) in seen_e)]
    names = {c["name"] for c in out["calendars"] if c.get("source") not in kit}
    used = {x["cal"] for x in out["tasks"] + out["events"]}
    out["calendars"] = [c for c in out["calendars"]
                        if not (c.get("source") in kit and c["name"] in names and c["id"] not in used)]


# --- google OAuth (loopback) ---------------------------------------------------

def google_auth(out_path, open_browser=True):
    import http.server, secrets, hashlib, threading
    cid, secret = google_client()
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(48)).decode().rstrip("=")
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    got = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            got.update({k: v[0] for k, v in q.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            msg = "Cove is connected to Google Calendar. You can close this tab."
            if "error" in got:
                msg = "Google said: %s" % got["error"]
            self.wfile.write(("<html><body style='font:16px -apple-system;padding:3em'>%s</body></html>"
                              % msg).encode())

        def log_message(self, *a):
            pass

    srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    redirect = "http://127.0.0.1:%d/" % srv.server_address[1]
    url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
        "client_id": cid, "redirect_uri": redirect, "response_type": "code",
        "scope": GOOGLE_SCOPE, "access_type": "offline", "prompt": "consent",
        "code_challenge": challenge, "code_challenge_method": "S256"})
    tmp_write(out_path, json.dumps({"ok": False, "stage": "waiting", "url": url, "redirect": redirect}))
    if open_browser:
        subprocess.run(["/usr/bin/open", url], check=False)
    threading.Thread(target=srv.handle_request, daemon=True).start()
    deadline = time.time() + 300
    while not got and time.time() < deadline:
        time.sleep(0.25)
    srv.server_close()
    if "code" not in got:
        res = {"ok": False, "error": got.get("error", "timed out waiting for Google")}
        tmp_write(out_path, json.dumps(res))
        return res
    tok = http_json("https://oauth2.googleapis.com/token",
                    {"client_id": cid, "client_secret": secret, "code": got["code"],
                     "code_verifier": verifier, "grant_type": "authorization_code",
                     "redirect_uri": redirect},
                    {"Content-Type": "application/x-www-form-urlencoded"})
    keep = {"refresh_token": tok.get("refresh_token", ""), "access_token": tok.get("access_token", ""),
            "expires_at": time.time() + int(tok.get("expires_in", 3600))}
    os.makedirs(os.path.dirname(GOOGLE_TOKEN), exist_ok=True)
    tmp_write(GOOGLE_TOKEN, json.dumps(keep))
    os.chmod(GOOGLE_TOKEN, 0o600)
    res = {"ok": bool(keep["refresh_token"]), "error": "" if keep["refresh_token"] else "no refresh token"}
    tmp_write(out_path, json.dumps(res))
    return res


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    cmd, out_path = argv[1], argv[2]
    if cmd == "fetch":
        start = parse_day(argv[3]) if len(argv) > 3 else date.today() - timedelta(days=30)
        end = parse_day(argv[4]) if len(argv) > 4 else start + timedelta(days=120)
        res = fetch(start, end)
    elif cmd == "task":
        res = task_write(load_config(), argv[3], argv[4], argv[5] if len(argv) > 5 else "")
    elif cmd == "google-auth":
        return 0 if google_auth(out_path, "--no-open" not in argv).get("ok") else 1
    else:
        print("unknown command %r" % cmd)
        return 2
    if out_path == "-":
        print(json.dumps(res, indent=2))
    else:
        tmp_write(out_path, json.dumps(res))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
