#!/usr/bin/env bash
# Notarizes and staples a signed DMG with a stored notarytool profile. build.sh runs it at the end of a local build;
# CI (build-swift.yml) runs it as its own step, so only that step sees the Apple ID credentials.
#
#   bash mac/notarize.sh dist/Verbatim-universal.dmg
# Env: NOTARY_PROFILE (default verbatim-notary), NOTARY_KEYCHAIN (optional: the keychain that holds the profile,
#      instead of the default one; CI keeps it in a temporary keychain that it deletes afterward)
set -euo pipefail
DMG="${1:?usage: notarize.sh <dmg>}"
NOTARY_PROFILE="${NOTARY_PROFILE:-verbatim-notary}"
AUTH=(--keychain-profile "$NOTARY_PROFILE")
if [ -n "${NOTARY_KEYCHAIN:-}" ]; then AUTH+=(--keychain "$NOTARY_KEYCHAIN"); fi

echo "Notarizing…"
# Apple's notary service sometimes hangs before it accepts the upload. Give each attempt
# 20 minutes (perl's alarm kills a stuck notarytool), and try up to 3 times.
notarized=0
for attempt in 1 2 3; do
  if perl -e 'alarm shift; exec @ARGV' 1200 \
       xcrun notarytool submit "$DMG" "${AUTH[@]}" --wait --timeout 18m; then
    notarized=1; break
  fi
  echo "Notarization attempt $attempt did not finish; retrying…"
  sleep 20
done
[ "$notarized" = 1 ] || { echo "Notarization failed after 3 attempts."; exit 1; }
xcrun stapler staple "$DMG"
