#!/usr/bin/env bash
# Commits an updated appcast.xml to the `updates` branch (created as an orphan branch if missing).
# CI only (.github/workflows/build-swift.yml). Never force-pushes: when the push is rejected because the branch
# moved, it fetches the new tip, applies the change again with appcast.py, and retries.
#
# Usage: publish-appcast.sh <appcast.py arguments, without the file path>
# Env:   GITHUB_TOKEN, GITHUB_REPOSITORY (APPCAST_REMOTE overrides the remote, such as a local bare repo for testing)
set -euo pipefail
: "${GITHUB_TOKEN:?}" "${GITHUB_REPOSITORY:?}"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/appcast.py"
REMOTE="${APPCAST_REMOTE:-https://github.com/${GITHUB_REPOSITORY}.git}"
BRANCH=updates
# The token reaches git through a credential helper that reads it from the environment, so it never appears in a
# command line, a remote URL, or .git/config.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=""
export GIT_CONFIG_KEY_1=credential.helper
export GIT_CONFIG_VALUE_1='!f() { echo username=x-access-token; echo "password=${GITHUB_TOKEN}"; }; f'

for attempt in 1 2 3 4 5 6; do
  W="$(mktemp -d)"
  git -C "$W" init -q
  git -C "$W" config user.name "verbatim-ci"
  git -C "$W" config user.email "ci@stumpandroot.co"
  git -C "$W" remote add origin "$REMOTE"
  if git -C "$W" ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    git -C "$W" fetch -q --depth 1 origin "$BRANCH"
    git -C "$W" checkout -q -b "$BRANCH" FETCH_HEAD
  else
    echo "The $BRANCH branch doesn't exist yet; creating it as an orphan branch."
    git -C "$W" symbolic-ref HEAD "refs/heads/$BRANCH"
  fi
  python3 "$SCRIPT" "$W/appcast.xml" "$@"
  python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$W/appcast.xml"
  git -C "$W" add appcast.xml
  if git -C "$W" diff --cached --quiet; then echo "appcast.xml unchanged"; rm -rf "$W"; exit 0; fi
  git -C "$W" commit -q -m "Appcast: build ${GITHUB_RUN_NUMBER:-local}"
  if git -C "$W" push -q origin "HEAD:refs/heads/$BRANCH"; then
    echo "Published appcast.xml to the $BRANCH branch (attempt $attempt)."
    rm -rf "$W"; exit 0
  fi
  echo "Push rejected (attempt $attempt); fetching the new tip and retrying." >&2
  rm -rf "$W"
  sleep $((attempt * 3))
done
echo "error: couldn't publish appcast.xml" >&2
exit 1
