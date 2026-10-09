#!/bin/bash
# Builds Verbatim.app on macOS. Run from the link-transcriber folder:
#   bash macapp/build_mac.sh
# Output: dist/Verbatim.app
#
# Needs: Python 3.11 or 3.12 (brew install python@3.11), internet access for pip and FFmpeg.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  for c in python3.12 python3.11 python3; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
echo "Using $($PY --version) at $(command -v "$PY")"

# 1. Build environment
if [ ! -d .venv-build ]; then "$PY" -m venv .venv-build; fi
# shellcheck disable=SC1091
source .venv-build/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt pywebview pyinstaller pillow

# 2. Static FFmpeg + ffprobe for this Mac's architecture
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

# 4. Bundle
rm -rf build dist
pyinstaller --noconfirm --clean --windowed --name Verbatim \
  --icon macapp/Verbatim.icns \
  --osx-bundle-identifier co.stumpandroot.verbatim \
  --add-data "app.py:." \
  --add-data "static:static" \
  --add-data "macapp/bin:bin" \
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

# 5. Let the app reach the network and sign it for this Mac
PLIST="dist/Verbatim.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0" "$PLIST" 2>/dev/null || true
codesign --force --deep --sign - dist/Verbatim.app

echo
echo "Built dist/Verbatim.app ($(du -sh dist/Verbatim.app | cut -f1)). Drag it to Applications."
echo "First launch: right-click the app, choose Open, then Open again. After that it opens normally."
