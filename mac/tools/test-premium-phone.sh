#!/bin/bash
# Compiles the iPhone's Premium Native rules (VerbatimPhone/PremiumRules.swift: the week chart, days used, the year's
# month bars, the month calendar's dots, the recorder's clock and waveform, previews, and contrast) with the cases in
# premium-phone-tests/main.swift, and runs them. The cases also read the gradient stops from Verbatim/Views/Tokens.swift
# and check white text on them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-premium-phone.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -O -o "$out/premium-phone-tests" "$here/../VerbatimPhone/PremiumRules.swift" "$here/premium-phone-tests/main.swift"
"$out/premium-phone-tests" "$here/../Verbatim/Views/Tokens.swift"
