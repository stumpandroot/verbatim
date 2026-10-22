#!/bin/bash
# Compiles the keyboard's typing layout (VerbatimKeyboard/TypingLayout.swift: which view it opens in, shift and caps
# lock, auto-capitalization, double space for a period, layers, rows, key frames, and hit testing) with the cases in
# keyboard-tests/main.swift, and runs them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-keyboard.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/keyboard-tests" "$here/../VerbatimKeyboard/TypingLayout.swift" "$here/keyboard-tests/main.swift"
"$out/keyboard-tests"
