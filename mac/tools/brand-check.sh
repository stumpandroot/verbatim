#!/usr/bin/env bash
# Brand check: fails when Swift code breaks the [checked] rules in mac/DESIGN.md.
#   1. SF Symbols outside the allowlist (DESIGN.md §3)
#   2. Colors outside Tokens.swift: hex literals in color calls and system color names (§1)
#   3. Materials or glass (§5): allowed only on a line marked `// brand: glass ok (no text)`
#   4. The retired V mark, BrandArt.mark (§4)
# Run from anywhere: bash mac/tools/brand-check.sh   (exit 1 lists each problem as file:line)
set -u
cd "$(dirname "$0")/.." || exit 2
DIRS="Verbatim VerbatimPhone VerbatimKeyboard VerbatimShare VerbatimWidgets"
SRC=$(for d in $DIRS; do [ -d "$d" ] && echo "$d"; done)
fail=0
report() { echo "brand-check: $1"; echo "$2" | sed 's/^/  /'; echo; fail=1; }

ALLOWED='^(xmark|xmark\.circle\.fill|plus|plus\.circle|minus\.circle|chevron\..*|checkmark|checkmark\.circle\.fill|ellipsis|ellipsis\.circle|square\.and\.arrow\.up|trash|magnifyingglass|sidebar\.left|line\.3\.horizontal|arrow\.right|arrow\.up\.arrow\.down|arrow\.uturn\.backward|arrow\.counterclockwise|return|delete\.left|globe|keyboard)$'
syms=$(grep -rnoE --include=*.swift '(systemName|systemImage): *"[^"]+"' $SRC \
  | awk -F: '{ n=$0; sub(/.*: *"/, "", n); sub(/"$/, "", n); print $1 ":" $2 "  " n }' \
  | while IFS= read -r l; do echo "${l##*  }" | grep -qE "$ALLOWED" || echo "$l"; done)
[ -n "$syms" ] && report "SF Symbols not on the DESIGN.md §3 allowlist (use a BrandArt glyph):" "$syms"

hex=$(grep -rnE --include=*.swift '(hex: *0x[0-9A-Fa-f]{6}|Color\(red:|Color\(\.sRGB|UIColor\(red:|NSColor\(red:|NSColor\(calibratedRed:)' $SRC | grep -v 'Views/Tokens.swift' | cut -d: -f1,2)
[ -n "$hex" ] && report "Colors outside Tokens.swift (add or use an Ink token):" "$hex"

sys=$(grep -rnE --include=*.swift '(Color\.|foregroundStyle\(\.|foregroundColor\(\.|tint\(\.|fill\(\.|background\(\.)(red|blue|orange|green|gray|grey|purple|pink|yellow|teal|indigo|mint|cyan|brown|accentColor)\b' $SRC | grep -v 'Views/Tokens.swift' | cut -d: -f1,2)
[ -n "$sys" ] && report "System color names (use Ink tokens; errors use Ink.danger):" "$sys"

glass=$(grep -rnE --include=*.swift '\.(ultraThinMaterial|thinMaterial|regularMaterial|thickMaterial|ultraThickMaterial|bar)\b|glassEffect\(' $SRC | grep -E 'Material|glassEffect' | grep -v 'brand: glass ok' | cut -d: -f1,2)
[ -n "$glass" ] && report "Material or glass without '// brand: glass ok (no text)' (never put text on blur):" "$glass"

mark=$(grep -rnE --include=*.swift 'BrandArt\.mark\b|art: *\.mark\b' $SRC | grep -v 'Views/Brand.swift' | cut -d: -f1,2)
[ -n "$mark" ] && report "The retired V mark (use the bars mark):" "$mark"

[ $fail -eq 0 ] && echo "brand-check: OK"
exit $fail
