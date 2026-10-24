#!/bin/bash
# Compiles what the iPhone app trusts from outside its process (VerbatimKeyboard/BridgeTrust.swift: commands from the
# widget's process, session links from the keyboard, the bundle ID to switch back to, and how long Recent keeps a
# dictation) with the cases in bridge-tests/main.swift, and runs them. Needs only a Swift toolchain (macOS or Linux),
# not Xcode.
#   bash mac/tools/test-bridge.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/bridge-tests" "$here/../VerbatimKeyboard/BridgeTrust.swift" "$here/bridge-tests/main.swift"
"$out/bridge-tests"
