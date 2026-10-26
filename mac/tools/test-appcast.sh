#!/bin/bash
# Tests the Sparkle update publishing in mac/Updates: appcast.py (appcast-tests/test_appcast.py), then
# publish-update.sh and publish-appcast.sh against a local bare repo standing in for stumpandroot/verbose-updates,
# with stand-ins for gh and curl, so nothing reaches GitHub. Needs only python3, git, and bash.
#   bash mac/tools/test-appcast.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
updates="$here/../Updates"
python3 -I "$here/appcast-tests/test_appcast.py"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
fails=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fails=$((fails + 1)); fi; }

# gh stand-in: keeps the release list in state/releases and logs every call.
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
# One line per call: release notes span lines.
printf 'gh %s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >> "$STATE/gh.log"
[ "$1" = release ] || exit 2
cmd="$2"; tag="$3"; rel="$STATE/releases"; touch "$rel"
case "$cmd" in
  view) grep -qx "$tag" "$rel" ;;
  create) echo "$tag" >> "$rel" ;;
  upload|edit) grep -qx "$tag" "$rel" ;;
  list) grep -E '^beta-[0-9]+$' "$rel" || true ;;
  delete) grep -vx "$tag" "$rel" > "$rel.new" || true; mv "$rel.new" "$rel" ;;
  *) exit 2 ;;
esac
EOF
printf '#!/bin/bash\necho "curl $*" >> "$STATE/curl.log"\n' > "$T/bin/curl"
chmod +x "$T/bin/gh" "$T/bin/curl"

# The updates repo: a main branch with only a README, as Tim creates it.
git init -q --bare -b main "$T/remote.git"
git clone -q "$T/remote.git" "$T/seed" 2>/dev/null
git -C "$T/seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
echo "# verbose-updates" > "$T/seed/README.md"
git -C "$T/seed" add README.md && git -C "$T/seed" -c user.name=t -c user.email=t@t commit -q -m readme
git -C "$T/seed" push -q origin HEAD:main
echo "fake dmg" > "$T/Verbatim-universal.dmg"

publish() { # publish <ref> <run number> <short version>; RELEASE_NOTES (optional) picks the release notes file
  PATH="$T/bin:$PATH" RELEASE_NOTES="${RELEASE_NOTES:-$here/../ReleaseNotes/ReleaseNotes.json}" STATE="$T/state" APPCAST_REMOTE="$T/remote.git" UPDATES_TOKEN=test-token-value \
    GITHUB_REF="$1" GITHUB_RUN_NUMBER="$2" SIG="SIG$2==" LEN=9 SHORT="$3" BUNDLE="$2" \
    bash "$updates/publish-update.sh" "$T/Verbatim-universal.dmg"
}
feed() { git -C "$T/seed" pull -q origin main && cat "$T/seed/appcast.xml"; }
R=https://github.com/stumpandroot/verbose-updates

publish refs/heads/main 101 "1.0 beta"
F="$(feed)"
# Versions (mac/VERSIONING.md): the update window reads "Verbose 1.0 beta (101)"; Sparkle compares the build number.
check "main build: sparkle:shortVersionString is 1.0 beta, sparkle:version the build" \
  'grep -q "<sparkle:shortVersionString>1.0 beta</sparkle:shortVersionString>" <<< "$F" && grep -q "<sparkle:version>101</sparkle:version>" <<< "$F"'
check "main build: beta-101 and beta-latest are prereleases" \
  'grep -q "release create beta-101 .*--prerelease" "$T/state/gh.log" && grep -q "release create beta-latest .*--prerelease" "$T/state/gh.log"'
check "main build: the asset is Verbose.dmg" 'grep -q "release create beta-101 [^ ]*/Verbose.dmg -R stumpandroot/verbose-updates" "$T/state/gh.log"'
check "main build: the feed's beta item points at beta-101" 'grep -q "url=\"$R/releases/download/beta-101/Verbose.dmg\"" <<< "$F"'
check "main build: the download was checked before the feed changed" 'grep -q "$R/releases/download/beta-101/Verbose.dmg" "$T/state/curl.log"'
check "main build: the README stays" '[ -f "$T/seed/README.md" ]'
# The repo's release notes have a "next" entry (unstamped checkout): its title and items reach Sparkle and GitHub.
NEXT_TITLE="$(python3 -c 'import json,sys; n=json.load(open(sys.argv[1]))["notes"][0]; print(n["title"] if n["build"]=="next" else "")' "$here/../ReleaseNotes/ReleaseNotes.json")"
desc() { python3 -c 'import sys,xml.etree.ElementTree as E; i=[x for x in E.fromstring(sys.argv[1]).find("channel").findall("item") if x.find("{http://www.andymatuschak.org/xml-namespaces/sparkle}channel") is not None][0]; print(i.find("description").text)' "$1"; }
if [ -n "$NEXT_TITLE" ]; then
  D="$(desc "$F")"
  check "main build: the appcast description carries the next entry's title and items" \
    'grep -qF "<h3>$NEXT_TITLE</h3>" <<< "$D" && grep -q "<ul><li>" <<< "$D" && grep -q "Release notes on GitHub" <<< "$D"'
  check "main build: the GitHub release body carries them as Markdown" \
    'grep "release create beta-101 " "$T/state/gh.log" | grep -qF -- "**$NEXT_TITLE**  - "'
fi

printf 'beta-%s\n' 95 96 97 98 99 100 >> "$T/state/releases"
: > "$T/state/gh.log"
# A notes file with no entry for 102 and no "next": the one-line text stands in.
printf '{"notes": [{"build": "90", "date": "2026-10-01", "title": "Old", "items": ["Old item."]}]}\n' > "$T/old-notes.json"
RELEASE_NOTES="$T/old-notes.json" publish refs/heads/main 102 "1.0 beta"
F="$(feed)"
check "no notes for the build: the appcast falls back to the one-line text" 'grep -q "Beta build 102 of main." <<< "$(desc "$F")" && ! grep -q "Old item" <<< "$(desc "$F")"'
check "no notes for the build: the release body falls back too" \
  'grep "release create beta-102 " "$T/state/gh.log" | grep -q "stable channel. --prerelease"' 
check "re-publishing beta-latest replaces its DMG" 'grep -q "release upload beta-latest .*--clobber" "$T/state/gh.log"'
check "only the newest five betas are kept" \
  '[ "$(grep -E "^beta-[0-9]+$" "$T/state/releases" | sort -t- -k2,2 -n | tr "\n" " ")" = "beta-98 beta-99 beta-100 beta-101 beta-102 " ]'
check "old betas are deleted with their tags" 'grep -q "release delete beta-95 .*--cleanup-tag" "$T/state/gh.log"'
check "beta-latest is never pruned" 'grep -qx beta-latest "$T/state/releases"'

: > "$T/state/gh.log"
publish refs/tags/mac-v1.2.0 103 1.2.0
F="$(feed)"
check "stable tag: a release marked latest" 'grep -q "release create mac-v1.2.0 .*--latest" "$T/state/gh.log"'
check "stable tag: the feed's stable item points at the release" \
  'python3 -c "import sys,xml.etree.ElementTree as E; i=E.fromstring(sys.argv[1]).find(\"channel\").findall(\"item\"); sys.exit(not (len(i)==2 and i[0].find(\"enclosure\").get(\"url\")==\"$R/releases/download/mac-v1.2.0/Verbose.dmg\"))" "$F"'

: > "$T/state/gh.log"
publish refs/tags/mac-v1.3.0-beta.1 104 1.3.0
F="$(feed)"
check "prerelease tag: a prerelease on the beta channel" \
  'grep -q "release create mac-v1.3.0-beta.1 .*--prerelease" "$T/state/gh.log" && grep -q "releases/download/mac-v1.3.0-beta.1/Verbose.dmg" <<< "$F"'
check "the token never appears in a command line" '! grep -rq test-token-value "$T/state"'
check "other refs are refused" '! publish refs/heads/feature 105 0.0.0 > /dev/null 2>&1'

if [ "$fails" -gt 0 ]; then echo "$fails publishing check(s) failed"; exit 1; fi
echo "All appcast and publishing checks passed."
