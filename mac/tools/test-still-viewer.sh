#!/bin/bash
# Compiles the stills viewer's rules (Verbatim/Model/StillViewerRules.swift) with the refined look's rules it reads
# the time from (Views/RefinedRules.swift and the RefinedHex table lifted out of Views/Tokens.swift) and the test cases
# in still-viewer-tests/main.swift, and runs them. Needs only a Swift toolchain (macOS or Linux), not Xcode.
#   bash mac/tools/test-still-viewer.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
views="$here/../Verbatim/Views"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
sed -n '/^\/\/ refined-table begin$/,/^\/\/ refined-table end$/p' "$views/Tokens.swift" > "$out/RefinedHex.swift"
if [ ! -s "$out/RefinedHex.swift" ]; then echo "FAIL Tokens.swift has no refined-table block"; exit 1; fi
swiftc -O -o "$out/still-viewer-tests" "$out/RefinedHex.swift" "$views/RefinedRules.swift" \
  "$here/../Verbatim/Model/StillViewerRules.swift" "$here/still-viewer-tests/main.swift"
"$out/still-viewer-tests"
