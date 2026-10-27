#!/usr/bin/env python3
"""Verbose's release notes (ReleaseNotes.json, bundled in the Mac and iPhone apps). See README.md in this folder.

  stamp <json> --build N [--date YYYY-MM-DD] [--version "1.0 beta"] [--project project.yml]
      CI, before each build: the "next" entry becomes build N, dated today (UTC) unless --date is given, in version
      --version (default: project.yml's MARKETING_VERSION and VERBOSE_CHANNEL, "1.0 beta"). Edits the working copy
      only; CI never commits it. With no "next" entry, or one for N already there, the file is left as it is.
  version [--project project.yml]
      The version a build of project.yml gets, as GitHub Actions outputs: marketing=1.0, channel=beta, and
      name=1.0 beta (../VERSIONING.md).
  notes <json> --build N [--format html|markdown|testflight]
      The entry for build N (or the "next" entry, in a checkout that wasn't stamped), sorted by platform: simple HTML
      for Sparkle's update window (Mac first, then "Also on iPhone and Apple Watch"), Markdown for the GitHub release
      (Mac, iPhone, and Apple Watch headings), or plain text for TestFlight's What to Test (iPhone, Apple Watch, then
      "Also on Mac", within TestFlight's 4,000 characters). Prints nothing, and exits 0, when there's neither.
  check <json>
      Fails unless the file is well formed: titles and items present, numbered builds descending, at most one
      "next", and it first; every item in "next" an object with valid platforms, a line of at most 90 characters, an
      optional detail of at most 200, no "Mac:"-style prefix, and no em dash or exclamation point.

Items are objects, {"platforms": ["iphone", "mac"], "text": "...", "detail": "..."}, or, in numbered entries only,
strings from before platforms were recorded, whose "Mac:", "iPhone:", "Apple Watch:", or "Mac and iPhone:" style
prefix gives their platforms (none: both apps). `summary` sorts a build's items for one app; every renderer, and the
apps' own parser (Verbatim/Model/ReleaseNotes.swift, `ReleaseNotes.summary`), sorts them the same way.
"""
import argparse
import datetime
import html
import json
import os
import re
import sys

NEXT = "next"
# Entries without a "version" belong to the first one: every build before versions were recorded was 1.0 beta.
FIRST_VERSION = "1.0 beta"
PROJECT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "project.yml")

# Platforms, in the order the GitHub release lists them, and their names.
PLATFORMS = ("mac", "iphone", "watch")
NAMES = {"mac": "Mac", "iphone": "iPhone", "watch": "Apple Watch"}
# Each app's own platforms, then the others it folds under "Also on ...". A change for both apps is in each app's own
# section; in each list, an item goes under the first platform it names.
APPS = {"iphone": (("iphone", "watch"), ("mac",)), "mac": (("mac",), ("iphone", "watch"))}
TEXT_MAX, DETAIL_MAX = 90, 200
# TestFlight's What to Test takes 4,000 characters.
TESTFLIGHT_MAX = 4000
# A string item's platform prefix: "Mac:", "iPhone:", "Apple Watch:", "Mac and iPhone:", "iPhone and Mac:", or a
# platform and an area, such as "Mac Home:" (the area stays: "Home: ...").
LEGACY = (("Mac and iPhone", ("iphone", "mac")), ("iPhone and Mac", ("iphone", "mac")), ("Apple Watch", ("watch",)),
          ("iPhone", ("iphone",)), ("Mac", ("mac",)))
LEGACY_RE = re.compile(r"^(Mac and iPhone|iPhone and Mac|Apple Watch|iPhone|Mac)(?: ([A-Za-z]+))?:\s+")


def legacy_prefix(s):
    """(platforms, text) for a string with a platform prefix, the prefix taken off; None without one."""
    m = LEGACY_RE.match(s)
    if not m:
        return None
    platforms = dict(LEGACY)[m.group(1)]
    rest = s[m.end():]
    area = m.group(2)
    if area:
        return list(platforms), area[0].upper() + area[1:] + ": " + rest
    return list(platforms), capitalized(rest)


def capitalized(s):
    """The first letter in capitals, unless the first word already has one ("iPhone", "⌘K")."""
    word = s.split(" ", 1)[0]
    if not s or any(c.isupper() for c in word):
        return s
    return s[0].upper() + s[1:]


def item_of(raw):
    """An item as {"platforms", "text", "detail"}: an object as written (unknown platforms dropped; none counts as
    both apps), or a string with its prefix read and taken off."""
    if isinstance(raw, str):
        found = legacy_prefix(raw.strip())
        platforms, text = found if found else (["iphone", "mac"], raw.strip())
        return {"platforms": platforms, "text": text, "detail": None}
    raw = raw if isinstance(raw, dict) else {}
    names = raw.get("platforms") if isinstance(raw.get("platforms"), list) else []
    platforms = [p for p in names if isinstance(p, str) and p in PLATFORMS]
    text = raw.get("text") if isinstance(raw.get("text"), str) else ""
    detail = raw.get("detail") if isinstance(raw.get("detail"), str) and raw.get("detail").strip() else None
    return {"platforms": platforms or ["iphone", "mac"], "text": text.strip(), "detail": detail.strip() if detail else None}


def join_and(names):
    """ "iPhone", "iPhone and Apple Watch", or "Mac, iPhone, and Apple Watch". """
    if len(names) <= 2:
        return " and ".join(names)
    return ", ".join(names[:-1]) + ", and " + names[-1]


def summary(raw_items, app):
    """A build's items for one app ("iphone" or "mac"): (sections, also, also_title). `sections` are the app's own
    platforms in order, each (platform, [items]); `also` the other platforms' items, folded under `also_title` ("Also
    on Mac"). Each item appears once, under the first of the app's platforms it names, or else under the first other
    platform it names; empty sections are left out. Verbatim/Model/ReleaseNotes.swift's `summary` matches it."""
    own, other = APPS[app]
    items = [item_of(r) for r in raw_items]
    def first(item, order):
        return next((p for p in order if p in item["platforms"]), None)
    sections = [(p, [i for i in items if first(i, own) == p]) for p in own]
    also = [(p, [i for i in items if first(i, own) is None and first(i, other) == p]) for p in other]
    sections = [s for s in sections if s[1]]
    also = [s for s in also if s[1]]
    return sections, also, ("Also on " + join_and([NAMES[p] for p, _ in also])) if also else ""


def by_platform(raw_items):
    """Every platform with its items, in PLATFORMS order (the GitHub release): an item for two platforms is in both."""
    items = [item_of(r) for r in raw_items]
    out = [(p, [i for i in items if p in i["platforms"]]) for p in PLATFORMS]
    return [s for s in out if s[1]]


def line(item, detail=True):
    """An item as one line: the text, then its detail when there is one and `detail` is on."""
    return item["text"] + (" " + item["detail"] if detail and item["detail"] else "")


def project_version(path):
    """(marketing, channel) from project.yml's MARKETING_VERSION and VERBOSE_CHANNEL; the first of each wins."""
    marketing = channel = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'\s*(MARKETING_VERSION|VERBOSE_CHANNEL):\s*"?([^"#]*?)"?\s*(#.*)?$', line)
            if not m:
                continue
            if m.group(1) == "MARKETING_VERSION" and marketing is None:
                marketing = m.group(2).strip()
            elif m.group(1) == "VERBOSE_CHANNEL" and channel is None:
                channel = m.group(2).strip()
    if not marketing or not re.fullmatch(r"[0-9]+(\.[0-9]+){0,2}", marketing):
        raise ValueError("%s has no numeric MARKETING_VERSION (found %r)" % (path, marketing))
    return marketing, channel or ""


def version_name(marketing, channel):
    """ "1.0 beta", or "1.0" with no channel: what the apps show before the build number."""
    return ("%s %s" % (marketing, channel)).strip()


def load(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get("notes"), list):
        raise ValueError("expected an object with a \"notes\" list")
    return data


def problems(data):
    """Every way the file breaks the rules, as sentences; empty when it's fine."""
    out, last = [], None
    notes = data.get("notes") if isinstance(data, dict) else None
    if not isinstance(notes, list):
        return ["expected an object with a \"notes\" list"]
    if not notes:
        out.append("there are no entries")
    nexts = 0
    for i, n in enumerate(notes):
        where = "entry %d" % (i + 1)
        if not isinstance(n, dict):
            out.append("%s isn't an object" % where)
            continue
        build = n.get("build")
        if not isinstance(build, str) or not (build == NEXT or re.fullmatch(r"[1-9][0-9]*", build)):
            out.append("%s: build must be \"next\" or a run number as a string, not %r" % (where, build))
            continue
        where = "build %s" % build
        if build == NEXT:
            nexts += 1
            if i != 0:
                out.append("the \"next\" entry must come first")
        else:
            if last is not None and int(build) >= last:
                out.append("%s: builds must go down, newest first (%s comes after %d)" % (where, build, last))
            last = int(build)
            if "date" not in n:
                out.append("%s has no date" % where)
        date = n.get("date")
        if date is not None and not (isinstance(date, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", date)):
            out.append("%s: date must be YYYY-MM-DD, not %r" % (where, date))
        if "version" in n and not (isinstance(n["version"], str) and n["version"].strip()):
            out.append("%s: version must be a name such as \"1.0 beta\", not %r" % (where, n["version"]))
        if not isinstance(n.get("title"), str) or not n["title"].strip():
            out.append("%s has no title" % where)
        items = n.get("items")
        if not isinstance(items, list) or not items:
            out.append("%s needs one or more items" % where)
        else:
            for j, item in enumerate(items):
                out.extend(item_problems(item, "%s, item %d" % (where, j + 1), build == NEXT))
    if nexts > 1:
        out.append("there are %d \"next\" entries; keep one" % nexts)
    return out


def item_problems(item, where, in_next):
    """What's wrong with one item, as sentences. Strings are fine only in numbered entries (builds from before
    platforms were recorded); objects follow the rules in README.md."""
    if isinstance(item, str):
        if in_next:
            return ["%s is a string; write it as {\"platforms\": [...], \"text\": \"...\"} (README.md)" % where]
        return [] if item.strip() else ["%s is empty" % where]
    if not isinstance(item, dict):
        return ["%s must be an object with platforms and text" % where]
    out = []
    extra = sorted(k for k in item if k not in ("platforms", "text", "detail"))
    if extra:
        out.append("%s has unknown keys: %s" % (where, ", ".join(extra)))
    platforms = item.get("platforms")
    if not isinstance(platforms, list) or not platforms:
        out.append("%s needs platforms, a list of %s" % (where, ", ".join(PLATFORMS)))
    else:
        bad = [p for p in platforms if not (isinstance(p, str) and p in PLATFORMS)]
        if bad:
            out.append("%s: platforms must be %s, not %s" % (where, ", ".join(PLATFORMS), ", ".join(repr(b) for b in bad)))
        if len(set(map(str, platforms))) != len(platforms):
            out.append("%s names a platform twice" % where)
    text = item.get("text")
    if not isinstance(text, str) or not text.strip():
        out.append("%s has no text" % where)
    else:
        out.extend(line_problems(text, where + "'s text", TEXT_MAX))
        if LEGACY_RE.match(text.strip()):
            out.append("%s starts with a platform (\"%s\"); platforms say that" % (where, text.split(":", 1)[0] + ":"))
    if "detail" in item:
        detail = item["detail"]
        if not isinstance(detail, str) or not detail.strip():
            out.append("%s: detail must be a sentence; leave it out when there's nothing to add" % where)
        else:
            out.extend(line_problems(detail, where + "'s detail", DETAIL_MAX))
    return out


def line_problems(s, where, limit):
    out = []
    if len(s) > limit:
        out.append("%s is %d characters; keep it to %d" % (where, len(s), limit))
    if "\u2014" in s:
        out.append("%s has an em dash" % where)
    if "!" in s:
        out.append("%s has an exclamation point" % where)
    if not (s.strip().endswith(".") or s.strip().endswith(".)")):
        out.append("%s doesn't end with a period" % where)
    return out


def write(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def stamp(path, build, date, version):
    data = load(path)
    notes = data["notes"]
    if any(n.get("build") == str(build) for n in notes):
        print("release notes: build %d already has an entry; left as it is" % build)
        return 0
    entry = next((n for n in notes if n.get("build") == NEXT), None)
    if entry is None:
        print("release notes: no \"next\" entry; left as it is")
        return 0
    # Keep the keys in the file's order: build, date, version, title, items.
    rest = {k: v for k, v in entry.items() if k not in ("build", "date", "version")}
    entry.clear()
    entry.update({"build": str(build), "date": date, **({"version": version} if version else {}), **rest})
    write(path, data)
    print("release notes: \"next\" is now build %d of %s (%s): %s" % (build, version or FIRST_VERSION, date, entry.get("title", "")))
    return 0


def entry_for(data, build):
    notes = data["notes"]
    return next((n for n in notes if n.get("build") == str(build)), None) \
        or next((n for n in notes if n.get("build") == NEXT), None)


def render(entry, fmt):
    title = entry.get("title", "").strip()
    items = entry.get("items", []) if isinstance(entry.get("items"), list) else []
    if fmt == "markdown":
        return render_markdown(title, items)
    if fmt == "testflight":
        return render_testflight(title, items)
    return render_html(title, items)


def esc(s):
    return html.escape(s, quote=False)


def render_html(title, items):
    """Sparkle's update window, which only the Mac app shows: the Mac's items (with details), then the rest under
    "Also on iPhone and Apple Watch" (lines only)."""
    sections, also, also_title = summary(items, "mac")
    parts = ["<h3>%s</h3>" % esc(title)] if title else []
    for p, its in sections:
        parts.append("<h4>%s</h4><ul>%s</ul>" % (esc(NAMES[p]), "".join("<li>%s</li>" % esc(line(i)) for i in its)))
    if also:
        parts.append("<h4>%s</h4>" % esc(also_title))
        for p, its in also:
            if len(also) > 1:
                parts.append("<p><b>%s</b></p>" % esc(NAMES[p]))
            parts.append("<ul>%s</ul>" % "".join("<li>%s</li>" % esc(line(i, detail=False)) for i in its))
    return "".join(parts)


def render_markdown(title, items):
    """The GitHub release: a heading per platform (Mac, iPhone, Apple Watch); a change for two is under both."""
    lines = (["**%s**" % title, ""] if title else [])
    for p, its in by_platform(items):
        lines += ["### %s" % NAMES[p], ""] + ["- %s" % line(i) for i in its] + [""]
    return "\n".join(lines).rstrip("\n")


def render_testflight(title, items, limit=TESTFLIGHT_MAX):
    """TestFlight's What to Test, plain text: iPhone, Apple Watch, then "Also on Mac". Over `limit` characters, the
    details go first, then the Mac's items from the end, with "And more." in their place."""
    sections, also, also_title = summary(items, "iphone")
    others = [(p, i) for p, its in also for i in its]

    def build(detail, keep):
        out = [title, ""] if title else []
        for p, its in sections:
            out += [NAMES[p]] + ["- " + line(i, detail) for i in its] + [""]
        if others:
            out.append(also_title)
            last = None
            for p, i in others[:keep]:
                if len(also) > 1 and p != last:
                    out.append(NAMES[p] + ":")
                    last = p
                out.append("- " + line(i, detail))
            if keep < len(others):
                out.append("- And more.")
        return "\n".join(out).rstrip("\n")

    text = build(True, len(others))
    if len(text) <= limit:
        return text
    for keep in range(len(others), -1, -1):
        text = build(False, keep)
        if len(text) <= limit:
            return text
    # Even the iPhone's lines alone are too long: cut at the last whole line that fits.
    return text[:limit].rsplit("\n", 1)[0]


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stamp", help="turn the \"next\" entry into this build")
    s.add_argument("json")
    s.add_argument("--build", required=True, type=int)
    s.add_argument("--date", default="", help="YYYY-MM-DD (default: today, UTC)")
    s.add_argument("--version", default=None, help='the version name, such as "1.0 beta" (default: from --project)')
    s.add_argument("--project", default=PROJECT, help="project.yml to read the version from (default: ../project.yml)")
    v = sub.add_parser("version", help="print the version project.yml builds, as GitHub Actions outputs")
    v.add_argument("--project", default=PROJECT)
    n = sub.add_parser("notes", help="print a build's entry as HTML, Markdown, or TestFlight's plain text")
    n.add_argument("json")
    n.add_argument("--build", required=True, type=int)
    n.add_argument("--format", choices=("html", "markdown", "testflight"), default="html")
    c = sub.add_parser("check", help="validate the file")
    c.add_argument("json")
    a = p.parse_args(argv)

    if a.cmd == "check":
        try:
            found = problems(load(a.json))
        except (OSError, ValueError) as e:
            found = [str(e)]
        for f in found:
            print("release notes: %s" % f, file=sys.stderr)
        if not found:
            print("release notes: OK")
        return 1 if found else 0

    if a.cmd == "version":
        try:
            marketing, channel = project_version(a.project)
        except (OSError, ValueError) as e:
            print("release notes: %s" % e, file=sys.stderr)
            return 1
        print("marketing=%s\nchannel=%s\nname=%s" % (marketing, channel, version_name(marketing, channel)))
        return 0

    if a.build <= 0:
        p.error("--build must be positive")
    if a.cmd == "stamp":
        date = a.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
            p.error("--date must be YYYY-MM-DD")
        version = a.version.strip() if a.version is not None else None
        if version is None:
            try:
                version = version_name(*project_version(a.project))
            except (OSError, ValueError) as e:
                print("release notes: %s; the entry gets no version" % e, file=sys.stderr)
                version = ""
        return stamp(a.json, a.build, date, version)

    # notes: never fails a release; a missing or broken file means no notes, and the caller falls back.
    try:
        entry = entry_for(load(a.json), a.build)
    except (OSError, ValueError) as e:
        print("release notes: %s" % e, file=sys.stderr)
        return 0
    if entry:
        print(render(entry, a.format))
    return 0


if __name__ == "__main__":
    sys.exit(main())
