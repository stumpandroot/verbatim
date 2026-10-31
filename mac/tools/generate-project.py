#!/usr/bin/env python3
"""The Apple Watch switch for mac/project.yml (DESIGN.md §20), used by tools/generate-project.sh.

The iPhone app embeds the watch app through one dependency, written between two marker lines:

    # >>> Apple Watch ...
    - target: VerbatimWatch
    # <<< Apple Watch

With VERBOSE_WATCH=NO, generate-project.sh writes a copy of project.yml without those lines and runs XcodeGen on the
copy, so the iPhone app builds, signs, and ships without the watch app. The watch targets stay defined; nothing
depends on them, so nothing builds them.

  python3 generate-project.py --strip project.yml .project-nowatch.yml
  python3 generate-project.py --check project.yml    (the Linux tests, tools/test-watch.sh)
"""
import re
import sys

BEGIN = "# >>> Apple Watch"
END = "# <<< Apple Watch"
# The YouTubeKit switch (App Review AR-05): VERBOSE_YOUTUBEKIT=NO drops the iPhone app's YouTubeKit dependency.
YT_BEGIN = "# >>> YouTubeKit"
YT_END = "# <<< YouTubeKit"


def block(lines, begin=BEGIN, end=END):
    """The (begin, end) line indexes of the marked block. Raises ValueError unless there's exactly one, in order."""
    begins = [i for i, l in enumerate(lines) if l.strip().startswith(begin)]
    ends = [i for i, l in enumerate(lines) if l.strip().startswith(end)]
    if len(begins) != 1 or len(ends) != 1 or begins[0] >= ends[0]:
        raise ValueError(f"project.yml needs one '{begin}' line and then one '{end}' line "
                         f"(found {len(begins)} and {len(ends)})")
    return begins[0], ends[0]


def strip(text, begin=BEGIN, end=END):
    lines = text.splitlines(keepends=True)
    b, e = block(lines, begin, end)
    return "".join(lines[:b] + lines[e + 1:])


def target_names(text):
    """Top-level target names under `targets:` (two-space indents, as project.yml is written)."""
    names, inside = [], False
    for line in text.splitlines():
        if line and not line.startswith(" "):
            inside = line.strip() == "targets:"
            continue
        m = re.match(r"^  ([A-Za-z][A-Za-z0-9_]*):\s*$", line)
        if inside and m:
            names.append(m.group(1))
    return names


def check(path):
    text = open(path, encoding="utf-8").read()
    lines = text.splitlines()
    fails = 0

    def ok(name, cond):
        nonlocal fails
        print(("PASS  " if cond else "FAIL  ") + name)
        if not cond:
            fails += 1

    try:
        b, e = block(lines)
    except ValueError as err:
        ok(f"switch: {err}", False)
        return 1
    inner = [l.strip() for l in lines[b + 1:e] if l.strip() and not l.strip().startswith("#")]
    ok("switch: the marked lines hold only the iPhone app's dependency on the watch app", inner == ["- target: VerbatimWatch"])
    # The block sits in VerbatimPhone's dependencies: the nearest target name above it is VerbatimPhone.
    owner = next((m.group(1) for l in reversed(lines[:b]) for m in [re.match(r"^  ([A-Za-z][A-Za-z0-9_]*):\s*$", l)] if m), None)
    ok("switch: the marked dependency belongs to VerbatimPhone", owner == "VerbatimPhone")
    stripped = strip(text)
    ok("switch: without the watch, nothing depends on VerbatimWatch", "target: VerbatimWatch\n" not in stripped
       and not re.search(r"-\s*target:\s*VerbatimWatch\s*$", stripped, re.M))
    ok("switch: without the watch, every target is still defined", target_names(stripped) == target_names(text))
    ok("switch: the watch app and its complications are targets",
       {"VerbatimWatch", "VerbatimWatchWidgets"} <= set(target_names(text)))
    ok("switch: only the marked lines change", len(stripped.splitlines()) == len(lines) - (e - b + 1))
    ok("switch: the watch app embeds its complications",
       re.search(r"^  VerbatimWatch:\n(?:(?!^  \S).*\n)*?\s+- target: VerbatimWatchWidgets\s*$", text, re.M) is not None)
    # The YouTubeKit switch.
    try:
        yb, ye = block(lines, YT_BEGIN, YT_END)
    except ValueError as err:
        ok(f"youtubekit: {err}", False)
        return 1
    yinner = [l.strip() for l in lines[yb + 1:ye] if l.strip() and not l.strip().startswith("#")]
    ok("youtubekit: the marked lines hold only the YouTubeKit dependency", yinner == ["- package: YouTubeKit", "product: YouTubeKit"])
    yowner = next((m.group(1) for l in reversed(lines[:yb]) for m in [re.match(r"^  ([A-Za-z][A-Za-z0-9_]*):\s*$", l)] if m), None)
    ok("youtubekit: the marked dependency belongs to VerbatimPhone", yowner == "VerbatimPhone")
    ystripped = strip(text, YT_BEGIN, YT_END)
    ok("youtubekit: without it, nothing depends on YouTubeKit", not re.search(r"-\s*package:\s*YouTubeKit\s*$", ystripped, re.M))
    ok("youtubekit: both switches apply together", target_names(strip(ystripped)) == target_names(text))
    return 1 if fails else 0


def main(argv):
    if len(argv) == 3 and argv[0] in ("--strip", "--strip-youtubekit"):
        src, dest = argv[1], argv[2]
        with open(src, encoding="utf-8") as f:
            text = f.read()
        out = strip(text) if argv[0] == "--strip" else strip(text, YT_BEGIN, YT_END)
        with open(dest, "w", encoding="utf-8") as f:
            f.write(out)
        return 0
    if len(argv) == 2 and argv[0] == "--check":
        return check(argv[1])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
