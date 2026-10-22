#!/usr/bin/env python3
"""Update Verbatim's Sparkle appcast: keep exactly one item per channel.

The feed holds a stable item (no <sparkle:channel>) and a beta item (<sparkle:channel>beta</sparkle:channel>).
This script parses the existing appcast (or starts a new one), replaces the item for the given channel, and
writes the file back. Items of the other channel are left as they are. See mac/Updates/README.md.

Example:
  python3 appcast.py appcast.xml --channel beta --version 123 --short-version 0.0.0 \
    --url https://github.com/stumpandroot/verbatim/releases/download/beta-123/Verbatim-universal.dmg \
    --length 123456 --signature BASE64== --notes "Build 123 from main" --notes-link https://github.com/...
"""
import argparse
import email.utils
import html
import os
import sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
FEED_URL = "https://raw.githubusercontent.com/stumpandroot/verbatim/updates/appcast.xml"
MIN_SYSTEM = "14.0"

ET.register_namespace("sparkle", SPARKLE)


def sp(tag):
    return "{%s}%s" % (SPARKLE, tag)


def new_feed():
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Verbose"
    ET.SubElement(channel, "link").text = FEED_URL
    ET.SubElement(channel, "description").text = "Verbose for Mac: tagged releases, plus beta builds of main."
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def item_channel(item):
    """The item's channel name, or "stable" when it has no <sparkle:channel>."""
    el = item.find(sp("channel"))
    name = (el.text or "").strip() if el is not None else ""
    return name or "stable"


def item_version(item):
    el = item.find(sp("version"))
    if el is None:
        enc = item.find("enclosure")
        text = enc.get(sp("version"), "") if enc is not None else ""
    else:
        text = el.text or ""
    try:
        return int(text.strip())
    except ValueError:
        return -1


def build_item(a):
    item = ET.Element("item")
    ET.SubElement(item, "title").text = a.title or "Verbose %s (%s)" % (a.short_version, a.version)
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    if a.channel != "stable":
        ET.SubElement(item, sp("channel")).text = a.channel
    ET.SubElement(item, sp("version")).text = str(a.version)
    ET.SubElement(item, sp("shortVersionString")).text = a.short_version
    ET.SubElement(item, sp("minimumSystemVersion")).text = MIN_SYSTEM
    if a.notes or a.notes_link:
        # Sparkle shows <description> as HTML in its update window. ElementTree escapes it; XML parsing undoes that.
        parts = []
        if a.notes:
            parts.append("<p>%s</p>" % html.escape(a.notes))
        if a.notes_link:
            parts.append('<p><a href="%s">Release notes on GitHub</a></p>' % html.escape(a.notes_link, quote=True))
        ET.SubElement(item, "description").text = "".join(parts)
    ET.SubElement(item, "enclosure", {
        "url": a.url,
        "length": str(a.length),
        "type": "application/octet-stream",
        sp("edSignature"): a.signature,
    })
    return item


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("appcast", help="path to appcast.xml (created if missing)")
    p.add_argument("--channel", required=True, help='"stable" (no channel element) or a channel name such as "beta"')
    p.add_argument("--version", required=True, type=int, help="sparkle:version = CFBundleVersion (the CI run number)")
    p.add_argument("--short-version", required=True, help="sparkle:shortVersionString = CFBundleShortVersionString")
    p.add_argument("--url", required=True, help="enclosure URL of the DMG")
    p.add_argument("--length", required=True, type=int, help="DMG size in bytes (from sign_update)")
    p.add_argument("--signature", required=True, help="sparkle:edSignature (from sign_update)")
    p.add_argument("--title", default="", help="item title (default: Verbose <short> (<version>))")
    p.add_argument("--notes", default="", help="one line of plain text for the update window")
    p.add_argument("--notes-link", default="", help="link shown under the notes, e.g. the GitHub release page")
    p.add_argument("--force", action="store_true", help="replace the channel's item even if it is newer")
    a = p.parse_args(argv)

    a.channel = a.channel.strip()
    if not a.channel:
        p.error("--channel is empty")
    if a.length <= 0:
        p.error("--length must be positive")
    if not a.signature.strip() or not a.url.startswith("https://"):
        p.error("--signature is empty or --url isn't https")

    if os.path.exists(a.appcast) and os.path.getsize(a.appcast) > 0:
        tree = ET.parse(a.appcast)
    else:
        tree = new_feed()
    rss = tree.getroot()
    if rss.tag != "rss":
        sys.exit("error: %s is not an RSS appcast" % a.appcast)
    channel = rss.find("channel")
    if channel is None:
        channel = ET.SubElement(rss, "channel")

    existing = [i for i in channel.findall("item") if item_channel(i) == a.channel]
    newest = max([item_version(i) for i in existing], default=-1)
    if newest > a.version and not a.force:
        print("appcast: kept %s item %d (newer than %d)" % (a.channel, newest, a.version))
        return 0
    for i in existing:
        channel.remove(i)
    channel.append(build_item(a))

    # Stable first, then other channels; Sparkle picks the newest allowed item regardless of order.
    items = channel.findall("item")
    for i in items:
        channel.remove(i)
    for i in sorted(items, key=lambda i: (item_channel(i) != "stable", item_channel(i))):
        channel.append(i)

    ET.indent(tree, space="  ")
    tmp = a.appcast + ".tmp"
    tree.write(tmp, encoding="utf-8", xml_declaration=True)
    with open(tmp, "a", encoding="utf-8") as f:
        f.write("\n")
    os.replace(tmp, a.appcast)
    print("appcast: %s -> %d (%s)" % (a.channel, a.version, a.short_version))
    return 0


if __name__ == "__main__":
    sys.exit(main())
