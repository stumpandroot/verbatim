#!/usr/bin/env python3
"""Which apps a change touches, so CI compiles and tests only those (check-swift.yml, build-swift.yml).

Usage, from the repository root: python3 .github/workflows/scripts/ci-targets.py BASE HEAD
Prints `mac=true|false` and `phone=true|false`, one per line, for $GITHUB_OUTPUT.

A changed file counts for an app when it's in the sources of one of that app's targets in mac/project.yml (the Mac
app: the macOS targets; the iPhone app: every other target, which includes the keyboard, widget, share, and broadcast
extensions and the Mac folders they share), or when every build reads it (BOTH). Anything else, such as docs,
mac/tools, mac/Bench, mac/Updates, or the build and signing scripts, needs neither compile. When anything goes wrong
the answer is true for both, so a mistake costs minutes, never a check.
"""
import re
import subprocess
import sys

# Read by every build: the project, package pins, the vendored and third-party builds, and CI itself.
BOTH = ("mac/project.yml", "mac/Package.resolved", "mac/Vendor/", "mac/harper-ffi/", "mac/ffmpeg/",
        "mac/tools/package-resolved.sh", "mac/tools/generate-project.sh", "mac/tools/generate-project.py", ".github/workflows/")


def targets(text):
    """{target: [platform, [source paths]]} from the targets section of project.yml. Reads this file's own layout
    (two-space indents; sources as `- path` or `- path: path`), so it needs no YAML library."""
    out, name, in_targets, in_sources = {}, None, False, False
    for line in text.splitlines():
        body = line.strip()
        if not body or body.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            in_targets, name = body == "targets:", None
            continue
        if not in_targets:
            continue
        if indent == 2 and body.endswith(":"):
            name, in_sources = body[:-1], False
            out[name] = ["", []]
        elif name is None:
            continue
        elif indent == 4:
            in_sources = body == "sources:"
            m = re.match(r"platform:\s*(\S+)", body)
            if m:
                out[name][0] = m.group(1)
        elif indent == 6 and in_sources:
            m = re.match(r"-\s*(?:path:\s*)?([\"']?)([^\"'#\s]+)\1\s*(?:#.*)?$", body)
            if m:
                out[name][1].append(m.group(2).rstrip("/"))
    return out


def decide(base, head):
    files = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", base, head],
                           check=True, capture_output=True, text=True).stdout.split("\0")
    files = [f for f in files if f]
    with open("mac/project.yml", encoding="utf-8") as f:
        found = targets(f.read())
    mac_src = [p for plat, srcs in found.values() if plat == "macOS" for p in srcs]
    phone_src = [p for plat, srcs in found.values() if plat != "macOS" for p in srcs]
    if not mac_src or not phone_src:
        raise ValueError("couldn't read the targets' sources from mac/project.yml")

    def under(f, paths):
        return f.startswith("mac/") and any(f[4:] == p or f[4:].startswith(p + "/") for p in paths)

    mac = phone = False
    for f in files:
        both = f in BOTH or any(b.endswith("/") and f.startswith(b) for b in BOTH)
        mac = mac or both or under(f, mac_src)
        phone = phone or both or under(f, phone_src)
    print(f"{len(files)} changed files between {base[:7]} and {head[:7]}", file=sys.stderr)
    for f in files[:200]:
        print(f"  {f}", file=sys.stderr)
    return mac, phone


def main():
    try:
        mac, phone = decide(sys.argv[1], sys.argv[2])
    except Exception as e:  # noqa: BLE001 (any failure means: run everything)
        print(f"::warning::Couldn't tell which apps changed ({e}); running both.", file=sys.stderr)
        mac = phone = True
    print(f"mac={'true' if mac else 'false'}")
    print(f"phone={'true' if phone else 'false'}")


if __name__ == "__main__":
    main()
