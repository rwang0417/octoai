#!/usr/bin/env python3
"""OctoWoW data lookup for AI assistants (stdlib only, Python 3.8+).

Data sources
  data/*.json        OctoQuestDatabase (quests, NPCs, objects, item sources, coords) - Octo/Turtle/Vanilla merged
  snapshot           OctoAI addon output: <WoW>/WTF/.../SavedVariables/OctoAI.lua or <WoW>/VanillaHelpersData/octo_<Name>.json
  Location           this file lives in <WoW>/Interface/AddOns/OctoAI/tools/; data/ sits next to it

Commands (all output is plain text meant to be read by an AI)
  char [NAME] [--section S]   character summary (S: stats|talents|equipment|bags|bank|quests|skills|professions|trainers|rep|spells|buffs|all)
  talents [NAME]              full talent trees of the character's class with descriptions
  myquests [NAME]             every quest in the log: objectives, where to go, turn-in, distance from player
  quest ID|TITLE              quest details
  npc ID|NAME                 NPC level/faction/locations, quests it starts/ends, items it sells
  object ID|NAME              world object locations and related quests
  item ID|NAME                where an item drops / is sold / which quests use or reward it
  zone NAME [--level N] [--faction A|H] [--class CLASS]   quests that start in a zone
  service TYPE [--zone Z] [--faction A|H]   flight|innkeeper|vendor|repair|banker|auctioneer|stablemaster|mailbox|...
  search TEXT                 search names of quests, NPCs, objects, items, zones
  seen ID|NAME                full tooltip (stats) of items the player hovered in game (OctoAI item cache)
  events                      holiday / event calendar
  list                        list exported characters

Options: --snap FILE (use a specific snapshot file), --json (raw JSON where supported)
Coordinates are zone map percentages (x = west->east, y = north->south), the same numbers pfQuest/Questie show.
"""
import argparse
import datetime
import glob
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = next((d for d in (os.path.join(HERE, "data"), os.path.join(HERE, "..", "data")) if os.path.isdir(d)),
            os.path.join(HERE, "data"))

RACE_BITS = {"human": 1, "orc": 2, "dwarf": 4, "night elf": 8, "nightelf": 8, "undead": 16, "scourge": 16,
             "tauren": 32, "gnome": 64, "troll": 128, "goblin": 256, "high elf": 512, "highelf": 512,
             "bloodelf": 512}
ALLIANCE_BITS = 1 | 4 | 8 | 64 | 512
HORDE_BITS = 2 | 16 | 32 | 128 | 256
CLASS_BITS = {"warrior": 1, "paladin": 2, "hunter": 4, "rogue": 8, "priest": 16, "shaman": 64,
              "mage": 128, "warlock": 256, "druid": 1024}
QUEST_TYPES = {1: "Group", 41: "PvP", 62: "Raid", 81: "Dungeon"}
RANKS = {"1": "Elite", "2": "Rare Elite", "3": "Boss", "4": "Rare"}

_db = {}


def load(name):
    if name not in _db:
        path = os.path.join(DATA, name + ".json")
        if not os.path.isfile(path):
            sys.exit("Quest database missing (%s). Download it once with:  python %s" % (
                path, os.path.join(HERE, "update_data.py")))
        with open(path, encoding="utf-8") as f:
            _db[name] = json.load(f)
    return _db[name]


def L(kind, i):
    return load("locales")[kind].get(str(i))


def name_of(kind, i):
    v = L(kind, i)
    if isinstance(v, dict):
        return v.get("T") or str(i)
    return v or ("#%s" % i)


def zone_name(zid):
    return L("zones", zid) or ("zone %s" % zid)


# ---------------------------------------------------------------------------
# Snapshot handling
# ---------------------------------------------------------------------------
WOW_DIR = os.environ.get("OCTO_WOW_DIR")  # set by --wow


def snapshot_dirs():
    dirs = []
    env = os.environ.get("OCTO_EXPORT_DIR")
    if env:
        dirs.append(env)
    if WOW_DIR:
        dirs.append(os.path.join(WOW_DIR, "VanillaHelpersData"))
    # tool installed in the addon folder (<WoW>/Interface/AddOns/OctoAI/tools/octo_query.py)
    dirs.append(os.path.join(os.path.join(HERE, "..", "..", "..", ".."), "VanillaHelpersData"))
    dirs.append(os.path.join(HERE, "..", "VanillaHelpersData"))
    dirs.append(os.path.join(os.getcwd(), "VanillaHelpersData"))
    dirs.append(os.getcwd())
    # common upload folders of AI sandboxes
    dirs += ["/mnt/data", "/mnt/user-data/uploads"]
    return dirs


def wow_dirs():
    out = []
    if WOW_DIR:
        out.append(WOW_DIR)
    out.append(os.path.join(HERE, "..", "..", "..", ".."))
    out.append(os.path.join(HERE, ".."))
    out.append(os.getcwd())
    return out


def _lua_unescape(body):
    out, i, n = [], 0, len(body)
    simple = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n"}
    while i < n:
        ch = body[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        nx = body[i + 1] if i + 1 < n else ""
        if nx.isdigit():
            j = i + 1
            while j < n and j < i + 4 and body[j].isdigit():
                j += 1
            out.append(chr(int(body[i + 1:j])))
            i = j
        else:
            out.append(simple.get(nx, nx))
            i += 2
    return "".join(out)


def savedvariable_snapshots():
    """Fallback when VanillaHelpers WriteFile is unavailable: OctoAIDB.last in SavedVariables (OctoExport.lua from the old addon name is still read)."""
    found = []
    for w in wow_dirs():
        for fname in ("OctoAI.lua", "OctoExport.lua"):
            found += glob.glob(os.path.join(w, "WTF", "Account", "*", "*", "*", "SavedVariables", fname))
    return found


def _read_snapshot(path):
    if path.endswith(".lua"):
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        key = text.find('["last"]')
        if key < 0:
            return None
        q1 = text.find('"', text.find("=", key))
        i = q1 + 1
        while i < len(text):
            if text[i] == "\\":
                i += 2
                continue
            if text[i] == '"':
                break
            i += 1
        return json.loads(_lua_unescape(text[q1 + 1:i]))
    with open(path, encoding="utf-8", errors="replace") as f:
        return json.load(f)


def list_snapshots():
    seen, out = set(), []
    paths = []
    for d in snapshot_dirs():
        paths += glob.glob(os.path.join(d, "octo_*.json"))
        paths += glob.glob(os.path.join(d, "OctoAI*.lua"))  # uploaded SavedVariables copy
        paths += glob.glob(os.path.join(d, "OctoExport*.lua"))
    paths += savedvariable_snapshots()
    for p in paths:
        rp = os.path.realpath(p)
        if rp not in seen and os.path.isfile(p):
            seen.add(rp)
            out.append(p)
    out.sort(key=os.path.getmtime, reverse=True)
    return out


SNAPSHOT_ERRORS = []


def snapshot_entries():
    """[(path, snap)] newest first, one entry per character (newest file wins: json or SavedVariables)."""
    out, seen = [], set()
    for p in list_snapshots():
        try:
            snap = _read_snapshot(p)
        except Exception as e:  # noqa
            SNAPSHOT_ERRORS.append("%s: unreadable (%s)" % (p, e))
            continue
        if not snap or not (snap.get("character") or {}).get("level"):
            continue
        nm = ((snap.get("character") or {}).get("name") or "").lower()
        if nm in seen:
            continue
        seen.add(nm)
        out.append((p, snap))
    return out


def load_snapshot(name=None, path=None):
    if path:
        return _read_snapshot(path), path
    for p, snap in snapshot_entries():
        if name and ((snap.get("character") or {}).get("name") or "").lower() != name.lower():
            continue
        return snap, p
    return None, None


def age_text(snap, path):
    # file mtime is timezone-independent; exportedAt is the game PC's local clock.
    # An uploaded copy has the upload time as mtime, so its age is unknown.
    parent = os.path.basename(os.path.dirname(os.path.abspath(path)))
    in_game_dir = parent in ("VanillaHelpersData", "SavedVariables")
    if not in_game_dir:
        return "age unknown for an uploaded copy; exportedAt is the game PC's local time"
    try:
        mins = (datetime.datetime.now().timestamp() - os.path.getmtime(path)) / 60
    except OSError:
        return "unknown age"
    if mins < 0:
        mins = 0
    if mins < 2:
        return "just now"
    if mins < 120:
        return "%d min ago" % mins
    if mins < 48 * 60:
        return "%.1f h ago" % (mins / 60)
    return "%.1f days ago (stale: ask the player to log in and type /octo)" % (mins / 1440)


def player_context(snap):
    """faction bit mask, class bit, level, zone, coords from snapshot."""
    ctx = {"faction": None, "racebit": None, "classbit": None, "level": None, "zone": None, "coords": None, "zid": None}
    if not snap:
        return ctx
    c = snap.get("character") or {}
    rb = RACE_BITS.get((c.get("raceToken") or "").lower()) or RACE_BITS.get((c.get("race") or "").lower())
    if rb:
        ctx["racebit"] = rb
        ctx["faction"] = "A" if rb & ALLIANCE_BITS else "H"
    if c.get("faction") in ("Alliance", "Horde"):
        ctx["faction"] = c["faction"][0]
    ctx["classbit"] = CLASS_BITS.get((c.get("classToken") or c.get("class") or "").lower())
    ctx["level"] = c.get("level")
    ctx["zone"] = c.get("zone")
    ctx["coords"] = c.get("coords")
    if ctx["zone"]:
        try:
            ctx["zid"] = find_zone_id(ctx["zone"])
        except SystemExit:  # quest database not downloaded: character commands still work
            ctx["zid"] = None
    return ctx


# ---------------------------------------------------------------------------
# Lookup helpers
# ---------------------------------------------------------------------------
def find_zone_id(text):
    t = text.lower().strip()
    zones = load("locales")["zones"]
    exact = [k for k, v in zones.items() if v.lower() == t]
    if exact:
        # prefer zones that actually appear as coordinate zones
        zj = load("zones")
        exact.sort(key=lambda k: (k not in zj, int(k)))
        return int(exact[0])
    part = [k for k, v in zones.items() if t in v.lower()]
    return int(part[0]) if part else None


def resolve(kind, query, limit=8):
    """kind: quests|units|objects|items. Returns list of ids (str)."""
    q = str(query).strip()
    if q.lstrip("-").isdigit():
        return [q]
    ql = q.lower()
    names = load("locales")[kind]
    exact, prefix, sub = [], [], []
    for k, v in names.items():
        n = (v.get("T") if isinstance(v, dict) else v) or ""
        nl = n.lower()
        if nl == ql:
            exact.append(k)
        elif nl.startswith(ql):
            prefix.append(k)
        elif ql in nl:
            sub.append(k)
    res = exact or (prefix + sub)
    return res[:limit] if not exact else res


def faction_ok(fac, want):
    if not want or not fac:
        return True
    return want in fac


def quest_side(q):
    r = q.get("race")
    if not r:
        return "both"
    a, h = bool(r & ALLIANCE_BITS), bool(r & HORDE_BITS)
    if a and h:
        return "both"
    return "Alliance" if a else ("Horde" if h else "race-%s" % r)


def quest_allowed(q, ctx):
    r = q.get("race")
    if r and ctx.get("racebit"):
        if not r & ctx["racebit"]:
            return False
    elif r and ctx.get("faction"):
        mask = ALLIANCE_BITS if ctx["faction"] == "A" else HORDE_BITS
        if not r & mask:
            return False
    cb = ctx.get("classbit")
    if q.get("class") and cb and not q["class"] & cb:
        return False
    return True


def fmt_coords_by_zone(coords, ctx=None, maxzones=4, maxpts=3):
    """coords: [[x,y,zone,respawn],...] -> 'Zone: (x,y) (x,y) +N more'."""
    if not coords:
        return "no known coordinates (instance, scripted spawn, or not in DB)"
    byz = {}
    for c in coords:
        if len(c) >= 3:
            byz.setdefault(c[2], []).append((c[0], c[1]))
    order = sorted(byz, key=lambda z: (-(ctx and ctx.get("zid") == z), -len(byz[z])))
    parts = []
    for z in order[:maxzones]:
        pts = byz[z]
        if ctx and ctx.get("zid") == z and ctx.get("coords"):
            px, py = ctx["coords"]["x"], ctx["coords"]["y"]
            pts = sorted(pts, key=lambda p: (p[0] - px) ** 2 + (p[1] - py) ** 2)
        s = "%s: %s" % (zone_name(z), " ".join("(%.1f, %.1f)" % p for p in pts[:maxpts]))
        if len(pts) > maxpts:
            s += " +%d more spawns" % (len(pts) - maxpts)
        if ctx and ctx.get("zid") == z and ctx.get("coords"):
            s += "  [nearest is %s from you]" % rel(ctx["coords"], pts[0])
        parts.append(s)
    if len(order) > maxzones:
        parts.append("+%d other zones" % (len(order) - maxzones))
    return "; ".join(parts)


def rel(me, p):
    dx, dy = p[0] - me["x"], p[1] - me["y"]
    d = math.hypot(dx, dy)
    if d < 1.5:
        return "right here"
    ang = math.degrees(math.atan2(-dy, dx)) % 360  # 0=east, 90=north
    dirs = ["E", "NE", "N", "NW", "W", "SW", "S", "SE"]
    return "%.0f map-%% %s" % (d, dirs[int((ang + 22.5) // 45) % 8])


def unit_line(uid, ctx=None, coords=True):
    u = load("units").get(str(uid), {})
    s = "%s [npc %s] lvl %s" % (name_of("units", uid), uid, u.get("lvl", "?"))
    if u.get("rnk"):
        s += " %s" % RANKS.get(u["rnk"], u["rnk"])
    if u.get("fac"):
        s += " (friendly to %s)" % {"A": "Alliance", "H": "Horde", "AH": "both"}.get(u["fac"], u["fac"])
    if coords:
        s += " -- " + fmt_coords_by_zone(u.get("coords"), ctx)
    return s


def object_line(oid, ctx=None):
    o = load("objects").get(str(oid), {})
    return "%s [object %s] -- %s" % (name_of("objects", oid), oid, fmt_coords_by_zone(o.get("coords"), ctx))


def item_sources_short(iid, ctx=None, top=4):
    it = load("items").get(str(iid), {})
    out = []
    units = load("units")
    zid = ctx.get("zid") if ctx else None

    def here(uid):
        return zid is not None and any(len(c) > 2 and c[2] == zid for c in units.get(str(uid), {}).get("coords", []))
    drops = sorted(it.get("U", {}).items(), key=lambda kv: (not here(kv[0]), -kv[1]))
    for uid, pct in drops[:top]:
        out.append("drops from %s (%.1f%%)" % (unit_line(uid, ctx), pct))
    if len(drops) > top:
        out.append("... and %d more mobs" % (len(drops) - top))
    for oid, pct in sorted(it.get("O", {}).items(), key=lambda kv: -kv[1])[:top]:
        out.append("from %s (%.0f%%)" % (object_line(oid, ctx), pct))
    vend = list(it.get("V", {}).keys())
    for uid in vend[:top]:
        out.append("sold by %s" % unit_line(uid, ctx))
    return out


def ends_starts(spec, ctx):
    lines = []
    for uid in (spec or {}).get("U", []):
        lines.append(unit_line(uid, ctx))
    for oid in (spec or {}).get("O", []):
        lines.append(object_line(oid, ctx))
    for iid in (spec or {}).get("I", []):
        lines.append("item %s [item %s] (starts from an item drop: %s)" % (
            name_of("items", iid), iid, "; ".join(item_sources_short(iid, ctx, 2)) or "source unknown"))
    return lines


# ---------------------------------------------------------------------------
# Commands: database
# ---------------------------------------------------------------------------
def describe_quest(qid, ctx, verbose=True):
    qid = str(qid)
    q = load("quests").get(qid)
    if not q:
        return "quest %s not found in OctoQuestDatabase" % qid
    loc = L("quests", qid) or {}
    out = ["QUEST %s [id %s]  level %s, requires level %s%s, side: %s" % (
        loc.get("T", "?"), qid, q.get("lvl"), q.get("min"),
        (", max level %s" % q["max"]) if q.get("max") else "", quest_side(q)) + "  (web: https://octowow.st/db/?quest=%s)" % qid]
    flags = []
    if q.get("type"):
        flags.append(QUEST_TYPES.get(q["type"], "type %s" % q["type"]))
    for f in ("repeatable", "daily", "timed", "hardcore", "event"):
        if q.get(f):
            flags.append(f if f != "event" else "event %s" % q[f])
    if q.get("class"):
        flags.append("classes: " + ",".join(k for k, b in CLASS_BITS.items() if q["class"] & b))
    if q.get("skill"):
        flags.append("needs %s %s" % (L("professions", q["skill"]) or "skill %s" % q["skill"], q.get("skillValue", "")))
    if q.get("disabled"):
        flags.append("DISABLED on server")
    if flags:
        out.append("  flags: " + "; ".join(flags))
    if loc.get("O"):
        out.append("  objective text: " + loc["O"])
    if verbose and loc.get("D"):
        d = loc["D"].replace("$B", " ").replace("$b", " ")
        out.append("  description: " + (d[:500] + "..." if len(d) > 500 else d))
    out.append("  start: " + (" | ".join(ends_starts(q.get("start"), ctx)) or "unknown"))
    out.append("  turn in: " + (" | ".join(ends_starts(q.get("end"), ctx)) or "unknown"))
    obj = q.get("obj") or {}
    req = (load("supplemental")["objectiveRequirements"].get(qid) or {})
    if obj:
        out.append("  objectives:")
    for uid in obj.get("U", []):
        n = (req.get("U") or {}).get(str(uid))
        out.append("    kill/interact%s: %s" % ((" x%s" % n) if n else "", unit_line(uid, ctx)))
    for iid in obj.get("I", []):
        n = (req.get("I") or {}).get(str(iid))
        src = item_sources_short(iid, ctx)
        out.append("    collect%s %s [item %s]: %s" % ((" x%s" % n) if n else "", name_of("items", iid), iid,
                                                   "; ".join(src) if src else "source not in DB (quest-provided or scripted)"))
    for oid in obj.get("O", []):
        out.append("    use object: " + object_line(oid, ctx))
    for aid in obj.get("A", []):
        a = load("areatrigger").get(str(aid), {})
        out.append("    explore/reach: " + fmt_coords_by_zone(a.get("coords"), ctx))
    for iid in obj.get("IR", []):
        out.append("    item needed to complete: %s [item %s]" % (name_of("items", iid), iid))
    enc = load("scriptedEncounters")
    for uid in obj.get("U", []):
        if str(uid) in enc and enc[str(uid)].get("note"):
            out.append("    note: " + enc[str(uid)]["note"])
    if q.get("pre"):
        out.append("  prerequisite quests: " + ", ".join("%s [%s]" % (name_of("quests", p), p) for p in q["pre"]))
    nxt = load("supplemental")["progression"]["nextByQuest"].get(qid)
    if nxt:
        out.append("  next in chain: %s [%s]" % (name_of("quests", nxt), nxt))
    rw = load("supplemental")["rewards"].get(qid) or {}
    rparts = []
    if rw.get("money"):
        rparts.append(money(rw["money"]))
    for iid, n in rw.get("items", []):
        rparts.append("%s x%s [item %s]" % (name_of("items", iid), n, iid))
    if rw.get("choices"):
        rparts.append("choose one of: " + ", ".join("%s [item %s]" % (name_of("items", i), i) for i, n in rw["choices"]))
    if rparts:
        out.append("  rewards: " + "; ".join(rparts))
    return "\n".join(out)


def money(c):
    c = int(c)
    return "%dg %ds %dc" % (c // 10000, (c // 100) % 100, c % 100)


def cmd_quest(args, ctx):
    ids = resolve("quests", args.query)
    if not ids:
        return "no quest matches '%s'" % args.query
    qs = load("quests")
    ids = [i for i in ids if i in qs]
    if not ids:
        hint = ("https://octowow.st/db/?quest=%s" % args.query) if str(args.query).isdigit() else "a web search on octowow.st / the Turtle WoW wiki"
        return "quest '%s' not found in OctoQuestDatabase (removed, custom, or not in the database). Try %s" % (args.query, hint)
    allowed = [i for i in ids if quest_allowed(qs[i], ctx)]
    if allowed:
        ids = allowed
    if len(ids) > 1:
        head = "%d quests match '%s':\n" % (len(ids), args.query) + "\n".join(
            "  [%s] %s lvl %s (%s)" % (i, name_of("quests", i), qs[i].get("lvl"), quest_side(qs[i])) for i in ids[:15])
        if len(ids) <= 3:
            return head + "\n\n" + "\n\n".join(describe_quest(i, ctx) for i in ids)
        return head + "\nRe-run with the quest id for details."
    return describe_quest(ids[0], ctx)


def cmd_npc(args, ctx):
    ids = resolve("units", args.query)
    if not ids:
        return "no NPC matches '%s' in OctoQuestDatabase (it only has quest-relevant NPCs). Try a web search on octowow.st / the Turtle WoW wiki." % args.query
    if len(ids) > 1:
        lines = ["%d NPCs match '%s':" % (len(ids), args.query)] + ["  " + unit_line(i, ctx) for i in ids[:10]]
        if len(ids) > 3:
            return "\n".join(lines)
    out = []
    qs = load("quests")
    for uid in ids[:3]:
        out.append(unit_line(uid, ctx) + "  (web: https://octowow.st/db/?npc=%s)" % uid)
        starts = [k for k, q in qs.items() if int(uid) in (q.get("start") or {}).get("U", []) and quest_allowed(q, ctx)]
        ends = [k for k, q in qs.items() if int(uid) in (q.get("end") or {}).get("U", []) and quest_allowed(q, ctx)]
        if starts:
            out.append("  starts quests: " + ", ".join("%s [%s] lvl %s" % (name_of("quests", k), k, qs[k].get("lvl")) for k in starts[:25]))
        if ends:
            out.append("  quest turn-ins: " + ", ".join("%s [%s]" % (name_of("quests", k), k) for k in ends[:25]))
        sells = [k for k, it in load("items").items() if uid in it.get("V", {})]
        if sells:
            out.append("  sells (quest-relevant items only): " + ", ".join("%s [%s]" % (name_of("items", k), k) for k in sells[:30]))
        drops = sorted(((k, it["U"][uid]) for k, it in load("items").items() if uid in it.get("U", {})), key=lambda kv: -kv[1])
        if drops:
            out.append("  drops (quest-relevant items only): " + ", ".join("%s %.1f%%" % (name_of("items", k), p) for k, p in drops[:20]))
        roles = [k for k, v in load("meta").items() if uid in v]
        if roles:
            out.append("  services: " + ", ".join(roles))
    return "\n".join(out)


def cmd_object(args, ctx):
    ids = resolve("objects", args.query)
    if not ids:
        return "no object matches '%s' in OctoQuestDatabase. Try a web search on octowow.st / the Turtle WoW wiki." % args.query
    out = []
    qs = load("quests")
    for oid in ids[:5]:
        out.append(object_line(oid, ctx))
        rel_q = [k for k, q in qs.items() if int(oid) in ((q.get("obj") or {}).get("O", []) + (q.get("start") or {}).get("O", []) + (q.get("end") or {}).get("O", []))]
        if rel_q:
            out.append("  related quests: " + ", ".join("%s [%s]" % (name_of("quests", k), k) for k in rel_q[:15]))
    return "\n".join(out)


def cmd_item(args, ctx):
    ids = resolve("items", args.query)
    if not ids:
        return ("no item matches '%s' in the quest database. OctoQuestDatabase only covers quest-relevant items; "
                "for stats/drop of other items check https://octowow.st/db/?item=ID" % args.query)
    out = []
    qs = load("quests")
    rewards = load("supplemental")["rewards"]
    for iid in ids[:3]:
        out.append("ITEM %s [item %s]  (stats: https://octowow.st/db/?item=%s)" % (name_of("items", iid), iid, iid))
        src = item_sources_short(iid, ctx, top=8)
        out += ["  " + s for s in src] or ["  no drop/vendor source in DB"]
        used = [k for k, q in qs.items() if int(iid) in (q.get("obj") or {}).get("I", [])]
        if used:
            out.append("  needed for quests: " + ", ".join("%s [%s]" % (name_of("quests", k), k) for k in used[:15]))
        rew = [k for k, r in rewards.items() if any(i == int(iid) for i, n in r.get("items", []) + r.get("choices", []))]
        if rew:
            out.append("  reward from quests: " + ", ".join("%s [%s]" % (name_of("quests", k), k) for k in rew[:15]))
    if len(ids) > 3:
        out.append("(%d more matches: %s)" % (len(ids) - 3, ", ".join("%s [%s]" % (name_of("items", i), i) for i in ids[3:10])))
    return "\n".join(out)


def cmd_zone(args, ctx):
    zid = find_zone_id(args.name)
    if zid is None:
        return "unknown zone '%s'" % args.name
    level = args.level or ctx.get("level")
    fac = (args.faction or ctx.get("faction") or "").upper()[:1] or None
    c2 = dict(ctx)
    if args.faction:
        c2["faction"] = fac
        c2["racebit"] = None
    if args.cls:
        c2["classbit"] = CLASS_BITS.get(args.cls.lower())
    qs = load("quests")
    units, objs = load("units"), load("objects")
    found = []
    for k, q in qs.items():
        if q.get("disabled") or not quest_allowed(q, c2):
            continue
        st = q.get("start") or {}
        zones = set()
        for uid in st.get("U", []):
            zones.update(c[2] for c in units.get(str(uid), {}).get("coords", []) if len(c) > 2)
        for oid in st.get("O", []):
            zones.update(c[2] for c in objs.get(str(oid), {}).get("coords", []) if len(c) > 2)
        if zid in zones:
            if level and (q.get("min", 0) > level or q.get("lvl", 0) < level - 6):
                continue
            found.append(k)
    found.sort(key=lambda k: (qs[k].get("lvl", 0), name_of("quests", k)))
    head = "Quests starting in %s%s%s (%d):" % (zone_name(zid), (" for level %s" % level) if level else "",
                                                (" faction %s" % fac) if fac else "", len(found))
    lines = [head]
    for k in found[:args.limit]:
        q = qs[k]
        giver = ", ".join(name_of("units", u) for u in (q.get("start") or {}).get("U", [])[:1]) or \
            ", ".join(name_of("objects", o) for o in (q.get("start") or {}).get("O", [])[:1])
        t = QUEST_TYPES.get(q.get("type"))
        lines.append("  [%s] lvl %s (min %s)%s %s  - from %s" % (k, q.get("lvl"), q.get("min"), (" " + t) if t else "", name_of("quests", k), giver))
    if len(found) > args.limit:
        lines.append("  ... %d more (use --limit)" % (len(found) - args.limit))
    return "\n".join(lines)


def cmd_service(args, ctx):
    meta = load("meta")
    t = args.type.lower()
    key = next((k for k in meta if k.startswith(t)), None)
    if not key:
        return "unknown service '%s'. Options: %s" % (args.type, ", ".join(sorted(meta)))
    fac = (args.faction or ctx.get("faction") or "")
    fac = fac.upper()[:1] if fac else None
    zid = find_zone_id(args.zone) if args.zone else None
    out = []
    for sid, v in meta[key].items():
        i = int(sid)
        if i < 0:
            coords = load("objects").get(str(-i), {}).get("coords", [])
            nm = name_of("objects", -i)
        else:
            u = load("units").get(sid, {})
            coords = u.get("coords", [])
            nm = name_of("units", sid)
            if isinstance(v, str) and fac and fac not in v:
                continue
        if zid is not None:
            coords = [c for c in coords if len(c) > 2 and c[2] == zid]
            if not coords:
                continue
        out.append("  %s [%s] -- %s" % (nm, sid, fmt_coords_by_zone(coords, ctx, maxzones=2, maxpts=2)))
    return "%s (%d):\n" % (key, len(out)) + "\n".join(out[:60])


def cmd_search(args, ctx):
    out = []
    for kind, label in (("quests", "quest"), ("units", "npc"), ("objects", "object"), ("items", "item"), ("zones", "zone")):
        ids = resolve(kind, args.text, limit=12)
        if ids and not args.text.isdigit():
            out.append("%s: %s" % (label, ", ".join("%s [%s]" % (name_of(kind, i), i) for i in ids)))
    return "\n".join(out) or "nothing found"


def item_cache_files():
    out = []
    for w in wow_dirs():
        out += glob.glob(os.path.join(w, "WTF", "Account", "*", "SavedVariables", "OctoAI.lua"))
    return out


def load_item_cache():
    """{key: (time, itemId, name, [tooltip lines])} from OctoAIItems (account-wide SavedVariables)."""
    items = {}
    for f in item_cache_files():
        with open(f, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for m in re.finditer(r'\["(item:[^"]+)"\]\s*=\s*"((?:[^"\\]|\\.)*)"', text):
            v = _lua_unescape(m.group(2)).split("\n")
            if len(v) < 4 or not v[0].isdigit() or not v[1].isdigit():
                continue
            ts, iid = int(v[0]), int(v[1])
            prev = items.get(m.group(1))
            if prev and prev[0] >= ts:
                continue
            items[m.group(1)] = (ts, iid, v[2], v[3:])
    return items


def cmd_seen(args, ctx):
    items = load_item_cache()
    if not items:
        return ("No item tooltips cached yet. In game (OctoAI 1.1.0+), hover the item once (auction house, vendor, "
                "chat link, loot, bags), then /reload so the cache is written.")
    q = args.query.strip().lower()
    hits = []
    for key, (ts, iid, name, lines) in items.items():
        if (q.isdigit() and int(q) == iid) or (not q.isdigit() and q in name.lower()):
            hits.append((ts, key, iid, name, lines))
    if not hits:
        return "No cached tooltip matches '%s' (%d items cached). Hover it in game, then /reload." % (args.query, len(items))
    hits.sort(reverse=True)
    out = []
    for ts, key, iid, name, lines in hits[:15]:
        when = datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")
        out.append("ITEM %s [item %d] (tooltip seen in game %s, %s)" % (name, iid, when, key))
        out.append("  " + "; ".join(lines))
    if len(hits) > 15:
        out.append("... %d more matches, refine the name" % (len(hits) - 15))
    return "\n".join(out)


def cmd_events(args, ctx):
    rules = load("supplemental")["calendarRules"]
    lines = ["Event calendar (month/day):"]
    for v in rules.values():
        lines.append("  %s: %s/%s - %s/%s" % (v["name"], v["startMonth"], v["startDay"], v["endMonth"], v["endDay"]))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Commands: character snapshot
# ---------------------------------------------------------------------------
def tip_text(lines, skip_first=True):
    lines = list(lines or [])
    if skip_first and lines:
        lines = lines[1:]
    lines = [l for l in lines if not l.startswith(("Binds when", "Soulbound", "Unique", "Durability"))]
    return "; ".join(l.replace("\n", " ") for l in lines)


def talent_desc(t):
    lines = list(t.get("tooltip") or [])[1:]
    lines = [l for l in lines if not l.startswith("Rank ") and l not in ("Click to learn",)]
    return " ".join(l.replace("\n", " ") for l in lines)


def section_text(snap, sec, path):
    c = snap.get("character") or {}
    out = []
    if sec in ("summary", "all"):
        out.append("CHARACTER %s (%s %s), level %s, realm %s, server %s. Snapshot exported %s (%s)." % (
            c.get("name"), c.get("race"), c.get("class"), c.get("level"), c.get("realm"), snap.get("server"),
            snap.get("exportedAt"), age_text(snap, path)))
        pos = c.get("coords")
        out.append("  location: %s%s%s" % (c.get("zone"), (" / " + c["subzone"]) if c.get("subzone") else "",
                                          (" at (%.1f, %.1f)" % (pos["x"], pos["y"])) if pos else ""))
        out.append("  xp %s/%s%s, money %s, guild %s" % (c.get("xp"), c.get("xpMax"),
                                                     (", rested %s" % c["restedXP"]) if c.get("restedXP") else "",
                                                     c.get("money"), c.get("guild") or "-"))
        t = snap.get("talents") or {}
        if t:
            out.append("  talents %s (%s), unspent points: %s" % (t.get("build"), " / ".join(tr["name"] for tr in t.get("trees", [])), t.get("unspent")))
        if c.get("pet"):
            out.append("  pet: %s" % c["pet"])
        if snap.get("errors"):
            out.append("  export warnings: %s" % snap["errors"])
    if sec in ("stats", "all") and snap.get("stats"):
        s = snap["stats"]
        out.append("STATS: " + ", ".join("%s %s" % kv for kv in (s.get("primary") or {}).items()) +
                   ", armor %s, AP %s, RAP %s, HP %s, mana/power %s" % (s.get("armor"), s.get("attackPower"), s.get("rangedAttackPower"), c.get("healthMax"), c.get("powerMax")))
        extra = {k: v for k, v in s.items() if k.endswith("Chance") and v is not None}
        if extra:
            out.append("  " + ", ".join("%s %.2f%%" % kv for kv in extra.items()))
        out.append("  resist: " + ", ".join("%s %s" % kv for kv in (s.get("resist") or {}).items()))
    if sec in ("talents", "all") and snap.get("talents"):
        out.append("TALENTS (learned): build %s, unspent %s" % (snap["talents"].get("build"), snap["talents"].get("unspent")))
        for tr in snap["talents"].get("trees", []):
            got = [t for t in tr.get("talents", []) if t.get("rank")]
            out.append("  %s (%s pts): %s" % (tr["name"], tr.get("spent"), ", ".join("%s %s/%s" % (t["name"], t["rank"], t["max"]) for t in got) or "-"))
        out.append("  (use 'talents' for the full trees with descriptions)")
    if sec in ("equipment", "all") and snap.get("equipment"):
        out.append("EQUIPMENT:")
        for it in snap["equipment"]:
            out.append("  %s: %s [item %s, %s] %s" % (it.get("slot"), it.get("name"), it.get("id"), it.get("quality"), tip_text(it.get("tooltip"))))
    if sec in ("bags", "all") and snap.get("bags"):
        b = snap["bags"]
        out.append("BAGS: %s free of %s slots (%s)" % (b.get("freeSlots"), b.get("totalSlots"), ", ".join("%s(%s)" % (x["name"], x["slots"]) for x in b.get("bags", []))))
        for it in b.get("equippable", []):
            out.append("  gear: %s [item %s, %s] %s" % (it.get("name"), it.get("id"), it.get("quality"), tip_text(it.get("tooltip"))))
        out.append("  other: " + ", ".join("%s x%s" % (it.get("name"), it.get("count")) for it in b.get("items", [])))
    if sec in ("bank", "all") and snap.get("bank"):
        b = snap["bank"]
        out.append("BANK (scanned %s): " % b.get("scannedAt") + ", ".join("%s x%s" % (it.get("name"), it.get("count")) for it in (b.get("items", []) + b.get("equippable", []))))
    if sec in ("quests", "all") and snap.get("quests") is not None:
        out.append("QUEST LOG (%d):" % len(snap["quests"]))
        for q in snap["quests"]:
            prog = "; ".join("%s%s" % (p.get("text"), " (done)" if p.get("done") else "") for p in q.get("progress") or [])
            out.append("  [%s] %s lvl %s - %s%s%s" % (q.get("id") or "?", q.get("title"), q.get("level"), q.get("status"),
                                                   (" - " + prog) if prog else "", (" (" + q["tag"] + ")") if q.get("tag") else ""))
    if sec in ("skills", "all") and snap.get("skills"):
        out.append("SKILLS: " + ", ".join("%s %s/%s" % (s["name"], s.get("rank"), s.get("max")) for s in snap["skills"] if s.get("category") not in ("Languages",) and (s.get("max") or 0) > 1))
    if sec in ("professions", "prof", "recipes", "all"):
        profs = snap.get("professions") or {}
        if not profs:
            out.append("PROFESSIONS: no recipe data yet. In game, open each profession window once (OctoAI addon); recipes are saved and exported automatically.")
        for pname in sorted(profs):
            P = profs[pname]
            rec = P.get("recipes") or []
            out.append("PROFESSION %s %s/%s - %d recipes (scanned %s; 'have' counts are bags only at scan time)" % (
                pname, P.get("rank"), P.get("max"), len(rec), P.get("scannedAt")))
            for r in rec:
                rg = ", ".join("%s x%s (have %s)" % (g.get("name"), g.get("count"), g.get("have")) for g in r.get("reagents") or [])
                extra = []
                if r.get("made"):
                    extra.append("makes %s" % r["made"])
                if r.get("canMake"):
                    extra.append("can make %s now" % r["canMake"])
                if r.get("cooldownSec"):
                    extra.append("ON COOLDOWN until %s" % r.get("readyAt"))
                out.append("  [%s] %s%s%s: %s%s" % (r.get("difficulty"), r.get("name"),
                                                  (" [item %s]" % r["itemId"]) if r.get("itemId") else "",
                                                  (" {" + r["header"] + "}") if r.get("header") else "", rg,
                                                  (" - " + "; ".join(extra)) if extra else ""))
            out.append("  difficulty: optimal=orange (sure skill-up), medium=yellow, easy=green, trivial=grey (no skill-up)")
    if sec in ("trainers", "trainer", "all") and snap.get("trainers"):
        for tname in sorted(snap["trainers"]):
            T = snap["trainers"][tname]
            out.append("TRAINER %s (scanned %s):" % (tname, T.get("scannedAt")))
            for sv in T.get("services") or []:
                cost = sv.get("costCopper")
                out.append("  [%s] %s%s%s%s%s" % (sv.get("status"), sv.get("name"),
                    (" (" + sv["rank"] + ")") if sv.get("rank") else "",
                    (" {" + sv["header"] + "}") if sv.get("header") else "",
                    (" - requires " + sv["requires"] + ("" if sv.get("meetsSkill") else " (NOT MET)")) if sv.get("requires") else "",
                    (" - %dg %ds %dc" % (cost // 10000, cost // 100 % 100, cost % 100)) if cost else ""))
    if sec in ("rep", "all") and snap.get("reputation"):
        out.append("REPUTATION: " + ", ".join("%s %s %s" % (r["name"], r.get("standing"), r.get("progress", "")) for r in snap["reputation"]))
    if sec in ("spells", "all") and snap.get("spells"):
        for tab in snap["spells"]:
            out.append("SPELLS %s: %s" % (tab.get("tab"), ", ".join(tab.get("spells", []))))
            for sname, lines in sorted((tab.get("details") or {}).items()):
                if lines and len(lines) > 1:
                    out.append("    %s: %s" % (sname, " | ".join(l.replace("\n", " ") for l in lines[1:])))
    if sec in ("buffs", "all") and snap.get("buffs"):
        out.append("BUFFS: " + ", ".join(snap["buffs"]))
    return "\n".join(out)


def need_snapshot(args):
    snap, path = load_snapshot(getattr(args, "name", None), args.snap)
    if not snap:
        dirs = ", ".join(os.path.abspath(d) for d in snapshot_dirs())
        print("No character snapshot found (looked in: %s and <WoW>/WTF/.../SavedVariables/OctoAI.lua). "
              "In game, type /octo to export. Then either pass --wow <WoW folder> or --snap <octo_Name.json>, "
              "or upload octo_<Name>.json." % dirs)
        sys.exit(2)
    return snap, path


def cmd_char(args, ctx):
    snap, path = need_snapshot(args)
    if args.json:
        return json.dumps(snap, ensure_ascii=False, indent=1)
    sec = args.section or "default"
    if sec == "default":
        return "\n".join(section_text(snap, s, path) for s in ("summary", "stats", "talents", "equipment", "quests"))
    return section_text(snap, "summary", path) + "\n" + section_text(snap, sec, path)


def cmd_talents(args, ctx):
    snap, path = need_snapshot(args)
    t = snap.get("talents")
    if not t:
        return "snapshot has no talent data"
    c = snap.get("character") or {}
    out = ["TALENT TREES for %s (%s, level %s). Build %s, unspent points %s. Data read from the game client (authoritative for OctoWoW)." % (
        c.get("name"), c.get("class"), c.get("level"), t.get("build"), t.get("unspent"))]
    for tr in t.get("trees", []):
        out.append("\n== %s (%s points spent)" % (tr["name"], tr.get("spent")))
        bypos = {(x.get("tier"), x.get("col")): x for x in tr.get("talents", [])}
        for x in sorted(tr.get("talents", []), key=lambda x: (x.get("tier", 0), x.get("col", 0))):
            req = ""
            if x.get("requires"):
                r = bypos.get((x["requires"]["tier"], x["requires"]["col"]))
                req = " [requires %s]" % (r["name"] if r else x["requires"])
            out.append("  tier %s col %s: %s %s/%s%s -- %s" % (x.get("tier"), x.get("col"), x.get("name"), x.get("rank"), x.get("max"), req, talent_desc(x)))
    out.append("\nRules (vanilla engine): tier N needs 5*(N-1) points spent in that tree; first point at level 10, one per level.")
    return "\n".join(out)


def cmd_myquests(args, ctx):
    snap, path = need_snapshot(args)
    qs = load("quests")
    lines = ["QUEST LOG of %s, snapshot %s (%s). Player at %s %s." % (
        (snap.get("character") or {}).get("name"), snap.get("exportedAt"), age_text(snap, path), ctx.get("zone"),
        ("(%.1f, %.1f)" % (ctx["coords"]["x"], ctx["coords"]["y"])) if ctx.get("coords") else "")]
    for q in snap.get("quests", []):
        qid = q.get("id")
        if not qid:
            cands = [k for k in resolve("quests", q.get("title", "")) if k in qs and qs[k].get("lvl") == q.get("level") and quest_allowed(qs[k], ctx)]
            qid = cands[0] if len(cands) == 1 else None
        lines.append("")
        prog = "; ".join("%s%s" % (p.get("text"), " (done)" if p.get("done") else "") for p in q.get("progress") or [])
        lines.append("### %s (lvl %s) - %s%s" % (q.get("title"), q.get("level"), q.get("status"), (" - " + prog) if prog else ""))
        if not qid or str(qid) not in qs:
            lines.append("  not found in OctoQuestDatabase (custom or missing quest). In-game objective: %s%s" % (
                q.get("objective"), ("  (web: https://octowow.st/db/?quest=%s)" % q["id"]) if q.get("id") else ""))
            continue
        lines.append(describe_quest(qid, ctx, verbose=False))
    return "\n".join(lines)


def cmd_list(args, ctx):
    ents = snapshot_entries()
    if not ents:
        return "\n".join(["no snapshots found"] + SNAPSHOT_ERRORS)
    out = []
    for p, s in ents:
        c = s.get("character", {})
        out.append("%s: %s %s level %s, exported %s (%s)%s" % (c.get("name"), c.get("race"), c.get("class"), c.get("level"), s.get("exportedAt"), age_text(s, p),
                                                             "  [from SavedVariables: updates only on logout or /reload]" if p.endswith(".lua") else ""))
    return "\n".join(out + SNAPSHOT_ERRORS)


def main(argv=None):
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--snap", default=argparse.SUPPRESS, help="snapshot file to use")
    common.add_argument("--wow", default=argparse.SUPPRESS, help="WoW install folder (the one with WoW.exe)")
    common.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
    common.add_argument("--char", dest="as_char", default=argparse.SUPPRESS,
                        help="character whose snapshot gives context (faction/level/position)")
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter, parents=[common])
    sub = p.add_subparsers(dest="cmd", required=True)
    _add = sub.add_parser
    sub.add_parser = lambda name, **kw: _add(name, parents=[common], **kw)
    s = sub.add_parser("char"); s.add_argument("name", nargs="?"); s.add_argument("--section")
    s = sub.add_parser("talents"); s.add_argument("name", nargs="?")
    s = sub.add_parser("myquests"); s.add_argument("name", nargs="?")
    s = sub.add_parser("quest"); s.add_argument("query", nargs="+")
    s = sub.add_parser("npc"); s.add_argument("query", nargs="+")
    s = sub.add_parser("object"); s.add_argument("query", nargs="+")
    s = sub.add_parser("item"); s.add_argument("query", nargs="+")
    s = sub.add_parser("zone"); s.add_argument("name", nargs="+"); s.add_argument("--level", type=int)
    s.add_argument("--faction"); s.add_argument("--class", dest="cls"); s.add_argument("--limit", type=int, default=60)
    s = sub.add_parser("service"); s.add_argument("type"); s.add_argument("--zone", nargs="+"); s.add_argument("--faction")
    s = sub.add_parser("search"); s.add_argument("text", nargs="+")
    s = sub.add_parser("seen"); s.add_argument("query", nargs="+")
    sub.add_parser("events")
    sub.add_parser("list")
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:  # noqa
        pass
    args = p.parse_args(argv)
    for attr, default in (("snap", None), ("json", False), ("as_char", None), ("wow", None)):
        if not hasattr(args, attr):
            setattr(args, attr, default)
    global WOW_DIR
    if args.wow:
        WOW_DIR = args.wow
    for attr in ("query", "text"):
        if isinstance(getattr(args, attr, None), list):
            setattr(args, attr, " ".join(getattr(args, attr)))
    if args.cmd == "zone":
        args.name = " ".join(args.name)
    if args.cmd == "service" and args.zone:
        args.zone = " ".join(args.zone)

    ctx_name = args.as_char or (getattr(args, "name", None) if args.cmd in ("char", "talents", "myquests") else None)
    try:
        snap, _ = load_snapshot(ctx_name, args.snap)
    except (OSError, ValueError) as e:
        print("Cannot read snapshot %s: %s" % (args.snap, e))
        sys.exit(2)
    ctx = player_context(snap)

    fn = {"char": cmd_char, "talents": cmd_talents, "myquests": cmd_myquests, "quest": cmd_quest, "npc": cmd_npc,
          "object": cmd_object, "item": cmd_item, "zone": cmd_zone, "service": cmd_service, "search": cmd_search,
          "events": cmd_events, "list": cmd_list, "seen": cmd_seen}[args.cmd]
    out = fn(args, ctx)
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:  # noqa
        pass
    print(out)


if __name__ == "__main__":
    main()
