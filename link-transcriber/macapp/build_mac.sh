#!/bin/bash
# Builds, signs, packages, and notarizes Verbatim for macOS. Run from the link-transcriber folder:
#   bash macapp/build_mac.sh
# Output: dist/Verbatim.app and dist/Verbatim.dmg (DMG_SUFFIX=-arm64 names it Verbatim-arm64.dmg)
#
# Needs: Python 3.11 or 3.12 (brew install python@3.11), Xcode command line tools, internet access.
#
# Signing and notarization happen automatically when these exist:
#   - A "Developer ID Application" certificate in your Keychain (made in Xcode > Settings > Accounts).
#   - A notarytool keychain profile named "verbatim-notary". Create it once with:
#       xcrun notarytool store-credentials verbatim-notary --apple-id YOU@EXAMPLE.COM --team-id TEAMID --password APP-SPECIFIC-PASSWORD
#     (The app-specific password comes from appleid.apple.com > Sign-In and Security.)
# Without those, the script still builds an app that runs on this Mac only.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-verbatim-notary}"
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
echo "Using $($PY --version) at $(command -v "$PY")"

# Developer ID certificate, if present
IDENTITY="${DEVELOPER_ID:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
fi
if [ -n "$IDENTITY" ]; then echo "Signing as: $IDENTITY"; else echo "No Developer ID certificate found: building for this Mac only."; fi

# 1. Build environment
if [ ! -d .venv-build ]; then "$PY" -m venv .venv-build; fi
# shellcheck disable=SC1091
source .venv-build/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt pywebview pyinstaller pillow

# 2. Static FFmpeg + ffprobe for this Mac's chip
ARCH="$(uname -m)"            # arm64 or x86_64
mkdir -p macapp/bin
for tool in ffmpeg ffprobe; do
  if [ ! -x "macapp/bin/$tool" ]; then
    echo "Downloading static $tool ($ARCH)…"
    curl -fsSL -o "macapp/$tool.zip" "https://ffmpeg.martin-riedl.de/redirect/latest/macos/$ARCH/release/$tool.zip"
    unzip -qo "macapp/$tool.zip" -d macapp/bin
    rm -f "macapp/$tool.zip"
    chmod +x "macapp/bin/$tool"
  fi
done
macapp/bin/ffmpeg -version | head -1

# 3. App icon (.icns from static/app-icon.png)
if [ ! -f macapp/Verbatim.icns ]; then
  echo "Making icon…"
  rm -rf macapp/Verbatim.iconset && mkdir -p macapp/Verbatim.iconset
  for s in 16 32 64 128 256 512 1024; do
    sips -z $s $s static/app-icon.png --out "macapp/Verbatim.iconset/icon_${s}x${s}.png" >/dev/null
  done
  for s in 16 32 128 256 512; do
    d=$((s*2)); cp "macapp/Verbatim.iconset/icon_${d}x${d}.png" "macapp/Verbatim.iconset/icon_${s}x${s}@2x.png"
  done
  rm -f macapp/Verbatim.iconset/icon_64x64.png macapp/Verbatim.iconset/icon_1024x1024.png
  iconutil -c icns macapp/Verbatim.iconset -o macapp/Verbatim.icns
  rm -rf macapp/Verbatim.iconset
fi

# 4. Bundle (PyInstaller signs every binary inside-out when an identity is given)
SIGN_ARGS=()
if [ -n "$IDENTITY" ]; then
  SIGN_ARGS=(--codesign-identity "$IDENTITY" --osx-entitlements-file macapp/entitlements.plist)
fi
rm -rf build dist
pyinstaller --noconfirm --clean --windowed --name Verbatim \
  --icon macapp/Verbatim.icns \
  --osx-bundle-identifier co.stumpandroot.verbatim \
  "${SIGN_ARGS[@]}" \
  --add-data "app.py:." \
  --add-data "static:static" \
  --add-binary "macapp/bin/ffmpeg:bin" \
  --add-binary "macapp/bin/ffprobe:bin" \
  --collect-all faster_whisper \
  --collect-all ctranslate2 \
  --collect-all tokenizers \
  --collect-all huggingface_hub \
  --collect-all onnxruntime \
  --collect-all av \
  --collect-all yt_dlp \
  --hidden-import uvicorn.logging \
  --hidden-import uvicorn.loops.auto \
  --hidden-import uvicorn.loops.asyncio \
  --hidden-import uvicorn.protocols.http.auto \
  --hidden-import uvicorn.protocols.http.h11_impl \
  --hidden-import uvicorn.protocols.websockets.auto \
  --hidden-import uvicorn.lifespan.on \
  --hidden-import multipart \
  macapp/verbatim_app.py

APP="dist/Verbatim.app"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST" 2>/dev/null || \
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 12.0" "$PLIST" 2>/dev/null || true

# 5. Final signature over the whole bundle (Info.plist changed above)
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp --entitlements macapp/entitlements.plist --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

# 6. Disk image: the standard "drag Verbatim to Applications" window
DMG="dist/Verbatim${DMG_SUFFIX:-}.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Verbatim" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
if [ -n "$IDENTITY" ]; then codesign --force --timestamp --sign "$IDENTITY" "$DMG"; fi

# 7. Notarize and staple, when the keychain profile exists
if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "Submitting to Apple for notarization (usually 2–10 minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
  spctl --assess --type open --context context:primary-signature -v "$DMG" && echo "Notarized: opens cleanly on any Mac."
else
  echo "Skipped notarization (no Developer ID, or no '$NOTARY_PROFILE' keychain profile). See the header of this script."
fi

echo
echo "Built $APP ($(du -sh "$APP" | cut -f1)) and $DMG ($(du -sh "$DMG" | cut -f1))."
