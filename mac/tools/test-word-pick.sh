#!/bin/bash
# Compiles the real WordPick.swift (a click, a highlight, or a double-click on a transcript line, as pure rules) with
# the cases in word-pick-tests/main.swift and runs them: which word sits at a place in the text, when it was said, the
# word or phrase a fix starts from, and what counts as a double-click; then, against the sources, that a click moves
# the playhead without starting playback and that a double-click and a highlighted phrase open the one Fix box. Needs
# only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-word-pick.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/word-pick-tests" "$here/../Verbatim/Model/WordPick.swift" "$here/word-pick-tests/main.swift"
"$out/word-pick-tests" "$here/.."
