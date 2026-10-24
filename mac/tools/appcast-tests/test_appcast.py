"""Tests for mac/Updates/appcast.py: one item per channel, stable first, newer items kept. Run by test-appcast.sh."""
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "Updates", "appcast.py")
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPO = "https://github.com/stumpandroot/verbose-updates"


def sp(tag):
    return "{%s}%s" % (SPARKLE, tag)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.feed = os.path.join(self.dir.name, "appcast.xml")

    def tearDown(self):
        self.dir.cleanup()

    def run_appcast(self, channel, version, tag=None, extra=(), check=True):
        tag = tag or ("beta-%d" % version)
        args = [sys.executable, "-I", SCRIPT, self.feed, "--channel", channel, "--version", str(version),
                "--short-version", "0.0.0", "--url", "%s/releases/download/%s/Verbose.dmg" % (REPO, tag),
                "--length", "1000", "--signature", "SIG%d==" % version, *extra]
        return subprocess.run(args, capture_output=True, text=True, check=check)

    def items(self):
        channel = ET.parse(self.feed).getroot().find("channel")
        out = []
        for i in channel.findall("item"):
            ch = i.find(sp("channel"))
            out.append(((ch.text if ch is not None else "stable"), int(i.find(sp("version")).text),
                        i.find("enclosure").get("url")))
        return out

    def test_new_feed_links_to_the_updates_repo(self):
        self.run_appcast("beta", 10)
        channel = ET.parse(self.feed).getroot().find("channel")
        self.assertEqual(channel.find("link").text,
                         "https://raw.githubusercontent.com/stumpandroot/verbose-updates/main/appcast.xml")
        self.assertEqual(self.items(), [("beta", 10, REPO + "/releases/download/beta-10/Verbose.dmg")])
        enc = channel.find("item").find("enclosure")
        self.assertEqual(enc.get(sp("edSignature")), "SIG10==")
        self.assertEqual(enc.get("length"), "1000")

    def test_one_item_per_channel_stable_first(self):
        self.run_appcast("beta", 10)
        self.run_appcast("stable", 8, tag="mac-v1.0.0")
        self.run_appcast("beta", 11)
        self.assertEqual([(c, v) for c, v, _ in self.items()], [("stable", 8), ("beta", 11)])
        stable = ET.parse(self.feed).getroot().find("channel").find("item")
        self.assertIsNone(stable.find(sp("channel")))

    def test_older_build_keeps_the_newer_item_unless_forced(self):
        self.run_appcast("beta", 12)
        r = self.run_appcast("beta", 11)
        self.assertIn("kept beta item 12", r.stdout)
        self.assertEqual([(c, v) for c, v, _ in self.items()], [("beta", 12)])
        self.run_appcast("beta", 11, extra=["--force"])
        self.assertEqual([(c, v) for c, v, _ in self.items()], [("beta", 11)])

    def test_notes_are_escaped_html(self):
        self.run_appcast("beta", 5, extra=["--notes", "a <b> & c", "--notes-link", REPO + "/releases/tag/beta-5"])
        desc = ET.parse(self.feed).getroot().find("channel").find("item").find("description").text
        self.assertIn("<p>a &lt;b&gt; &amp; c</p>", desc)
        self.assertIn('href="%s/releases/tag/beta-5"' % REPO, desc)

    def test_rejects_bad_input(self):
        r = self.run_appcast("beta", 5, extra=["--url", "http://example.com/x.dmg"], check=False)
        self.assertNotEqual(r.returncode, 0)
        r = self.run_appcast("beta", 5, extra=["--length", "0"], check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(self.feed))


if __name__ == "__main__":
    unittest.main(verbosity=2)
