#!/bin/bash
# What's new: checks mac/ReleaseNotes/ReleaseNotes.json with the app's own parser (Verbatim/Model/ReleaseNotes.swift,
# compiled with release-notes-tests/main.swift) and with release_notes.py, then runs CI's stamping on a copy (never
# the file itself) and checks the result, the version it records (mac/VERSIONING.md), that the apps and the script
# sort items by platform the same way, the Sparkle, GitHub, and TestFlight renderings, and the fallbacks. Needs a
# Swift toolchain and python3 (macOS or Linux), not Xcode.
#   bash mac/tools/test-release-notes.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
notes="$here/../ReleaseNotes/ReleaseNotes.json"
py="$here/../ReleaseNotes/release_notes.py"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
fails=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }

python3 -I "$py" check "$notes"

# A copy with a "next" entry on top: the file as it is, or with one added when every entry already has a build.
python3 -I - "$notes" "$out/before.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
if not d["notes"] or d["notes"][0].get("build") != "next":
    d["notes"].insert(0, {"build": "next", "title": "Test entry", "items": [
        {"platforms": ["mac"], "text": "A change you can see on the Mac.", "detail": "More about it."},
        {"platforms": ["iphone", "mac"], "text": "A change for both apps."},
        {"platforms": ["iphone"], "text": "A change on iPhone."},
        {"platforms": ["watch"], "text": "A change on Apple Watch."}]})
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
EOF
top="$(python3 -I -c 'import json,sys; print(max(int(n["build"]) for n in json.load(open(sys.argv[1]))["notes"] if n["build"] != "next"))' "$out/before.json")"
N=$((top + 7))
cp "$out/before.json" "$out/stamped.json"
python3 -I "$py" stamp "$out/stamped.json" --build "$N"
python3 -I "$py" check "$out/stamped.json"

swiftc -O -o "$out/release-notes-tests" "$here/../Verbatim/Model/ReleaseNotes.swift" "$here/release-notes-tests/main.swift"
# The version project.yml builds ("1.0 beta"), which stamping records with the build number.
VNAME="$(python3 -I "$py" version | sed -n 's/^name=//p')"
"$out/release-notes-tests" "$notes" "$out/before.json" "$out/stamped.json" "$N" "$VNAME" || fails=$((fails + 1))

check "version: project.yml's marketing version is numbers only, and the outputs agree" \
  'python3 -I "$py" version > "$out/v.txt" && grep -Eqx "marketing=[0-9]+(\.[0-9]+){0,2}" "$out/v.txt" && [ "$(sed -n "s/^name=//p" "$out/v.txt")" = "$(sed -n "s/^marketing=//p" "$out/v.txt")$(sed -n "s/^channel=\(..*\)/ \1/p" "$out/v.txt")" ]'
check "version: every target takes project.yml's one MARKETING_VERSION (no target sets its own)" \
  '[ "$(grep -c "^ *MARKETING_VERSION:" "$here/../project.yml")" = 1 ]'
check "stamping records the version from project.yml" 'grep -qF "\"version\": \"$VNAME\"" "$out/stamped.json"'
check "stamping takes --version" \
  'cp "$out/before.json" "$out/v2.json" && python3 -I "$py" stamp "$out/v2.json" --build "$N" --version "2.1" > /dev/null && grep -q "\"version\": \"2.1\"" "$out/v2.json"'
printf 'settings:\n  base:\n    MARKETING_VERSION: "1.0"\n    VERBOSE_CHANNEL: ""\n' > "$out/store.yml"
check "no channel (the App Store release): the version is 1.0" \
  'cp "$out/before.json" "$out/v3.json" && python3 -I "$py" stamp "$out/v3.json" --build "$N" --project "$out/store.yml" > /dev/null && grep -q "\"version\": \"1.0\"," "$out/v3.json"'
check "a project with no version: stamping still works, with no version" \
  'cp "$out/before.json" "$out/v4.json" && : > "$out/none.yml" && python3 -I "$py" stamp "$out/v4.json" --build "$N" --project "$out/none.yml" > /dev/null 2>&1 && python3 -I "$py" check "$out/v4.json" > /dev/null && ! python3 -I -c "import json,sys; sys.exit(\"version\" not in json.load(open(sys.argv[1]))[\"notes\"][0])" "$out/v4.json"'

check "stamping twice changes nothing" \
  'cp "$out/stamped.json" "$out/again.json" && python3 -I "$py" stamp "$out/again.json" --build "$N" > /dev/null && cmp -s "$out/stamped.json" "$out/again.json"'
check "a later run doesn't restamp an entry already stamped" \
  'cp "$out/stamped.json" "$out/later.json" && python3 -I "$py" stamp "$out/later.json" --build $((N + 1)) > /dev/null && cmp -s "$out/stamped.json" "$out/later.json"'
check "stamping takes --date" \
  'cp "$out/before.json" "$out/dated.json" && python3 -I "$py" stamp "$out/dated.json" --build "$N" --date 2026-01-02 > /dev/null && grep -q "\"date\": \"2026-01-02\"" "$out/dated.json"'
check "the file in the repo is never stamped" 'grep -q "\"build\": \"$N\"" "$out/stamped.json" && ! grep -q "\"build\": \"$N\"" "$notes"'

# Checks that take more than a line of shell, in Python: `verify.py <what> <args>` exits 0 when it holds.
cat > "$out/verify.py" <<'EOF'
import importlib.util, json, sys
what, args = sys.argv[1], sys.argv[2:]

def module(path):
    spec = importlib.util.spec_from_file_location("release_notes", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def top_items(path):
    return json.load(open(path, encoding="utf-8"))["notes"][0]["items"]

if what == "summary":  # every build sorted for each app and GitHub, as the Swift test's --summary prints it
    rn = module(args[0])
    for n in json.load(open(args[1], encoding="utf-8"))["notes"]:
        for app in ("iphone", "mac"):
            sections, also, title = rn.summary(n["items"], app)
            for where, secs in (("own", sections), (title, also)):
                for p, its in secs:
                    for i in its:
                        print("\t".join([n["build"], app, where, p, i["text"], i["detail"] or ""]))
        for p, its in rn.by_platform(n["items"]):
            for i in its:
                print("\t".join([n["build"], "github", "", p, i["text"], i["detail"] or ""]))
    sys.exit(0)

if what == "html-order":  # the Mac's section first, then Also on, when there's anything to fold
    html, path = args
    items = top_items(path)
    other = any(not ("mac" in i["platforms"]) for i in items if isinstance(i, dict))
    mac, also = html.find("<h4>Mac</h4>"), html.find("<h4>Also on ")
    sys.exit(0 if mac >= 0 and (also > mac if other else also == -1) else 1)

if what == "md-headings":  # the GitHub release: Mac, iPhone, Apple Watch headings in order, a bullet per platform named
    md, path = args
    items = top_items(path)
    want = ["### " + n for p, n in (("mac", "Mac"), ("iphone", "iPhone"), ("watch", "Apple Watch")) if any(p in i["platforms"] for i in items)]
    got = [l for l in md.split("\n") if l.startswith("### ")]
    bullets = sum(1 for l in md.split("\n") if l.startswith("- "))
    sys.exit(0 if got == want and bullets == sum(len(i["platforms"]) for i in items) else 1)

if what == "testflight-order":  # iPhone, Apple Watch, Also on Mac, each once and in that order; plain text
    text = args[0]
    order = ["iPhone", "Apple Watch", "Also on Mac"]
    heads = [l for l in text.split("\n") if l in order]
    sys.exit(0 if heads == sorted(heads, key=order.index) and len(set(heads)) == len(heads) and heads and "<" not in text else 1)

if what == "fits":  # within TestFlight's 4,000 characters
    sys.exit(0 if len(args[0]) <= 4000 else 1)

if what == "details-kept":  # every detail of the top entry is in the text
    text, path = args
    sys.exit(0 if all(i["detail"] in text for i in top_items(path) if i.get("detail")) else 1)

if what == "small":  # writes a short build with a detail on each platform
    items = [{"platforms": ["mac"], "text": "On the Mac.", "detail": "Mac detail."}, {"platforms": ["iphone", "mac"], "text": "Both.", "detail": "Both detail."},
             {"platforms": ["iphone"], "text": "On iPhone.", "detail": "iPhone detail."}, {"platforms": ["watch"], "text": "On the watch.", "detail": "Watch detail."}]
    json.dump({"notes": [{"build": "5", "date": "2026-10-01", "title": "Small", "items": items}]}, open(args[0], "w"))
    sys.exit(0)

if what == "long":  # writes a build too long for TestFlight
    items = [{"platforms": ["iphone"], "text": "iPhone change %d with a line about this long." % i, "detail": "D" * 150 + "."} for i in range(20)]
    items += [{"platforms": ["mac"], "text": "Mac change %d with a line about this long, too." % i, "detail": "M" * 150 + "."} for i in range(80)]
    json.dump({"notes": [{"build": "5", "date": "2026-10-01", "title": "Long", "items": items}]}, open(args[0], "w"))
    sys.exit(0)

if what == "long-ok":  # details dropped, every iPhone line kept, the Mac's cut short with "And more."
    text = args[0]
    lines = text.split("\n")
    ok = (len(text) <= 4000 and "DDDD" not in text and sum(l.startswith("- iPhone change") for l in lines) == 20
          and lines[-1] == "- And more." and any(l.startswith("- Mac change 0 ") for l in lines)
          and sum(l.startswith("- Mac change") for l in lines) < 80)
    sys.exit(0 if ok else 1)

sys.exit("unknown check " + what)
EOF
V() { python3 -I "$out/verify.py" "$@"; }

# The apps' parser and the script sort every build's items the same way, for the iPhone app, the Mac app, and GitHub.
"$out/release-notes-tests" --summary "$out/stamped.json" > "$out/swift-summary.txt"
V summary "$py" "$out/stamped.json" > "$out/py-summary.txt"
check "platforms: the apps and release_notes.py sort every build's items the same way" \
  '[ -s "$out/swift-summary.txt" ] && { cmp -s "$out/swift-summary.txt" "$out/py-summary.txt" || { diff "$out/swift-summary.txt" "$out/py-summary.txt" | head -n 10; false; }; }'

TITLE="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["notes"][0]["title"])' "$out/stamped.json")"
HTML="$(python3 -I "$py" notes "$out/stamped.json" --build "$N")"
MD="$(python3 -I "$py" notes "$out/stamped.json" --build "$N" --format markdown)"
TF="$(python3 -I "$py" notes "$out/stamped.json" --build "$N" --format testflight)"
# The Mac-first checks need a top entry with a Mac item; after an iPhone-only catch-up the next entry may have none.
HASMAC="$(python3 -I -c 'import json,sys; n=json.load(open(sys.argv[1]))["notes"][0]; print(any(isinstance(i,dict) and "mac" in i.get("platforms",[]) or isinstance(i,str) for i in n["items"]))' "$out/stamped.json")"
if [ "$HASMAC" = "True" ]; then
check "Sparkle: the build's title, then the Mac's items" 'grep -qF "<h3>$TITLE</h3><h4>Mac</h4><ul><li>" <<< "$HTML" && [[ "$HTML" == *"</li></ul>" ]]'
check "Sparkle: the iPhone and Apple Watch items fold under Also on, after the Mac's" 'V html-order "$HTML" "$out/stamped.json"'
else
  check "Sparkle: with no Mac items, the build's title and the folded items still render" 'grep -qF "<h3>$TITLE</h3>" <<< "$HTML"'
fi
check "Sparkle: the HTML parses (no stray markup from the text)" 'python3 -I -c "import sys,xml.etree.ElementTree as E; E.fromstring(\"<d>\" + sys.argv[1] + \"</d>\")" "$HTML"'
check "GitHub: the title in bold" '[ "$(head -n 1 <<< "$MD")" = "**$TITLE**" ]'
check "GitHub: Mac, iPhone, and Apple Watch headings in that order, a bullet under each platform an item names" 'V md-headings "$MD" "$out/stamped.json"'
check "TestFlight: the title first" '[ "$(head -n 1 <<< "$TF")" = "$TITLE" ]'
check "TestFlight: plain text, iPhone, then Apple Watch, then Also on Mac" 'V testflight-order "$TF"'
check "TestFlight: within its 4,000 characters" 'V fits "$TF"'
V small "$out/small.json"
SMALL="$(python3 -I "$py" notes "$out/small.json" --build 5 --format testflight)"
check "TestFlight: a short build keeps its details, and its Mac item under Also on Mac" \
  'V details-kept "$SMALL" "$out/small.json" && V testflight-order "$SMALL" && [ "$(tail -n 1 <<< "$SMALL")" = "- On the Mac. Mac detail." ]'
V long "$out/long.json"
LONG="$(python3 -I "$py" notes "$out/long.json" --build 5 --format testflight)"
check "TestFlight: a long build drops details, keeps every iPhone line, and cuts the Mac's with And more." 'V long-ok "$LONG"'
check "an unstamped checkout (the updates job) uses the next entry" \
  '[ "$(python3 -I "$py" notes "$out/before.json" --build "$N")" = "$HTML" ]'
check "an older build gets its own entry, its string items under platform headings without their prefixes" \
  'H="$(python3 -I "$py" notes "$notes" --build "$top")" && grep -q "<h3>" <<< "$H" && grep -q "<h4>" <<< "$H" && ! grep -qE "<li>(Mac|iPhone|Apple Watch|Mac and iPhone): " <<< "$H"'
check "no entry and no next: prints nothing (the caller falls back)" \
  '[ -z "$(python3 -I "$py" notes "$out/stamped.json" --build $((N + 50)))" ]'
check "a missing file: prints nothing and doesn't fail" \
  '[ -z "$(python3 -I "$py" notes "$out/missing.json" --build 1 2> /dev/null)" ] && [ -z "$(python3 -I "$py" notes "$out/missing.json" --build 1 --format testflight 2> /dev/null)" ]'
printf '{"notes": [{"build": "next", "title": "A", "items": [{"platforms": ["mac"], "text": "x."}]}, {"build": "next", "title": "B", "items": [{"platforms": ["mac"], "text": "y."}]}, {"build": "3", "date": "2026-01-01", "title": "C", "items": ["z."]}, {"build": "4", "date": "2026-01-02", "title": "D", "items": ["w."]}]}\n' > "$out/bad.json"
check "check: two next entries and builds going up fail" '! python3 -I "$py" check "$out/bad.json" 2> /dev/null'
printf '{"notes": [{"build": "3", "date": "2026-01-01", "version": "", "title": "C", "items": ["z."]}]}\n' > "$out/badversion.json"
check "check: an empty version fails" '! python3 -I "$py" check "$out/badversion.json" 2> /dev/null'

# The item rules. bad_item <item as JSON>: true when check rejects a "next" entry holding that item.
bad_item() { printf '{"notes": [{"build": "next", "title": "A", "items": [%s]}]}\n' "$1" > "$out/item.json"; ! python3 -I "$py" check "$out/item.json" > /dev/null 2>&1; }
A90="$(printf 'a%.0s' $(seq 90))"; A89="$(printf 'a%.0s' $(seq 89))"; A200="$(printf 'a%.0s' $(seq 200))"; A199="$(printf 'a%.0s' $(seq 199))"
check "check: a good object item passes" '! bad_item "{\"platforms\": [\"iphone\", \"mac\"], \"text\": \"Tap Record.\", \"detail\": \"Touch and hold opens Record as.\"}"'
check "check: a string item in next fails" 'bad_item "\"iPhone: tap Record.\""'
check "check: missing, empty, unknown, or repeated platforms fail" \
  'bad_item "{\"text\": \"A.\"}" && bad_item "{\"platforms\": [], \"text\": \"A.\"}" && bad_item "{\"platforms\": [\"ipad\"], \"text\": \"A.\"}" && bad_item "{\"platforms\": [\"mac\", \"mac\"], \"text\": \"A.\"}"'
check "check: a line over 90 characters fails, and 90 passes" \
  'bad_item "{\"platforms\": [\"mac\"], \"text\": \"$A90.\"}" && ! bad_item "{\"platforms\": [\"mac\"], \"text\": \"$A89.\"}"'
check "check: a detail over 200 characters fails, and 200 passes" \
  'bad_item "{\"platforms\": [\"mac\"], \"text\": \"A.\", \"detail\": \"$A200.\"}" && ! bad_item "{\"platforms\": [\"mac\"], \"text\": \"A.\", \"detail\": \"$A199.\"}"'
check "check: a Mac:-style prefix, an em dash, an exclamation point, or no period fails" \
  'bad_item "{\"platforms\": [\"mac\"], \"text\": \"Mac: press it.\"}" && bad_item "{\"platforms\": [\"mac\"], \"text\": \"A \\u2014 b.\"}" && bad_item "{\"platforms\": [\"mac\"], \"text\": \"Wow!\"}" && bad_item "{\"platforms\": [\"mac\"], \"text\": \"A\"}"'
check "check: an empty detail or an unknown key fails" \
  'bad_item "{\"platforms\": [\"mac\"], \"text\": \"A.\", \"detail\": \"\"}" && bad_item "{\"platforms\": [\"mac\"], \"text\": \"A.\", \"note\": \"x\"}"'
printf '{"notes": [{"build": "3", "date": "2026-01-01", "title": "C", "items": ["Mac: z."]}]}\n' > "$out/old.json"
check "check: strings stay valid in numbered builds" 'python3 -I "$py" check "$out/old.json" > /dev/null'

# TestFlight's What to Test (testflight_what_to_test.py, the build's last TestFlight step): ES256 signing with a
# throwaway key, and the API calls against a stand-in for App Store Connect. No network, no real key.
wtt="$here/../ReleaseNotes/testflight_what_to_test.py"
if command -v openssl > /dev/null; then
  openssl ecparam -genkey -name prime256v1 -noout 2> /dev/null | openssl pkcs8 -topk8 -nocrypt -out "$out/throwaway.p8"
  check "What to Test: the App Store Connect token is ES256 and verifies" 'python3 -I "$wtt" jwt-check --key "$out/throwaway.p8" > /dev/null'
fi
cat > "$out/wtt-fake.py" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wtt", sys.argv[1])
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
what = sys.argv[2]

class Fake:
    """App Store Connect: build 7 processes after two checks; `existing` says whether en-US is already there."""
    def __init__(self, existing=False, state_after="VALID", checks=2):
        self.calls, self.n, self.existing, self.state_after, self.checks = [], 0, existing, state_after, checks
    def call(self, method, path, query=None, body=None):
        self.calls.append((method, path, query, body))
        if path == "/v1/apps":
            return {"data": [{"id": "app1", "attributes": {"bundleId": query["filter[bundleId]"]}}]}
        if path == "/v1/builds":
            self.n += 1
            if self.n == 1:
                return {"data": []}
            state = self.state_after if self.n > self.checks else "PROCESSING"
            return {"data": [{"id": "b7", "attributes": {"version": query["filter[version]"], "processingState": state}}]}
        if path.endswith("/betaBuildLocalizations") and method == "GET":
            return {"data": [{"id": "loc1", "attributes": {"locale": "en-US", "whatsNew": "old"}}] if self.existing else []}
        return {}

clock = [0]
tick = lambda: clock[0]
def sleep(s): clock[0] += s

if what == "create":
    f = Fake()
    bid = w.wait_for_build(f, w.find_app(f, "co.stumpandroot.verbatim.ios"), 7, 1200, 30, clock=tick, sleep=sleep)
    how = w.set_what_to_test(f, bid, "Notes.")
    post = f.calls[-1]
    ok = (bid == "b7" and how == "created" and post[0] == "POST" and post[1] == "/v1/betaBuildLocalizations"
          and post[3]["data"]["attributes"] == {"locale": "en-US", "whatsNew": "Notes."}
          and post[3]["data"]["relationships"]["build"]["data"] == {"type": "builds", "id": "b7"}
          and all(c[2].get("filter[preReleaseVersion.platform]") == "IOS" for c in f.calls if c[1] == "/v1/builds"))
    sys.exit(0 if ok else 1)
if what == "update":
    f = Fake(existing=True)
    how = w.set_what_to_test(f, "b7", "Notes.")
    patch = f.calls[-1]
    sys.exit(0 if how == "updated" and patch[0] == "PATCH" and patch[1] == "/v1/betaBuildLocalizations/loc1"
             and patch[3]["data"] == {"type": "betaBuildLocalizations", "id": "loc1", "attributes": {"whatsNew": "Notes."}} else 1)
if what == "timeout":
    f = Fake(checks=10**6)
    try:
        w.wait_for_build(f, "app1", 7, 1200, 30, clock=tick, sleep=sleep)
    except w.Problem as e:
        sys.exit(0 if "wasn't processed within 20 minutes" in str(e) and clock[0] <= 1200 else 1)
    sys.exit(1)
if what == "failed":
    f = Fake(state_after="INVALID")
    try:
        w.wait_for_build(f, "app1", 7, 1200, 30, clock=tick, sleep=sleep)
    except w.Problem as e:
        sys.exit(0 if "INVALID" in str(e) else 1)
    sys.exit(1)
sys.exit("unknown check " + what)
EOF
check "What to Test: waits for processing, then creates the en-US localization for the build" 'python3 -I "$out/wtt-fake.py" "$wtt" create > /dev/null'
check "What to Test: updates the en-US localization when there is one" 'python3 -I "$out/wtt-fake.py" "$wtt" update > /dev/null'
check "What to Test: gives up after 20 minutes of processing, or when processing fails" \
  'python3 -I "$out/wtt-fake.py" "$wtt" timeout > /dev/null && python3 -I "$out/wtt-fake.py" "$wtt" failed > /dev/null'
printf '' > "$out/empty.txt"
check "What to Test: no notes, no call, no failure" \
  'env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH python3 -I "$wtt" set --text "$out/empty.txt" --build 7 > /dev/null'
printf 'Notes.\n' > "$out/wtt.txt"
check "What to Test: without the key it fails with a reason (the workflow warns), and names no secret" \
  '! env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH python3 -I "$wtt" set --text "$out/wtt.txt" --build 7 2> "$out/wtt.err" && grep -q "must be set" "$out/wtt.err"'
check "What to Test: takes the public track's build number (7.1), not a stray value" \
  '! env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH python3 -I "$wtt" set --text "$out/wtt.txt" --build 7.1 2> "$out/wtt.err" && grep -q "must be set" "$out/wtt.err" && ! python3 -I "$wtt" set --text "$out/wtt.txt" --build 7x 2> /dev/null'

# The public TestFlight link (testflight_share.py, the public track's last step): the group, Test Information, and
# Beta App Review steps against a stand-in for App Store Connect.
share="$here/../ReleaseNotes/testflight_share.py"
check "Public link: makes the group once, fills in Test Information, adds and submits the build, and stops without a review phone" \
  'python3 -I "$share" share-check > /dev/null'
check "Public link: without the key it fails with a reason" \
  '! env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH python3 -I "$share" share --build 7.1 --feedback-email a@b.c 2> "$out/share.err" && grep -q "must be set" "$out/share.err"'
# The workflow shares only the public track; the public and store tracks never carry YouTube on the iPhone, only
# the store track (N.2, for App Review) leaves out the beta unlock (mac/APP_STORE.md).
wf="$here/../../.github/workflows/build-swift.yml"
check "Public link: the public track builds without YOUTUBE_ON_DEVICE, the store track without BETA_UNLOCK, and only public is shared" \
  'grep -qF "PHONE_CONDITIONS: \${{ matrix.track == '"'public'"' && '"'APP_STORE BETA_UNLOCK'"' || (matrix.track == '"'store'"' && '"'APP_STORE'"' || '"'APP_STORE YOUTUBE_ON_DEVICE BETA_UNLOCK'"') }}" "$wf" && grep -qF "VERBATIM_PHONE_CONDITIONS_YES=\$PHONE_CONDITIONS" "$wf" && grep -qF "if: matrix.track == '"'public'"' && env.HAS_ASC" "$wf"'

if [ "$fails" -gt 0 ]; then echo "$fails release notes check(s) failed"; exit 1; fi
echo "All release notes checks passed."
