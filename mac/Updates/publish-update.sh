#!/usr/bin/env bash
# Publishes a signed, notarized DMG to the public updates repo (stumpandroot/verbose-updates) and points the appcast
# at it. CI only: the `updates` job of .github/workflows/build-swift.yml. See mac/Updates/README.md.
#
#   Build of main      -> prerelease beta-<run> with Verbose.dmg (newest five kept), beta-latest's Verbose.dmg
#                         replaced, and the feed's beta item pointed at beta-<run>.
#   Tag mac-v1.2.0     -> release mac-v1.2.0 with Verbose.dmg, marked latest; the feed's stable item.
#   Tag mac-v1.3.0-b.1 -> prerelease mac-v1.3.0-b.1 with Verbose.dmg; the feed's beta item.
#
# The DMG goes up before the feed changes, so the feed never points at a missing file. Feed items point at the
# per-build release, never at beta-latest, whose file changes with every build.
#
# Usage: publish-update.sh <path to the DMG>
# Env:   UPDATES_TOKEN (Contents read/write on the updates repo only), UPDATES_REPO (default
#        stumpandroot/verbose-updates), GITHUB_REF, GITHUB_REF_NAME, GITHUB_RUN_NUMBER, and the build's Sparkle
#        values SIG, LEN, SHORT, BUNDLE.
set -euo pipefail
: "${UPDATES_TOKEN:?}" "${GITHUB_REF:?}" "${GITHUB_RUN_NUMBER:?}" "${SIG:?}" "${LEN:?}" "${SHORT:?}" "${BUNDLE:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:?usage: publish-update.sh <dmg>}"
R="${UPDATES_REPO:-stumpandroot/verbose-updates}"
export UPDATES_REPO="$R"
# gh reads the token from GH_TOKEN; it never appears in a command line.
export GH_TOKEN="$UPDATES_TOKEN"
N="$GITHUB_RUN_NUMBER"
ASSET=Verbose.dmg
KEEP_BETAS=5

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
DMG="$W/$ASSET"
cp "$SRC" "$DMG"

download_url() { echo "https://github.com/${R}/releases/download/$1/${ASSET}"; }
release_page() { echo "https://github.com/${R}/releases/tag/$1"; }

# release_put <tag> <title> <notes> <prerelease|latest>: creates the release with the DMG, or replaces the DMG on an
# existing one (a re-run keeps the run number). New tags point at the updates repo's main branch.
release_put() {
  local tag="$1" title="$2" notes="$3" kind="$4" flag
  if [ "$kind" = prerelease ]; then flag=--prerelease; else flag=--latest; fi
  if gh release view "$tag" -R "$R" > /dev/null 2>&1; then
    gh release upload "$tag" "$DMG" -R "$R" --clobber
    gh release edit "$tag" -R "$R" --title "$title" --notes "$notes" "$flag" > /dev/null
  else
    gh release create "$tag" "$DMG" -R "$R" --target main --title "$title" --notes "$notes" "$flag" > /dev/null
  fi
  echo "Uploaded $ASSET to $(release_page "$tag")"
}

# Fails when the public download URL doesn't serve the file, for example because the updates repo is private.
check_download() {
  local url="$1" i
  for i in 1 2 3 4 5; do
    if curl -fsSL -r 0-0 -o /dev/null "$url"; then echo "Checked $url"; return 0; fi
    sleep $((i * 3))
  done
  echo "::error::$url isn't downloadable without signing in. Is $R public?"; return 1
}

if [ "$GITHUB_REF" = refs/heads/main ]; then
  TAG="beta-${N}"
  release_put "$TAG" "Beta build ${N}" \
    "Automatic beta build ${N} of main. For testing; tagged releases are the stable channel." prerelease
  check_download "$(download_url "$TAG")"
  release_put beta-latest "Newest beta build" \
    "Always the newest build of main (now beta build ${N}): $(download_url beta-latest)" prerelease
  bash "$HERE/publish-appcast.sh" --channel beta --version "$BUNDLE" --short-version "$SHORT" \
    --url "$(download_url "$TAG")" --length "$LEN" --signature "$SIG" \
    --title "Verbose beta ${N}" --notes "Beta build ${N} of main." --notes-link "$(release_page "$TAG")"
  # Keep the newest beta-<run> prereleases; delete older ones and their tags. beta-latest doesn't match.
  gh release list -R "$R" --limit 200 --json tagName,isPrerelease \
    --jq '.[] | select(.isPrerelease and (.tagName | test("^beta-[0-9]+$"))) | .tagName' \
    | sort -t- -k2,2 -n -r | tail -n +$((KEEP_BETAS + 1)) | while IFS= read -r OLD; do
      echo "Deleting old beta $OLD"
      gh release delete "$OLD" -R "$R" --yes --cleanup-tag || echo "::warning::couldn't delete $OLD"
    done
elif [[ "$GITHUB_REF" == refs/tags/mac-v* ]]; then
  TAG="${GITHUB_REF#refs/tags/}"
  # A version with a suffix (mac-v1.3.0-beta.1) is a prerelease on the beta channel; others are stable. Look
  # after "mac-v", which has a hyphen of its own.
  if [[ "${TAG#mac-v}" == *-* ]]; then CHANNEL=beta KIND=prerelease; else CHANNEL=stable KIND=latest; fi
  release_put "$TAG" "Verbose ${SHORT}" "Verbose ${SHORT} for Mac." "$KIND"
  check_download "$(download_url "$TAG")"
  bash "$HERE/publish-appcast.sh" --channel "$CHANNEL" --version "$BUNDLE" --short-version "$SHORT" \
    --url "$(download_url "$TAG")" --length "$LEN" --signature "$SIG" \
    --title "Verbose ${SHORT}" --notes-link "$(release_page "$TAG")"
else
  echo "::error::publish-update.sh runs only for main and mac-v* tags, not $GITHUB_REF"; exit 1
fi
