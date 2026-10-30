#!/bin/bash
# Checks the refined look (DESIGN.md §13): lifts the `RefinedHex` table out of Verbatim/Views/Tokens.swift (the block
# between "refined-table begin" and "refined-table end"), compiles it with Verbatim/Views/RefinedRules.swift and the
# cases in refined-tests/main.swift, and runs them: every text pair the kit draws reaches 4.5:1 in light, dark, and
# both with Increase Contrast; the Palette setting's mapping; the kinds' colors; the speakers' rotation; and the rules the
# older looks' tests used to cover (the date line, speaker shares, the Library's sort, Back and Forward, where the
# appearance settings are kept). The cases also read the kit's sources to check they take colors from the tokens only. Needs only a Swift toolchain, not Xcode.
#   bash mac/tools/test-refined.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
views="$here/../Verbatim/Views"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
sed -n '/^\/\/ refined-table begin$/,/^\/\/ refined-table end$/p' "$views/Tokens.swift" > "$out/RefinedHex.swift"
if [ ! -s "$out/RefinedHex.swift" ]; then echo "FAIL Tokens.swift has no refined-table block"; exit 1; fi
swiftc -O -o "$out/refined-tests" "$out/RefinedHex.swift" "$views/RefinedRules.swift" "$here/refined-tests/main.swift"
"$out/refined-tests" "$views" "$here/.."
