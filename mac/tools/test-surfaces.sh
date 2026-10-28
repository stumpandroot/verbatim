#!/bin/bash
# Compiles the Mac dictation surfaces' pure rules (Verbatim/Flow/NotchGeometry.swift: where the notch is and how big
# the notch style's shape gets; DictationSurface.swift: which style shows and where the thought bubble sits;
# HotkeyRules.swift: recorded shortcuts, conflicts, mouse buttons, and the ⌃⌥ Space upgrade) with the cases in
# surfaces-tests/main.swift, and runs them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-surfaces.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
flow="$here/../Verbatim/Flow"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/surfaces-tests" "$flow/NotchGeometry.swift" "$flow/DictationSurface.swift" "$flow/HotkeyRules.swift" "$here/surfaces-tests/main.swift"
"$out/surfaces-tests"
