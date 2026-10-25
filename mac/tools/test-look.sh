#!/bin/bash
# Compiles the look the keyboard reads (VerbatimKeyboard/KeyboardLook.swift: the App Group value and WCAG contrast)
# with the cases in look-tests/main.swift, and runs them. The cases also read the Native accent's values from
# Verbatim/Views/Tokens.swift and check them against 4.5:1. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-look.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/look-tests" "$here/../VerbatimKeyboard/KeyboardLook.swift" "$here/look-tests/main.swift"
"$out/look-tests" "$here/../Verbatim/Views/Tokens.swift" "$here/../Verbatim/Views/Look.swift"
