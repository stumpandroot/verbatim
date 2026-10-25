#!/bin/bash
# Compiles the keyboard's modes and Home stats (VerbatimKeyboard/KeyboardHome.swift: which mode it opens in, the stats
# pages' words) and typing layout (VerbatimKeyboard/TypingLayout.swift: shift and caps lock, auto-capitalization,
# double space for a period, layers, rows, key frames, and hit testing) and dictate button (VerbatimKeyboard/DictateButton.swift:
# Settings › Keyboard › Dictate button's stored choices and layout) with the cases in keyboard-tests/main.swift,
# and runs them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-keyboard.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/keyboard-tests" "$here/../VerbatimKeyboard/TypingLayout.swift" "$here/../VerbatimKeyboard/KeyboardHome.swift" \
  "$here/../VerbatimKeyboard/DictateButton.swift" "$here/keyboard-tests/main.swift"
"$out/keyboard-tests"
