#!/usr/bin/env bash
# Builds Verbatim with iCloud sync, signed with your team, and installs it in /Applications.
# Run it whenever you want the newest version on your Mac:
#
#   ~/verbatim/mac/install-mac.sh
#
# Needs: ./setup.sh run once, and Xcode signed in to your Apple ID (Xcode › Settings › Accounts).
set -euo pipefail
cd "$(dirname "$0")"

echo "Getting the newest code…"
git pull --ff-only -q
xcodegen generate --quiet

TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Local.xcconfig 2>/dev/null || true)"
TEAM="${TEAM:-VK9YQY88Q9}"

echo "Building Verbatim with iCloud sync (a few minutes the first time)…"
rm -rf build/install
# Builds the target directly: XcodeGen doesn't write shared schemes, so a fresh checkout has none.
# Uses the Debug configuration, which carries the iCloud entitlements (command-line settings would also hit
# the Swift packages), with full optimization so it runs as fast as a release build.
xcodebuild -project Verbatim.xcodeproj -target Verbatim -configuration Debug \
  -allowProvisioningUpdates -quiet SYMROOT="$PWD/build/install" \
  DEVELOPMENT_TEAM="$TEAM" ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=NO \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s

APP="build/install/Debug/Verbatim.app"
[ -d "$APP" ] || { echo "The build didn't produce Verbatim.app. Send the output above to Claude."; exit 1; }

echo "Installing in Applications…"
osascript -e 'tell application "Verbatim" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Verbatim.app
cp -R "$APP" /Applications/Verbatim.app
open /Applications/Verbatim.app
echo "✓ Verbatim is installed. The bottom of the sidebar should say \"Syncing with iCloud\"."
