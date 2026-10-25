#!/bin/bash
# What's new: checks mac/ReleaseNotes/ReleaseNotes.json with the app's own parser (Verbatim/Model/ReleaseNotes.swift,
# compiled with release-notes-tests/main.swift) and with release_notes.py, then runs CI's stamping on a copy (never
# the file itself) and checks the result, the Sparkle and GitHub renderings, and the fallbacks. Needs a Swift
# toolchain and python3 (macOS or Linux), not Xcode.
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
    d["notes"].insert(0, {"build": "next", "title": "Test entry", "items": ["A change you can see."]})
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
EOF
top="$(python3 -I -c 'import json,sys; print(max(int(n["build"]) for n in json.load(open(sys.argv[1]))["notes"] if n["build"] != "next"))' "$out/before.json")"
N=$((top + 7))
cp "$out/before.json" "$out/stamped.json"
python3 -I "$py" stamp "$out/stamped.json" --build "$N"
python3 -I "$py" check "$out/stamped.json"

swiftc -O -o "$out/release-notes-tests" "$here/../Verbatim/Model/ReleaseNotes.swift" "$here/release-notes-tests/main.swift"
"$out/release-notes-tests" "$notes" "$out/before.json" "$out/stamped.json" "$N" || fails=$((fails + 1))

check "stamping twice changes nothing" \
  'cp "$out/stamped.json" "$out/again.json" && python3 -I "$py" stamp "$out/again.json" --build "$N" > /dev/null && cmp -s "$out/stamped.json" "$out/again.json"'
check "a later run doesn't restamp an entry already stamped" \
  'cp "$out/stamped.json" "$out/later.json" && python3 -I "$py" stamp "$out/later.json" --build $((N + 1)) > /dev/null && cmp -s "$out/stamped.json" "$out/later.json"'
check "stamping takes --date" \
  'cp "$out/before.json" "$out/dated.json" && python3 -I "$py" stamp "$out/dated.json" --build "$N" --date 2026-01-02 > /dev/null && grep -q "\"date\": \"2026-01-02\"" "$out/dated.json"'
check "the file in the repo is never stamped" 'grep -q "\"build\": \"$N\"" "$out/stamped.json" && ! grep -q "\"build\": \"$N\"" "$notes"'

TITLE="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["notes"][0]["title"])' "$out/stamped.json")"
HTML="$(python3 -I "$py" notes "$out/stamped.json" --build "$N")"
MD="$(python3 -I "$py" notes "$out/stamped.json" --build "$N" --format markdown)"
check "Sparkle: the build's title and items as HTML" 'grep -qF "<h3>$TITLE</h3><ul><li>" <<< "$HTML" && [[ "$HTML" == *"</li></ul>" ]]'
check "Sparkle: the HTML parses (no stray markup from the text)" 'python3 -I -c "import sys,xml.etree.ElementTree as E; E.fromstring(\"<d>\" + sys.argv[1] + \"</d>\")" "$HTML"'
check "GitHub: the title in bold, then one bullet per item" \
  '[ "$(head -n 1 <<< "$MD")" = "**$TITLE**" ] && [ "$(grep -c "^- " <<< "$MD")" = "$(python3 -I -c "import json,sys; print(len(json.load(open(sys.argv[1]))[\"notes\"][0][\"items\"]))" "$out/stamped.json")" ]'
check "an unstamped checkout (the updates job) uses the next entry" \
  '[ "$(python3 -I "$py" notes "$out/before.json" --build "$N")" = "$HTML" ]'
check "an older build gets its own entry" \
  'python3 -I "$py" notes "$notes" --build "$top" | grep -q "<h3>"'
check "no entry and no next: prints nothing (the caller falls back)" \
  '[ -z "$(python3 -I "$py" notes "$out/stamped.json" --build $((N + 50)))" ]'
check "a missing file: prints nothing and doesn't fail" \
  '[ -z "$(python3 -I "$py" notes "$out/missing.json" --build 1 2> /dev/null)" ]'
printf '{"notes": [{"build": "next", "title": "A", "items": ["x."]}, {"build": "next", "title": "B", "items": ["y."]}, {"build": "3", "date": "2026-01-01", "title": "C", "items": ["z."]}, {"build": "4", "date": "2026-01-02", "title": "D", "items": ["w."]}]}\n' > "$out/bad.json"
check "check: two next entries and builds going up fail" '! python3 -I "$py" check "$out/bad.json" 2> /dev/null'

if [ "$fails" -gt 0 ]; then echo "$fails release notes check(s) failed"; exit 1; fi
echo "All release notes checks passed."
