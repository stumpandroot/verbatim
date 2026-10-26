#!/usr/bin/env bash
# Builds Verbatim.app (universal), signs it with a Developer ID certificate when one is in the keychain,
# wraps it in a DMG, and notarizes it when the "verbatim-notary" notarytool profile exists.
#
# Needs: Xcode 16+, xcodegen (brew install xcodegen).
# Env:   VERSION (default: project.yml's MARKETING_VERSION), VERBOSE_CHANNEL (default: project.yml's; set it empty
#        for a release with no channel), BUILD (default 1), DMG_SUFFIX (e.g. -universal), NOTARY_PROFILE,
#        PROVISION_PROFILE (path to a Developer ID provisioning profile with iCloud; turns on iCloud sync),
#        SKIP_NOTARIZE=1 (build and sign only; run notarize.sh afterward)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-}"
VERSION="${VERSION%%-*}"   # 2.0.0-alpha.1 -> 2.0.0 for CFBundleShortVersionString
# Versions (VERSIONING.md): project.yml's MARKETING_VERSION and VERBOSE_CHANNEL unless VERSION or VERBOSE_CHANNEL is set.
VERSION_ARGS=()
if [ -n "$VERSION" ]; then VERSION_ARGS+=(MARKETING_VERSION="$VERSION"); fi
if [ -n "${VERBOSE_CHANNEL+set}" ]; then VERSION_ARGS+=(VERBOSE_CHANNEL="$VERBOSE_CHANNEL"); fi
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
# Swift package versions pinned by mac/Package.resolved (the generated project is git-ignored).
bash tools/package-resolved.sh install

# 1b. Link helper: yt-dlp standalone macOS binary (universal). Pinned release; SHA-256 checked (fetch-yt-dlp.sh).
bash fetch-yt-dlp.sh

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

# 1d. FFmpeg (audio only, LGPL, dynamic frameworks) for MKV, WebM, AVI, and other imports. Does nothing when
# Vendor/ffmpeg already matches ffmpeg/build.sh (CI restores it from its cache).
bash ffmpeg/build.sh

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
  ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} CURRENT_PROJECT_VERSION="$BUILD" \
  "${SIGN[@]}" build 2>&1 | tee build/xcodebuild.log | grep -E "error:|warning: unre|BUILD|Compiling|Linking" | tail -n 40

APP="build/Build/Products/Release/Verbatim.app"
test -d "$APP"

# 2b. Bundle the helper and sign it like the app
mkdir -p "$APP/Contents/Helpers"
cp Helpers/yt-dlp "$APP/Contents/Helpers/yt-dlp"
# The entitlements name the App Group the app shares with its desktop widgets as Xcode's
# $(TeamIdentifierPrefix)co.stumpandroot.verbatim; codesign needs the prefix filled in ("TEAMID.", or nothing unsigned),
# matching the VerbatimAppGroup value Xcode wrote into both Info.plists.
ENT_DIR="$(mktemp -d)"
fill_team() { sed "s/\$(TeamIdentifierPrefix)/${TEAM:+$TEAM.}/g" "$1" > "$2"; }
ENTITLEMENTS="$ENT_DIR/Verbatim.entitlements"
fill_team Verbatim/Verbatim.entitlements "$ENTITLEMENTS"
WIDGETS="$APP/Contents/PlugIns/VerbatimMacWidgets.appex"
WIDGET_ENTITLEMENTS="$ENT_DIR/VerbatimMacWidgets.entitlements"
fill_team VerbatimMacWidgets/VerbatimMacWidgets.entitlements "$WIDGET_ENTITLEMENTS"
if [ ! -d "$WIDGETS" ]; then echo "error: VerbatimMacWidgets.appex is missing from $APP/Contents/PlugIns" >&2; exit 1; fi
if [ -n "$IDENTITY" ] && [ -n "${PROVISION_PROFILE:-}" ] && [ -f "$PROVISION_PROFILE" ]; then
  # iCloud sync in a Developer ID build: embed the provisioning profile and sign with the iCloud entitlements,
  # plus the identifiers the profile grants and the Production iCloud environment Developer ID requires.
  cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS="$ENT_DIR/Verbatim-signed.entitlements"
  fill_team Verbatim/Verbatim-iCloud.entitlements "$ENTITLEMENTS"
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
  # FFmpeg's frameworks (ffmpeg/build.sh): Xcode embeds and signs them; sign them again here with the hardened
  # runtime and a timestamp, as notarization expects of every binary, before the app's own signature seals them.
  for LIB in libavutil libswresample libavcodec libavformat; do
    FW="$APP/Contents/Frameworks/$LIB.framework"
    if [ ! -d "$FW" ]; then echo "error: $LIB.framework is missing from $APP/Contents/Frameworks" >&2; exit 1; fi
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$FW"
  done
  # The desktop widgets (VerbatimMacWidgets.appex): signed again here like every nested bundle, with the hardened
  # runtime, a timestamp, and its own entitlements (the App Sandbox, which WidgetKit requires, and the App Group).
  codesign --force --options runtime --timestamp --entitlements "$WIDGET_ENTITLEMENTS" --sign "$SIGN_ID" "$WIDGETS"
  WENT="$(codesign -d --entitlements - "$WIDGETS" 2>&1 || true)"
  for KEY in com.apple.security.app-sandbox com.apple.security.application-groups "$TEAM.co.stumpandroot.verbatim"; do
    if ! grep -q "$KEY" <<< "$WENT"; then echo "error: the widget extension's signature lacks $KEY" >&2; exit 1; fi
  done
  echo "Widget extension signature:"
  codesign -dvv "$WIDGETS" 2>&1 | grep -E "^(Authority=Developer ID Application|TeamIdentifier|Timestamp|CodeDirectory)" | sed 's/^/  /' || true
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
fi

# 2c. The link helper must still run after signing (a hardened-runtime signature can stop it loading Python).
if ! "$APP/Contents/Helpers/yt-dlp" --version; then echo "error: the signed yt-dlp helper doesn't run" >&2; exit 1; fi

# 3. Verify the signature (or ad-hoc sign so the unsigned build still launches on a dev Mac)
if [ -n "$IDENTITY" ]; then
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  codesign --force --deep --sign - "$APP"
  # --deep signs the widget extension without entitlements, and WidgetKit loads only a sandboxed extension: sign it
  # again with its own (the group has no team prefix here, as in the Info.plists), then seal it into the app.
  codesign --force --sign - --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGETS"
  codesign --force --sign - "$APP"
fi

# 4. DMG
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# hdiutil fails now and then on CI runners ("Resource busy"); retry a few times before giving up.
for attempt in 1 2 3 4; do
  if hdiutil create -volname "Verbose" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"; then break; fi
  echo "hdiutil failed (attempt $attempt); retrying" >&2
  if [ "$attempt" = 4 ]; then echo "error: couldn't create the DMG" >&2; exit 1; fi
  sleep $((attempt * 5))
done
rm -rf "$STAGE"
if [ -n "$IDENTITY" ]; then codesign --force --timestamp --sign "$SIGN_ID" "$DMG"; fi

# 5. Notarize and staple (notarize.sh). CI sets SKIP_NOTARIZE=1 and notarizes in a separate step, so the Apple ID
# credentials never sit in a keychain while this script runs third-party build code.
if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "Skipping notarization here (SKIP_NOTARIZE=1)."
elif [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  NOTARY_PROFILE="$NOTARY_PROFILE" bash notarize.sh "$DMG"
else
  echo "Skipping notarization (no certificate or no '$NOTARY_PROFILE' profile)."
fi

ls -la "$DMG"
