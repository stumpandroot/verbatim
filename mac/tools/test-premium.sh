#!/bin/bash
# Compiles PremiumRules.swift (Premium Native on the Mac: the gradient cards' text placement, the date line, speakers'
# shares, This week's bars, the scope bar, and back and forward) with the cases in premium-tests/main.swift, and runs
# them; they read the gradient and window colors from Tokens.swift. Needs only a Swift toolchain, not Xcode.
#   bash mac/tools/test-premium.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/premium-tests" "$here/../Verbatim/Views/PremiumRules.swift" "$here/premium-tests/main.swift"
"$out/premium-tests" "$here/../Verbatim/Views/Tokens.swift"
