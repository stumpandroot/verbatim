#!/bin/bash
# Compiles PremiumRules.swift (the Native look on the Mac: the date line and the Library table's date cell, sort, and
# row meta, speakers' shares, This week's bars, the Settings squares, and back and forward) with the cases in
# premium-tests/main.swift, and runs them; they also read the Native Views files to check no brand color, glow,
# gradient, or custom shadow is left in Native's chrome. Needs only a Swift toolchain, not Xcode.
#   bash mac/tools/test-premium.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/premium-tests" "$here/../Verbatim/Views/PremiumRules.swift" "$here/premium-tests/main.swift"
"$out/premium-tests" "$here/../Verbatim/Views"
