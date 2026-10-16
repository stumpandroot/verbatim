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
if [ ! -f Vendor/harper/libharper_ffi.a ] || [ "${HARPER_REBUILD:-0}" = "1" ]; then
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
  SIGN=(CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--timestamp")
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
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/yt-dlp"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi

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
hdiutil create -volname "Verbatim" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
if [ -n "$IDENTITY" ]; then codesign --force --timestamp --sign "$IDENTITY" "$DMG"; fi

# 5. Notarize and staple
if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "Notarizing…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  echo "Skipping notarization (no certificate or no '$NOTARY_PROFILE' profile)."
fi

ls -la "$DMG"
