#!/usr/bin/env bash
# One-time setup for running Verbatim from Xcode on your Mac and iPhone, with iCloud sync.
#
#   cd mac && ./setup.sh            (uses the Stump & Root team, VK9YQY88Q9)
#
# Your team ID is the 10-character code at developer.apple.com > Account > Membership details.
# The script writes it to Local.xcconfig (not committed), gets the Harper grammar libraries and the link
# helper, generates Verbatim.xcodeproj, and opens it.
set -euo pipefail
cd "$(dirname "$0")"

TEAM="${1:-VK9YQY88Q9}"   # Stump & Root team ID; pass another to override
if [ -z "$TEAM" ] && [ -f Local.xcconfig ]; then TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Local.xcconfig)"; fi
if [ -z "$TEAM" ]; then
  read -r -p "Apple Developer team ID (10 characters): " TEAM
fi
echo "DEVELOPMENT_TEAM = $TEAM" > Local.xcconfig
echo "✓ Team $TEAM saved to Local.xcconfig"

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then echo "Installing XcodeGen…"; brew install xcodegen
  else echo "Install Homebrew (https://brew.sh), then run this script again."; exit 1; fi
fi

# Harper (spelling and grammar). Built from source when Rust is installed; otherwise from the CI download.
# Libraries built before harper_fix (the dictation grammar pass) existed are rebuilt too.
harper_stale() { [ ! -f "$1" ] || ! nm "$1" 2>/dev/null | grep -q harper_fix; }
if harper_stale Vendor/harper/libharper_ffi.a || harper_stale Vendor/harper/ios/libharper_ffi.a || harper_stale Vendor/harper/ios-sim/libharper_ffi.a; then
  if command -v cargo >/dev/null 2>&1; then
    echo "Building Harper for Mac and iPhone (a few minutes the first time)…"
    rustup target add aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios >/dev/null
    bash Vendor/harper/build.sh
    bash Vendor/harper/build-ios.sh
  elif [ -f "$HOME/Downloads/harper-libs.zip" ]; then
    echo "Using ~/Downloads/harper-libs.zip"
    unzip -oq "$HOME/Downloads/harper-libs.zip" -d Vendor/harper
  else
    echo
    echo "Harper's libraries are missing. Either:"
    echo "  1. Download harper-libs.zip from https://github.com/stumpandroot/verbatim/raw/ci-screens/harper-libs.zip"
    echo "     into your Downloads folder, then run this script again, or"
    echo "  2. Install Rust (https://rustup.rs), then run this script again."
    exit 1
  fi
fi
echo "✓ Harper libraries ready"

# FFmpeg (audio only, LGPL), which reads MKV, WebM, AVI, and other files. Built from the pinned source the first
# time (about 5–10 minutes), then only when ffmpeg/build.sh changes.
echo "Building FFmpeg for Mac and iPhone if needed…"
bash ffmpeg/build.sh
echo "✓ FFmpeg ready"

# The link helper (yt-dlp) for the Mac app's link fetching. The iPhone hands links to the Mac.
YTDLP_VERSION="2026.08.19"
mkdir -p Helpers
if [ ! -x Helpers/yt-dlp ]; then
  curl -fsSL -o Helpers/yt-dlp "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp_macos" && chmod +x Helpers/yt-dlp && echo "$YTDLP_VERSION" > Helpers/yt-dlp.version
fi
echo "✓ Link helper ready"

xcodegen generate --quiet
echo "✓ Verbatim.xcodeproj generated"
echo
echo "Next, in Xcode:"
echo "  1. Pick the VerbatimPhone scheme and your iPhone, then press Run (⌘R)."
echo "  2. Pick the Verbatim scheme and My Mac, then press Run, so the Mac syncs too."
echo "The first run asks Xcode to register the iCloud container; let it."
open Verbatim.xcodeproj
