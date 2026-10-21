#!/usr/bin/env bash
# Builds Verbatim.app (universal), signs it with a Developer ID certificate when one is in the keychain,
# wraps it in a DMG, and notarizes it when the "verbatim-notary" notarytool profile exists.
#
# Needs: Xcode 16+, xcodegen (brew install xcodegen).
# Env:   VERSION (default 1.0.0), BUILD (default 1), DMG_SUFFIX (e.g. -universal), NOTARY_PROFILE,
#        PROVISION_PROFILE (path to a Developer ID provisioning profile with iCloud; turns on iCloud sync)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.0}"
VERSION="${VERSION%%-*}"   # 2.0.0-alpha.1 -> 2.0.0 for CFBundleShortVersionString
BUILD="${BUILD:-1}"
NOTARY_PROFILE="${NOTARY_PROFILE:-verbatim-notary}"
DMG="dist/Verbatim${DMG_SUFFIX:-}.dmg"

IDENTITY="${DEVELOPER_ID:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
fi
if [ -n "$IDENTITY" ]; then echo "Signing as: $IDENTITY"; else echo "No Developer ID certificate found: building unsigned."; fi
# Sign by SHA-1, not by name: a keychain can hold several Developer ID certificates with the same name.
# With a provisioning profile, use the certificate the profile was made for, so its iCloud entitlement holds.
SIGN_ID="$IDENTITY"
if [ -n "$IDENTITY" ]; then
  if [ -n "${PROVISION_PROFILE:-}" ] && [ -f "$PROVISION_PROFILE" ]; then
    SIGN_ID="$(security cms -D -i "$PROVISION_PROFILE" | plutil -extract DeveloperCertificates.0 raw -o - - | base64 -D | openssl sha1 | awk '{print toupper($NF)}')"
  else
    SIGN_ID="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')"
  fi
  echo "Certificate SHA-1: $SIGN_ID"
fi

# 1. Project from project.yml (Local.xcconfig holds your team ID for Xcode builds; empty is fine here)
[ -f Local.xcconfig ] || : > Local.xcconfig
xcodegen generate --quiet

# 1b. Link helper: yt-dlp standalone macOS binary (universal). Pinned release; checksum verified.
YTDLP_VERSION="${YTDLP_VERSION:-2026.08.19}"
mkdir -p Helpers
if [ ! -x Helpers/yt-dlp ] || ! grep -q "$YTDLP_VERSION" Helpers/yt-dlp.version 2>/dev/null; then
  curl -fsSL -o Helpers/yt-dlp "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp_macos"
  chmod +x Helpers/yt-dlp
  echo "$YTDLP_VERSION" > Helpers/yt-dlp.version
fi

# 1c. Harper grammar engine (Rust staticlib, universal). Skipped if cargo is missing and a prebuilt lib exists.
# A library built before harper_fix (dictation grammar pass) existed is rebuilt too.
if [ ! -f Vendor/harper/libharper_ffi.a ] || [ "${HARPER_REBUILD:-0}" = "1" ] || ! nm Vendor/harper/libharper_ffi.a 2>/dev/null | grep -q harper_fix; then
  if command -v cargo >/dev/null 2>&1; then
    rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null 2>&1 || true
    bash Vendor/harper/build.sh
  else
    echo "cargo not found and no prebuilt Vendor/harper/libharper_ffi.a; install Rust (https://rustup.rs) or set HARPER_REBUILD=0 with a prebuilt lib." >&2
    exit 1
  fi
fi

# 2. Build
rm -rf build dist && mkdir -p dist build
SIGN=()
if [ -n "$IDENTITY" ]; then
  TEAM="$(echo "$IDENTITY" | grep -o '([A-Z0-9]*)' | tr -d '()')"
  SIGN=(CODE_SIGN_IDENTITY="$SIGN_ID" DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--timestamp")
else
  SIGN=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi
xcodebuild -project Verbatim.xcodeproj -scheme Verbatim -configuration Release \
  -derivedDataPath build -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath build/spm -skipPackagePluginValidation \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  "${SIGN[@]}" build 2>&1 | tee build/xcodebuild.log | grep -E "error:|warning: unre|BUILD|Compiling|Linking" | tail -n 40

APP="build/Build/Products/Release/Verbatim.app"
test -d "$APP"

# 2b. Bundle the helper and sign it like the app
mkdir -p "$APP/Contents/Helpers"
cp Helpers/yt-dlp "$APP/Contents/Helpers/yt-dlp"
ENTITLEMENTS=Verbatim/Verbatim.entitlements
if [ -n "$IDENTITY" ] && [ -n "${PROVISION_PROFILE:-}" ] && [ -f "$PROVISION_PROFILE" ]; then
  # iCloud sync in a Developer ID build: embed the provisioning profile and sign with the iCloud entitlements,
  # plus the identifiers the profile grants and the Production iCloud environment Developer ID requires.
  cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS="$(mktemp -d)/Verbatim-signed.entitlements"
  cp Verbatim/Verbatim-iCloud.entitlements "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.co.stumpandroot.verbatim" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-container-environment string Production" "$ENTITLEMENTS"
  echo "iCloud sync: on (provisioning profile embedded)"
else
  echo "iCloud sync: off (no provisioning profile)"
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp --entitlements Verbatim/Helper.entitlements --sign "$SIGN_ID" "$APP/Contents/Helpers/yt-dlp"
  # Sparkle (automatic updates) ships nested code: XPC services, the Autoupdate tool, and Updater.app. Sign each
  # one inside-out with the same identity, hardened runtime, and a timestamp, then the framework, then the app.
  # Not --deep: it applies one set of options to everything and drops the Downloader service's entitlements.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  if [ ! -d "$SPARKLE" ]; then echo "error: Sparkle.framework is missing from $APP/Contents/Frameworks" >&2; exit 1; fi
  SPARKLE_V="$(cd "$SPARKLE/Versions/Current" && pwd -P)"   # Versions/B
  SPARKLE_SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_ID")
  for XPC in "$SPARKLE_V"/XPCServices/*.xpc; do
    if [ -d "$XPC" ]; then "${SPARKLE_SIGN[@]}" --preserve-metadata=entitlements "$XPC"; fi
  done
  if [ -f "$SPARKLE_V/Autoupdate" ]; then "${SPARKLE_SIGN[@]}" "$SPARKLE_V/Autoupdate"; fi
  if [ -d "$SPARKLE_V/Updater.app" ]; then "${SPARKLE_SIGN[@]}" "$SPARKLE_V/Updater.app"; fi
  "${SPARKLE_SIGN[@]}" "$SPARKLE"
  for PART in "$SPARKLE_V"/XPCServices/*.xpc "$SPARKLE_V/Autoupdate" "$SPARKLE_V/Updater.app" "$SPARKLE"; do
    if [ -e "$PART" ]; then
      echo "Sparkle signature: $(basename "$PART")"
      codesign -dvv "$PART" 2>&1 | grep -E "^(Authority=Developer ID Application|TeamIdentifier|Timestamp|CodeDirectory)" | sed 's/^/  /' || true
    fi
  done
  codesign --verify --strict --verbose=2 "$SPARKLE"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
fi

# 2c. The link helper must still run after signing (a hardened-runtime signature can stop it loading Python).
if ! "$APP/Contents/Helpers/yt-dlp" --version; then echo "error: the signed yt-dlp helper doesn't run" >&2; exit 1; fi

# 3. Verify the signature (or ad-hoc sign so the unsigned build still launches on a dev Mac)
if [ -n "$IDENTITY" ]; then
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

# 4. DMG
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# hdiutil fails now and then on CI runners ("Resource busy"); retry a few times before giving up.
for attempt in 1 2 3 4; do
  if hdiutil create -volname "Verbatim" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"; then break; fi
  echo "hdiutil failed (attempt $attempt); retrying" >&2
  if [ "$attempt" = 4 ]; then echo "error: couldn't create the DMG" >&2; exit 1; fi
  sleep $((attempt * 5))
done
rm -rf "$STAGE"
if [ -n "$IDENTITY" ]; then codesign --force --timestamp --sign "$SIGN_ID" "$DMG"; fi

# 5. Notarize and staple
if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "Notarizing…"
  # Apple's notary service sometimes hangs before it accepts the upload. Give each attempt
  # 20 minutes (perl's alarm kills a stuck notarytool), and try up to 3 times.
  notarized=0
  for attempt in 1 2 3; do
    if perl -e 'alarm shift; exec @ARGV' 1200 \
         xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 18m; then
      notarized=1; break
    fi
    echo "Notarization attempt $attempt did not finish; retrying…"
    sleep 20
  done
  [ "$notarized" = 1 ] || { echo "Notarization failed after 3 attempts."; exit 1; }
  xcrun stapler staple "$DMG"
else
  echo "Skipping notarization (no certificate or no '$NOTARY_PROFILE' profile)."
fi

ls -la "$DMG"
