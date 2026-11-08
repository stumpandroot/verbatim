#!/bin/bash
# Compiles typing help's pure rules (VerbatimKeyboard/TypingCorrection.swift: which fields correct, the word at the
# cursor, which words are left alone, when space corrects and to what, text replacements, putting a correction back, the
# suggestion strip, the long-press row, and the space-bar cursor drag; VerbatimKeyboard/TypingHelp.swift: the settings,
# the languages, the letter layouts, and each language's long-press letters; VerbatimKeyboard/TypingScripts.swift: the
# Russian, Ukrainian, Greek, Arabic, and Hebrew rows, scripts, final sigma, Greek's accent key, and which way a line runs)
# with the cases in typing-correction-tests/main.swift, and runs them. TypingLayout.swift comes along for the field kinds
# and the key rows.
# Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-typing-correction.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/typing-correction-tests" "$here/../VerbatimKeyboard/TypingLayout.swift" "$here/../VerbatimKeyboard/TypingHelp.swift" \
  "$here/../VerbatimKeyboard/TypingScripts.swift" "$here/../VerbatimKeyboard/TypingCorrection.swift" "$here/typing-correction-tests/main.swift"
"$out/typing-correction-tests"
