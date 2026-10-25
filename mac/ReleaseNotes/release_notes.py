#!/usr/bin/env python3
"""Verbose's release notes (ReleaseNotes.json, bundled in the Mac and iPhone apps). See README.md in this folder.

  stamp <json> --build N [--date YYYY-MM-DD]
      CI, before each build: the "next" entry becomes build N, dated today (UTC) unless --date is given. Edits the
      working copy only; CI never commits it. With no "next" entry, or one for N already there, the file is left as
      it is.
  notes <json> --build N [--format html|markdown]
      The entry for build N (or the "next" entry, in a checkout that wasn't stamped) as simple HTML for Sparkle's
      update window or Markdown for the GitHub release. Prints nothing, and exits 0, when there's neither.
  check <json>
      Fails unless the file is well formed: titles and items present, numbered builds descending, at most one
      "next", and it first.
"""
import argparse
import datetime
import html
import json
import os
import re
import sys

NEXT = "next"


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
        if not isinstance(n.get("title"), str) or not n["title"].strip():
            out.append("%s has no title" % where)
        items = n.get("items")
        if not isinstance(items, list) or not items or not all(isinstance(s, str) and s.strip() for s in items):
            out.append("%s needs one or more items, each a non-empty string" % where)
    if nexts > 1:
        out.append("there are %d \"next\" entries; keep one" % nexts)
    return out


def write(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def stamp(path, build, date):
    data = load(path)
    notes = data["notes"]
    if any(n.get("build") == str(build) for n in notes):
        print("release notes: build %d already has an entry; left as it is" % build)
        return 0
    entry = next((n for n in notes if n.get("build") == NEXT), None)
    if entry is None:
        print("release notes: no \"next\" entry; left as it is")
        return 0
    # Keep the keys in the file's order: build, date, title, items.
    rest = {k: v for k, v in entry.items() if k not in ("build", "date")}
    entry.clear()
    entry.update({"build": str(build), "date": date, **rest})
    write(path, data)
    print("release notes: \"next\" is now build %d (%s): %s" % (build, date, entry.get("title", "")))
    return 0


def entry_for(data, build):
    notes = data["notes"]
    return next((n for n in notes if n.get("build") == str(build)), None) \
        or next((n for n in notes if n.get("build") == NEXT), None)


def render(entry, fmt):
    title = entry.get("title", "").strip()
    items = [s.strip() for s in entry.get("items", []) if isinstance(s, str) and s.strip()]
    if fmt == "markdown":
        lines = (["**%s**" % title, ""] if title else []) + ["- %s" % s for s in items]
        return "\n".join(lines)
    parts = []
    if title:
        parts.append("<h3>%s</h3>" % html.escape(title, quote=False))
    if items:
        parts.append("<ul>%s</ul>" % "".join("<li>%s</li>" % html.escape(s, quote=False) for s in items))
    return "".join(parts)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("stamp", help="turn the \"next\" entry into this build")
    s.add_argument("json")
    s.add_argument("--build", required=True, type=int)
    s.add_argument("--date", default="", help="YYYY-MM-DD (default: today, UTC)")
    n = sub.add_parser("notes", help="print a build's entry as HTML or Markdown")
    n.add_argument("json")
    n.add_argument("--build", required=True, type=int)
    n.add_argument("--format", choices=("html", "markdown"), default="html")
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

    if a.build <= 0:
        p.error("--build must be positive")
    if a.cmd == "stamp":
        date = a.date or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
            p.error("--date must be YYYY-MM-DD")
        return stamp(a.json, a.build, date)

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
